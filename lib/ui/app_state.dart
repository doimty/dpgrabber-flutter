/// Application state: the single owner of config, credentials, the
/// API client, the listen engine, history, logs and theme.
///
/// Wiring (PORTING_CONTRACT §1.6/§7.3/§8):
/// - engine `log` -> [LogStore] (500-entry cap, §12 Q-14)
/// - engine `speak` -> [VoiceAnnouncer] when `voice_enabled`
/// - engine `onGrab` -> history `success` + remote push (§8, success
///   only) + local notification hook (see [onLocalNotification])
/// - engine `onOutcome` -> history entry, exactly one per order
///   (success dedup is enforced by the engine, §1.6)
/// - account rotation timer lives here in the UI layer (core only
///   provides the config items — core handoff deviation #5)
///
/// Credential storage: main() passes the bridge's secure store
/// ([SecureCredentialStore]); without it this falls back to the
/// core's development-only [FileCredentialStore] and the UI shows its
/// unencrypted warning (§1.7 — never silently downgrade). Swap point:
/// pass a secure [CredentialStore] into the constructor.
library;

import 'dart:async';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';

import '../bridge/bridge.dart';
import '../background/background_repository.dart';
import '../core.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/palette.dart';
import 'log_store.dart';
import 'voice_announcer.dart';

/// Local notification hook, filled in by the bridge layer when it
/// lands (title `抢单成功`, body `已抢到一单，金额 X 元，请去查看订单。`,
/// §8.4). Until then grabs only log; the hook being null is reported,
/// never silently assumed to work.
typedef LocalNotifyFn = Future<void> Function(String title, String body);

class AppState extends ChangeNotifier {
  final Directory appDir;
  final CredentialStore store;
  final AccountStore accounts;
  final HistoryStore historyStore;
  final LogStore logs = LogStore();
  final GlassSettings glass = GlassSettings();
  final VoiceAnnouncer voice = VoiceAnnouncer();

  /// Set by the bridge layer to post the grab-success local
  /// notification (§8.4). Null until the bridge wires it.
  LocalNotifyFn? onLocalNotification;

  /// Set by main() from the bridge layer: started when listening
  /// starts, stopped when it stops (§12 Q-13).
  KeepAlive? keepAlive;

  late AppConfig config;
  late ThemeController theme;
  late ApiClient client;
  late Notifier notifier;
  ListenEngine? engine;

  Session? session;
  Clerk? clerk;
  bool initialized = false;
  bool loggedIn = false;
  String? loginPhone;
  String? _password; // in-memory only, never persisted by this class
  bool online = false;

  /// Cached clerk avatar file path (empty = show the letter fallback).
  String avatarPath = '';
  bool listening = false;
  String? lastError;

  ClerkStatistics? weekStats;
  int? weekFallbackTotal;
  bool weekStatsLoading = false;

  /// Item-type switches from `itemSwitchList` (§6.5): id -> name, and
  /// the enabled ids. Empty + unknown means "not fetched yet".
  Map<int, String> itemSwitchNames = {};
  List<int> itemSwitchIds = [];
  bool itemSwitchKnown = false;

  List<Map<String, dynamic>> savedAccounts = [];

  Timer? _watchTimer;
  Timer? _rotateTimer;
  final Set<String> _recordedGrabKeys = {};
  bool _engineRebuilding = false;

  AppState({required this.appDir, CredentialStore? store})
    : store = store ?? FileCredentialStore(appDir),
      accounts = AccountStore(appDir),
      background = BackgroundController(appDir),
      historyStore = HistoryStore(
        File('${appDir.path}/dpgrabber_history.json'),
      );

  /// Wallpaper settings + content-addressed image store (wenxi
  /// background system). Persisted under appDir/backgrounds/.
  final BackgroundController background;

  bool get hasSecureStorage => store.isSecureStorage;

  String get currentPhone => loginPhone ?? config.phone;

  int get todaySuccessCount => historyStore.todaySuccessCount();

  Map<HistoryOutcome, int> get todayCounts => historyStore.todayCounts();

  List<HistoryEntry> history({bool allAccounts = false}) =>
      historyStore.entriesForAccount(currentPhone, allAccounts: allAccounts);

  Future<void> init() async {
    try {
      accounts.migrateLegacy();
    } catch (_) {}
    AppConfig loaded;
    final saved = await store.loadAccount();
    if (saved != null) {
      try {
        loaded = accounts.loadAccount(saved.phone);
      } catch (_) {
        loaded = await store.loadConfig();
      }
      loginPhone = FileCredentialStore.digitsOf(saved.phone);
      _password = saved.password;
      loggedIn = true;
    } else {
      loaded = await store.loadConfig();
    }
    config = loaded;
    theme = ThemeController(config.theme);
    voice.enabled = config.voiceEnabled;
    _buildClientAndEngine();
    savedAccounts = accounts.listAccounts();
    await background.load();
    initialized = true;
    if (!hasSecureStorage) {
      logs.add(
        LogLevel.warning,
        store is SecureCredentialStore
            ? SecureCredentialStore.unencryptedWarning
            : FileCredentialStore.unencryptedWarning,
      );
    }
    notifyListeners();
  }

  void _syncListeningFlag() {
    final running = engine?.isRunning ?? false;
    if (running != listening) {
      listening = running;
      notifyListeners();
    }
  }

  void _buildClientAndEngine() {
    client = ApiClient(
      aesKeyHex: config.aesKeyHex,
      aesIvHex: config.aesIvHex,
      aesKeyHexAlt: config.aesKeyHexAlt,
      aesIvHexAlt: config.aesIvHexAlt,
      verifyTls: config.verifyTls,
    );
    notifier = Notifier(config);
    engine = ListenEngine(
      client: client,
      config: config,
      log: (level, message) {
        logs.add(level, message);
        unawaited(keepAlive?.updateStatus(message));
      },
      speak: (text) {
        if (config.voiceEnabled) unawaited(voice.speak(text));
      },
      onGrab: _onGrab,
      onOutcome: _onOutcome,
      onSession: (s) {
        session = s;
        notifyListeners();
      },
    );
  }

  /// Rebuild client + engine (needed when AES keys / TLS change,
  /// because the engine holds the client). Notifies listeners.
  void _rebuildClientAndEngine() {
    if (_engineRebuilding) return;
    _engineRebuilding = true;
    final wasRunning = engine?.isRunning ?? false;
    engine?.stop();
    _buildClientAndEngine();
    _engineRebuilding = false;
    if (wasRunning) {
      logs.add(
        LogLevel.warning,
        '密钥/证书设置已变更，监听已停止，请重新开始监听',
      );
    }
  }

  // -- config ----------------------------------------------------------

  /// Apply a new config: validate via [AppConfig] (callers build it
  /// with `AppConfig.fromJson`, which throws [ConfigError] on invalid
  /// values), persist, push to the engine/notifier/theme.
  Future<void> updateConfig(AppConfig next, {bool persist = true}) async {
    final aesChanged = next.aesKeyHex != config.aesKeyHex ||
        next.aesIvHex != config.aesIvHex ||
        next.aesKeyHexAlt != config.aesKeyHexAlt ||
        next.aesIvHexAlt != config.aesIvHexAlt ||
        next.verifyTls != config.verifyTls;
    final themeChanged = next.theme != config.theme;
    config = next;
    voice.enabled = next.voiceEnabled;
    if (themeChanged) theme.set(next.theme);
    if (aesChanged) {
      _rebuildClientAndEngine();
    } else {
      engine?.updateConfig(next);
      notifier = Notifier(next);
    }
    if (persist) await saveConfig();
    notifyListeners();
  }

  /// Persist the config: per-account file when logged in, plus the
  /// store's own config file (keeps the legacy single file in sync).
  Future<void> saveConfig() async {
    try {
      if (currentPhone.isNotEmpty) {
        accounts.saveAccount(config, phone: currentPhone);
      }
    } catch (_) {}
    try {
      await store.saveConfig(config);
    } catch (_) {}
  }

  /// Theme switch: instant + persisted to the config `theme` key (§9).
  Future<void> setTheme(String id) async {
    await updateConfig(config.copyWith(theme: paletteFor(id).id));
  }

  // -- login -----------------------------------------------------------

  /// Full login via the core (§4.1): verifies the account against the
  /// real API, saves credentials + per-account config, fetches clerk
  /// info and item switches (best effort). Throws [ApiError] on
  /// failure; the caller shows the message.
  Future<Session> login(String phone, String password) async {
    final cleanPhone = phone.trim();
    final s = await client.sessionForAccount(
      cleanPhone,
      password,
      preferredShopId: config.shopId,
    );
    session = s;
    loginPhone = FileCredentialStore.digitsOf(cleanPhone);
    _password = password;
    loggedIn = true;
    lastError = null;
    await store.saveAccount(phone: cleanPhone, password: password);
    config = config.copyWith(phone: cleanPhone);
    await saveConfig();
    savedAccounts = accounts.listAccounts();
    notifyListeners();
    await _refreshClerkAndSwitches();
    return s;
  }

  /// Download and cache the clerk avatar (DPPP `_fetch_avatar`):
  /// source `clerk.avatarUrl`, cached at `<appDir>/avatars/avatar_<id>.png`.
  /// Cosmetic only — never breaks login or listening.
  Future<void> _refreshAvatar(Clerk clerk) async {
    final url = clerk.avatarUrl ?? '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;
    try {
      final dir = Directory('${appDir.path}/avatars');
      await dir.create(recursive: true);
      final file = File('${dir.path}/avatar_${clerk.id}.png');
      if (!await file.exists() || await file.length() < 512) {
        final http = HttpClient();
        http.connectionTimeout = const Duration(seconds: 15);
        try {
          final req = await http.getUrl(Uri.parse(url));
          final resp =
              await req.close().timeout(const Duration(seconds: 15));
          final builder = BytesBuilder();
          await for (final chunk in resp) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.length > 512) {
            await file.writeAsBytes(bytes, flush: true);
          }
        } finally {
          http.close(force: true);
        }
      }
      if (await file.exists() && await file.length() > 512) {
        avatarPath = file.path;
        notifyListeners();
      }
    } catch (_) {
      // Avatar is cosmetic; ignore any failure.
    }
  }

  Future<void> _refreshClerkAndSwitches() async {
    try {
      final raw = await client.clerkGet(session: session);
      clerk = extractClerk(raw);
      // Sync the real online state from the platform (1 online /
      // 2 offline), exactly like DPPP's _fetch_clerk_state ->
      // _set_online_text(status == 1). Without this the switch always
      // showed "当前离线" after login regardless of the real state.
      online = (clerk?.status ?? 0) == 1;
      if (clerk != null && clerk!.id > 0) {
        unawaited(_refreshAvatar(clerk!));
        config = config.copyWith(clerkName: clerk!.name ?? config.clerkName);
        await saveConfig();
      }
    } catch (e) {
      logs.add(LogLevel.warning, '店员信息读取失败，不影响监听：$e');
    }
    try {
      final raw = await client.itemSwitchList(session: session);
      final list = raw['itemSwitchList'];
      final enabled = raw['clerkItemSwitchIds'];
      if (list is List) {
        itemSwitchNames = {
          for (final item in list)
            if (item is Map && item['id'] is num)
              (item['id'] as num).toInt():
                  (item['name'] ?? '').toString(),
        };
      }
      if (enabled is List) {
        itemSwitchIds = [
          for (final v in enabled)
            if (v is num) v.toInt(),
        ];
      }
      itemSwitchKnown = true;
      config = config.copyWith(
        itemSwitchIds: itemSwitchIds,
        itemSwitchKnown: true,
        itemSwitchNames: {
          for (final e in itemSwitchNames.entries)
            e.key.toString(): e.value,
        },
      );
      await saveConfig();
    } catch (e) {
      logs.add(LogLevel.warning, '接单类型列表拉取失败：$e');
    }
    notifyListeners();
  }

  /// Switch to a saved account: loads its config + credentials and
  /// re-logs in. Returns false (with [lastError] set) on failure.
  Future<bool> switchAccount(String phone) async {
    final digits = FileCredentialStore.digitsOf(phone);
    try {
      if (store is FileCredentialStore) {
        (store as FileCredentialStore).activePhone = digits;
      } else if (store is SecureCredentialStore) {
        (store as SecureCredentialStore).activePhone = digits;
      }
      final saved = await store.loadAccount();
      if (saved == null) {
        lastError = '找不到该账号的保存凭据';
        return false;
      }
      engine?.stop();
      session = null;
      config = accounts.loadAccount(digits);
      theme.set(config.theme);
      _buildClientAndEngine();
      await login(saved.phone, saved.password);
      _startRotateTimerIfNeeded();
      return true;
    } catch (e) {
      lastError = e.toString();
      logs.add(LogLevel.error, '切换账号失败：$e');
      notifyListeners();
      return false;
    }
  }

  /// Clear the saved account (§10.2): deletes credentials + the
  /// per-account config file, stops listening, returns to login.
  Future<void> clearAccount() async {
    engine?.stop();
    final phone = currentPhone;
    try {
      await store.clearAccount();
    } catch (_) {}
    try {
      if (phone.isNotEmpty) accounts.deleteAccount(phone);
    } catch (_) {}
    session = null;
    clerk = null;
    _password = null;
    loginPhone = null;
    loggedIn = false;
    savedAccounts = accounts.listAccounts();
    notifyListeners();
  }

  // -- listening --------------------------------------------------------

  Future<bool> startListening() async {
    if (engine == null) return false;
    if (currentPhone.isEmpty || _password == null || _password!.isEmpty) {
      lastError = '请先登录并保存账号';
      logs.add(LogLevel.error, '启动失败：请先登录并保存账号');
      notifyListeners();
      return false;
    }
    final ok = await engine!.start(
      currentPhone,
      _password!,
      initialSession: session,
    );
    if (!ok) {
      lastError = '启动失败，请查看运行日志';
      notifyListeners();
      return false;
    }
    listening = true;
    unawaited(keepAlive?.start());
    _startRotateTimerIfNeeded();
    _startWatchTimer();
    notifyListeners();
    return true;
  }

  void stopListening() {
    engine?.stop();
    unawaited(keepAlive?.stop());
    listening = false;
    _watchTimer?.cancel();
    _watchTimer = null;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    notifyListeners();
  }

  /// Watches `engine.isRunning` once a second while listening, so an
  /// engine-side stop (e.g. auto-stop after a grab) is reflected in
  /// the UI. Only runs while listening — a permanent timer would keep
  /// widget tests from settling.
  void _startWatchTimer() {
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        _syncListeningFlag();
        if (!listening) {
          _watchTimer?.cancel();
          _watchTimer = null;
        }
      },
    );
  }

  /// Online switch (§10.3): calls `setOnline`, rolls back on failure.
  Future<bool> setOnline(bool value) async {
    try {
      await client.setOnline(value ? 1 : 2, session: session);
      online = value;
      logs.add(LogLevel.info, value ? '已上线接单' : '已下线');
      notifyListeners();
      return true;
    } catch (e) {
      logs.add(LogLevel.error, '在线状态切换失败：$e');
      notifyListeners();
      return false;
    }
  }

  /// Item-type switch (§6.5): calls `setItemSwitch`, rolls back the
  /// check state on failure; persists immediately (§6.5 UI rule).
  Future<bool> toggleItemSwitch(int switchId, bool enabled) async {
    final next = List<int>.of(itemSwitchIds);
    if (enabled) {
      if (!next.contains(switchId)) next.add(switchId);
    } else {
      next.remove(switchId);
    }
    try {
      await client.setItemSwitch(switchId, next, session: session);
      itemSwitchIds = next;
      await updateConfig(
        config.copyWith(itemSwitchIds: next, itemSwitchKnown: true),
      );
      return true;
    } catch (e) {
      logs.add(LogLevel.error, '接单类型切换失败，已回滚：$e');
      notifyListeners();
      return false;
    }
  }

  /// Week statistics (§10.8): clerkStatistics with the order-total
  /// fallback (core `fetchWeekStatistics`).
  Future<void> refreshWeekStats() async {
    weekStatsLoading = true;
    notifyListeners();
    try {
      final result =
          await fetchWeekStatistics(client, session: session);
      weekStats = result.stats;
      weekFallbackTotal = result.fallbackOrderTotal;
      if (result.stats == null && result.fallbackOrderTotal != null) {
        logs.add(
          LogLevel.warning,
          '本周统计为空，改用订单总数：${result.fallbackOrderTotal}',
        );
      }
    } catch (e) {
      logs.add(LogLevel.warning, '本周统计拉取失败：$e');
    } finally {
      weekStatsLoading = false;
      notifyListeners();
    }
  }

  /// Push test (§8.1): one `send` with test title/body.
  Future<bool> sendTestPush() async {
    final ok = await notifier.send('测试推送', '这是一条来自 DPGrabber 的测试推送');
    logs.add(
      ok ? LogLevel.success : LogLevel.warning,
      ok ? '推送(${notifier.describe()})已发送' : '推送(${notifier.describe()})失败',
    );
    return ok;
  }

  // -- engine callbacks -------------------------------------------------

  void _onGrab(
    Map<String, dynamic> order,
    String orderId,
    int confirmCalls,
  ) {
    final entry = HistoryStore.entryForOrder(
      order: order,
      outcome: HistoryOutcome.success,
      reason: '',
      account: currentPhone,
      clerk: clerk?.name ?? config.clerkName,
    );
    historyStore.append(entry);
    _recordedGrabKeys.add('${entry.no}|${entry.id}');
    unawaited(_pushGrab(entry));
    notifyListeners();
  }

  Future<void> _pushGrab(HistoryEntry entry) async {
    if (onLocalNotification != null) {
      try {
        await onLocalNotification!(
          '抢单成功',
          '已抢到一单，金额 ${entry.amount.toStringAsFixed(2)} 元，请去查看订单。',
        );
      } catch (_) {}
    }
    final ok = await notifier.sendGrab(
      orderNo: entry.no,
      amount: entry.amount,
      grabbedAt: entry.grabbedAt,
    );
    if (notifier.enabled) {
      logs.add(
        ok ? LogLevel.success : LogLevel.warning,
        ok ? '推送(${notifier.describe()})已发送' : '推送(${notifier.describe()})失败',
      );
    }
  }

  void _onOutcome(
    Map<String, dynamic> order,
    HistoryOutcome outcome,
    String reason,
  ) {
    final entry = HistoryStore.entryForOrder(
      order: order,
      outcome: outcome,
      reason: reason,
      account: currentPhone,
      clerk: clerk?.name ?? config.clerkName,
    );
    if (outcome == HistoryOutcome.success &&
        _recordedGrabKeys.contains('${entry.no}|${entry.id}')) {
      return; // already recorded by onGrab (§1.6/§7.3 dedup)
    }
    historyStore.append(entry);
    notifyListeners();
  }

  // -- account rotation (UI layer, §12 Q-12 / core deviation #5) --------

  void _startRotateTimerIfNeeded() {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    if (!config.rotateEnabled) return;
    if (savedAccounts.length < 2) {
      logs.add(
        LogLevel.warning,
        '账号轮换已开启，但只有一个账号，轮换不生效',
      );
      return;
    }
    _rotateTimer = Timer(
      Duration(minutes: config.rotateMinutes),
      _rotateToNextAccount,
    );
  }

  Future<void> _rotateToNextAccount() async {
    final phones = savedAccounts.map((a) => (a['phone'] ?? '').toString()).toList();
    if (phones.length < 2) return;
    final current = FileCredentialStore.digitsOf(currentPhone);
    final idx = phones.indexOf(current);
    final next = phones[(idx + 1) % phones.length];
    logs.add(LogLevel.info, '账号轮换：切换到 $next');
    final wasListening = listening;
    stopListening();
    final ok = await switchAccount(next);
    if (ok && wasListening) {
      await startListening();
    }
  }

  @override
  void dispose() {
    _watchTimer?.cancel();
    _rotateTimer?.cancel();
    engine?.stop();
    super.dispose();
  }
}
