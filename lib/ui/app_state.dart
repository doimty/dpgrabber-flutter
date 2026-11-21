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
/// Credential storage: plain local file ([FileCredentialStore]),
/// the same as the DPPP PC build — the file store is the design on
/// all platforms, not a fallback. The platform secure store is
/// namespaced by the signing identity, and a re-signed IPA cannot
/// read items saved by a differently-signed build, so it
/// silently lost logins on relaunch; the file survives re-signing.
///
/// Session: this class is the single source of truth for the live
/// session. The saved account alone is NOT a session — after a cold
/// start `session` is null until [ensureSession] builds one from the
/// saved credentials (see [init]). There is no sign-out button: the
/// account stays signed in until its saved credentials are cleared
/// ([clearAccount]).
library;

import 'dart:async';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

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

class AppState extends ChangeNotifier with WidgetsBindingObserver {
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

  /// The live session — the single source of truth (§10.2). The
  /// setter is the ONE sync point to the client's mirror:
  /// every assignment here also writes `client.session`, and nothing
  /// else writes the mirror. The client never reads its mirror for
  /// requests (see `ApiClient.request`): every authenticated call
  /// takes this session explicitly.
  Session? _session;
  Session? get session => _session;
  set session(Session? value) {
    _session = value;
    client.session = value;
  }

  Clerk? clerk;
  bool initialized = false;
  bool loggedIn = false;

  /// True while a session rebuild is in flight (cold-start restore,
  /// or any [ensureSession] that actually runs the login chain).
  /// The listen hero shows the cached shop identity with a weak
  /// "同步中…" state while this is true — never as logged-in.
  bool sessionRestoring = false;
  Future<bool>? _sessionFuture;
  String? loginPhone;
  String? _password; // in-memory only, never persisted by this class
  bool online = false;

  /// Cached clerk avatar file path (empty = show the letter fallback).
  String avatarPath = '';
  bool listening = false;
  String? lastError;
  KeepAliveStatus? keepAliveStatus;
  DateTime? currentPollStartedAt;
  DateTime? lastPollStartedAt;
  DateTime? lastPollAt;
  Duration? lastPollDuration;
  bool? lastPollSucceeded;
  int completedPollCount = 0;
  int failedPollCount = 0;
  AppLifecycleState? lastLifecycleState;
  DateTime? lastLifecycleChangeAt;
  DateTime? lastBackgroundedAt;
  DateTime? lastResumedAt;

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
  int _listenGeneration = 0;
  bool _listenRequested = false;
  int _accountGeneration = 0;
  int _sessionRestoreGeneration = 0;
  Future<bool>? _startListeningFuture;
  bool _keepAliveCheckInFlight = false;
  bool _keepAliveRepairRequested = false;
  Future<void> _keepAliveQueue = Future<void>.value();
  bool _lifecycleObserverRegistered = false;
  bool _disposed = false;
  bool _accountSwitchInProgress = false;
  int _accountSwitchGeneration = 0;

  AppState({required this.appDir, CredentialStore? store, this._transport})
    : store = store ?? FileCredentialStore(appDir),
      accounts = AccountStore(appDir),
      background = BackgroundController(appDir),
      historyStore = HistoryStore(
        File('${appDir.path}/dpgrabber_history.json'),
      );

  /// Test seam: fake network for the client. Null in production
  /// (the client builds its own `HttpClientTransport`).
  final HttpTransport? _transport;

  /// Wallpaper settings + content-addressed image store (wenxi
  /// background system). Persisted under appDir/backgrounds/.
  final BackgroundController background;

  String get currentPhone => loginPhone ?? config.phone;

  int get todaySuccessCount => historyStore.todaySuccessCount();

  Map<HistoryOutcome, int> get todayCounts => historyStore.todayCounts();

  List<HistoryEntry> history({bool allAccounts = false}) =>
      historyStore.entriesForAccount(currentPhone, allAccounts: allAccounts);

  Future<void> init() async {
    if (!_lifecycleObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverRegistered = true;
    }
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
    if (!_disposed) notifyListeners();
    // A saved account is not a live session: rebuild it in the
    // background so the listen page never reads "未登录" after a
    // cold start and week stats never 401 on a null session.
    // Best-effort only — a failure is logged, never surfaced, and
    // never clears the saved account.
    if (loggedIn) unawaited(_restoreSessionInBackground());
  }

  void _syncListeningFlag() {
    final running = engine?.isRunning ?? false;
    if (running != listening) {
      listening = running;
      if (!running) {
        _cancelListeningSupport(stopEngine: false, notify: false);
      }
      if (!_disposed) notifyListeners();
    }
  }

  void _buildClientAndEngine() {
    client = ApiClient(
      aesKeyHex: config.aesKeyHex,
      aesIvHex: config.aesIvHex,
      aesKeyHexAlt: config.aesKeyHexAlt,
      aesIvHexAlt: config.aesIvHexAlt,
      verifyTls: config.verifyTls,
      transport: _transport,
    );
    // A fresh client starts with a null mirror: sync the live
    // session (if any) back into it.
    client.session = _session;
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
      onPollStarted: (startedAt) {
        if (_disposed) return;
        currentPollStartedAt = startedAt;
        notifyListeners();
      },
      onPoll: (startedAt, completedAt, duration, succeeded) {
        if (_disposed) return;
        currentPollStartedAt = null;
        lastPollStartedAt = startedAt;
        lastPollAt = completedAt;
        lastPollDuration = duration;
        lastPollSucceeded = succeeded;
        if (succeeded) {
          completedPollCount++;
        } else {
          failedPollCount++;
        }
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
    if (wasRunning) {
      _cancelListeningSupport(stopEngine: false, notify: false);
    }
    _buildClientAndEngine();
    _engineRebuilding = false;
    if (wasRunning) {
      logs.add(LogLevel.warning, '密钥/证书设置已变更，监听已停止，请重新开始监听');
    }
  }

  // -- config ----------------------------------------------------------

  /// Apply a new config: validate via [AppConfig] (callers build it
  /// with `AppConfig.fromJson`, which throws [ConfigError] on invalid
  /// values), persist, push to the engine/notifier/theme.
  Future<void> updateConfig(AppConfig next, {bool persist = true}) async {
    final aesChanged =
        next.aesKeyHex != config.aesKeyHex ||
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
    final accountGeneration = ++_accountGeneration;
    _sessionFuture = null;
    _sessionRestoreGeneration++;
    sessionRestoring = false;
    _startListeningFuture = null;
    final cleanPhone = phone.trim();
    final activeClient = client;
    final preferredShopId = config.shopId;
    final s = await activeClient.sessionForAccount(
      cleanPhone,
      password,
      preferredShopId: preferredShopId,
    );
    if (accountGeneration != _accountGeneration ||
        !identical(activeClient, client)) {
      throw const ApiError(ApiErrorKind.cancelled, 'login superseded');
    }
    session = s;
    loginPhone = FileCredentialStore.digitsOf(cleanPhone);
    _password = password;
    loggedIn = true;
    lastError = null;
    await store.saveAccount(phone: cleanPhone, password: password);
    _throwIfLoginSuperseded(accountGeneration, activeClient);
    config = config.copyWith(phone: cleanPhone);
    await saveConfig();
    _throwIfLoginSuperseded(accountGeneration, activeClient);
    savedAccounts = accounts.listAccounts();
    notifyListeners();
    await _refreshClerkAndSwitches(
      accountGeneration: accountGeneration,
      expectedClient: activeClient,
      expectedSession: s,
    );
    _throwIfLoginSuperseded(accountGeneration, activeClient);
    return s;
  }

  void _throwIfLoginSuperseded(int generation, ApiClient activeClient) {
    if (_disposed ||
        generation != _accountGeneration ||
        !identical(activeClient, client)) {
      throw const ApiError(ApiErrorKind.cancelled, 'login superseded');
    }
  }

  /// Build (or rebuild) the live session from the saved credentials
  /// (§10.2). The saved account alone is not a session, so any
  /// authenticated entry calls this first when [session] is null.
  /// Returns false when there are no saved credentials or the login
  /// fails; never clears the saved account, never throws.
  ///
  /// Concurrent callers share one in-flight login chain
  /// ([_sessionFuture]): the background restore, the stats
  /// auto-refresh and start-listening must not each run the full
  /// 6–7 request chain.
  Future<bool> ensureSession() async {
    if (_accountSwitchInProgress) return false;
    if (session != null) return true;
    final inFlight = _sessionFuture;
    if (inFlight != null) return inFlight;
    final phone = loginPhone;
    final password = _password;
    if (phone == null ||
        phone.isEmpty ||
        password == null ||
        password.isEmpty) {
      return false;
    }
    final generation = _accountGeneration;
    final restoreGeneration = ++_sessionRestoreGeneration;
    final activeClient = client;
    final preferredShopId = config.shopId;
    final future = _ensureSessionLocked(
      phone,
      password,
      generation,
      restoreGeneration,
      activeClient,
      preferredShopId,
    );
    _sessionFuture = future;
    try {
      return await future;
    } finally {
      if (_sessionFuture == future) _sessionFuture = null;
    }
  }

  Future<bool> _ensureSessionLocked(
    String phone,
    String password,
    int accountGeneration,
    int restoreGeneration,
    ApiClient activeClient,
    int preferredShopId,
  ) async {
    sessionRestoring = true;
    notifyListeners();
    try {
      final s = await activeClient.sessionForAccount(
        phone,
        password,
        preferredShopId: preferredShopId,
      );
      if (accountGeneration != _accountGeneration ||
          !identical(activeClient, client)) {
        return false;
      }
      session = s;
      lastError = null;
      notifyListeners();
      return true;
    } catch (e) {
      if (accountGeneration == _accountGeneration &&
          identical(activeClient, client)) {
        logs.add(LogLevel.warning, '自动登录失败：$e');
      }
      return false;
    } finally {
      if (restoreGeneration == _sessionRestoreGeneration) {
        sessionRestoring = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// Cold-start restore (§10.2): after [init] restores the saved
  /// account, rebuild the live session in the background (never
  /// blocks the shell), then refresh clerk info + item switches so
  /// the listen page is fully live without a manual login, then
  /// refresh the week stats once (the manual button stays as a
  /// retry).
  Future<void> _restoreSessionInBackground() async {
    final generation = _accountGeneration;
    if (!await ensureSession()) return;
    if (_disposed || generation != _accountGeneration) return;
    final activeClient = client;
    final activeSession = session;
    if (activeSession == null) return;
    await _refreshClerkAndSwitches(
      accountGeneration: generation,
      expectedClient: activeClient,
      expectedSession: activeSession,
    );
    if (!_disposed &&
        generation == _accountGeneration &&
        identical(activeClient, client) &&
        identical(activeSession, session)) {
      unawaited(refreshWeekStats());
    }
  }

  /// Download and cache the clerk avatar (DPPP `_fetch_avatar`):
  /// source `clerk.avatarUrl`, cached at `<appDir>/avatars/avatar_<id>.png`.
  /// Cosmetic only — never breaks login or listening.
  Future<void> _refreshAvatar(
    Clerk clerk, {
    required int accountGeneration,
  }) async {
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
          final resp = await req.close().timeout(const Duration(seconds: 15));
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
        if (_disposed || accountGeneration != _accountGeneration) return;
        avatarPath = file.path;
        notifyListeners();
      }
    } catch (_) {
      // Avatar is cosmetic; ignore any failure.
    }
  }

  /// Refresh clerk info + item switches after a (re)login. The two
  /// fetches run concurrently (both need only the session), but the
  /// results are merged into ONE config update + ONE save afterwards:
  /// each fetch's `copyWith` starts from the same config, so writing
  /// them separately would let the later write clobber the earlier
  /// field update.
  Future<void> _refreshClerkAndSwitches({
    int? accountGeneration,
    ApiClient? expectedClient,
    Session? expectedSession,
  }) async {
    final generation = accountGeneration ?? _accountGeneration;
    final activeClient = expectedClient ?? client;
    final activeSession = expectedSession ?? session;
    if (_disposed ||
        generation != _accountGeneration ||
        !identical(activeClient, client) ||
        !identical(activeSession, session)) {
      return;
    }
    final results = await Future.wait([
      _fetchClerk(client: activeClient, session: activeSession),
      _fetchItemSwitches(client: activeClient, session: activeSession),
    ]);
    if (_disposed ||
        generation != _accountGeneration ||
        !identical(activeClient, client) ||
        !identical(activeSession, session)) {
      return;
    }
    final clerkData = results[0] as ({Clerk? clerk, bool online})?;
    final switchData = results[1] as ({Map<int, String> names, List<int> ids})?;
    var next = config;
    var changed = false;
    if (clerkData != null) {
      clerk = clerkData.clerk;
      online = clerkData.online;
      final found = clerkData.clerk;
      if (found != null && found.id > 0) {
        unawaited(_refreshAvatar(found, accountGeneration: generation));
        final name = found.name ?? config.clerkName;
        if (name != config.clerkName || found.id != config.clerkId) {
          next = next.copyWith(clerkName: name, clerkId: found.id);
          changed = true;
        }
      }
    }
    if (switchData != null) {
      itemSwitchNames = switchData.names;
      itemSwitchIds = switchData.ids;
      itemSwitchKnown = true;
      next = next.copyWith(
        itemSwitchIds: switchData.ids,
        itemSwitchKnown: true,
        itemSwitchNames: {
          for (final e in switchData.names.entries) e.key.toString(): e.value,
        },
      );
      changed = true;
    }
    if (changed) {
      config = next;
      await saveConfig();
      if (_disposed ||
          generation != _accountGeneration ||
          !identical(activeClient, client) ||
          !identical(activeSession, session)) {
        return;
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// Fetch the clerk (reusing the login probe's clerk/get response
  /// when it was captured for this session, so a cold start does not
  /// call clerk/get twice). Returns null on failure (logged).
  Future<({Clerk? clerk, bool online})?> _fetchClerk({
    required ApiClient client,
    required Session? session,
  }) async {
    final s = session;
    if (s == null) return null;
    try {
      final raw =
          client.takeCachedClerkRaw(s) ?? await client.clerkGet(session: s);
      final found = extractClerk(raw);
      // Sync the real online state from the platform (1 online /
      // 2 offline), exactly like DPPP's _fetch_clerk_state ->
      // _set_online_text(status == 1). Without this the switch always
      // showed "当前离线" after login regardless of the real state.
      return (clerk: found, online: (found?.status ?? 0) == 1);
    } catch (e) {
      logs.add(LogLevel.warning, '店员信息读取失败，不影响监听：$e');
      return null;
    }
  }

  /// Fetch the item-type switch list. Returns null on failure
  /// (logged); an empty-but-successful response still counts as
  /// known, exactly like the old sequential code.
  Future<({Map<int, String> names, List<int> ids})?> _fetchItemSwitches({
    required ApiClient client,
    required Session? session,
  }) async {
    try {
      final raw = await client.itemSwitchList(session: session);
      final list = raw['itemSwitchList'];
      final enabled = raw['clerkItemSwitchIds'];
      final names = <int, String>{
        if (list is List)
          for (final item in list)
            if (item is Map && item['id'] is num)
              (item['id'] as num).toInt(): (item['name'] ?? '').toString(),
      };
      final ids = <int>[
        if (enabled is List)
          for (final v in enabled)
            if (v is num) v.toInt(),
      ];
      return (names: names, ids: ids);
    } catch (e) {
      logs.add(LogLevel.warning, '接单类型列表拉取失败：$e');
      return null;
    }
  }

  /// Switch to a saved account: loads its config + credentials and
  /// re-logs in. Returns false (with [lastError] set) on failure.
  Future<bool> switchAccount(String phone) async {
    _invalidateAccountWork();
    final switchOperation = ++_accountSwitchGeneration;
    _accountSwitchInProgress = true;
    final switchGeneration = _accountGeneration;
    _cancelListeningSupport(notify: false);
    final digits = FileCredentialStore.digitsOf(phone);
    try {
      if (store is FileCredentialStore) {
        (store as FileCredentialStore).activePhone = digits;
      }
      final saved = await store.loadAccount();
      if (switchGeneration != _accountGeneration) return false;
      if (saved == null) {
        lastError = '找不到该账号的保存凭据';
        return false;
      }
      session = null;
      config = accounts.loadAccount(digits);
      theme.set(config.theme);
      _buildClientAndEngine();
      await login(saved.phone, saved.password);
      if (_accountGeneration != switchGeneration + 1) return false;
      _startRotateTimerIfNeeded();
      return true;
    } catch (e) {
      if (_accountGeneration != switchGeneration + 1) return false;
      lastError = e.toString();
      logs.add(LogLevel.error, '切换账号失败：$e');
      notifyListeners();
      return false;
    } finally {
      if (switchOperation == _accountSwitchGeneration) {
        _accountSwitchInProgress = false;
      }
    }
  }

  /// Clear the saved account (§10.2): deletes credentials + the
  /// per-account config file, stops listening, returns to login.
  Future<void> clearAccount() async {
    _invalidateAccountWork();
    _cancelListeningSupport(notify: false);
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

  void _invalidateAccountWork() {
    _accountGeneration++;
    _sessionFuture = null;
    _sessionRestoreGeneration++;
    sessionRestoring = false;
    _startListeningFuture = null;
  }

  Future<bool> startListening() {
    final inFlight = _startListeningFuture;
    if (inFlight != null) return inFlight;
    final future = _startListening();
    _startListeningFuture = future;
    return future.whenComplete(() {
      if (identical(_startListeningFuture, future)) {
        _startListeningFuture = null;
      }
    });
  }

  Future<bool> _startListening() async {
    if (_accountSwitchInProgress) return false;
    if (engine == null) return false;
    final generation = ++_listenGeneration;
    final accountGeneration = _accountGeneration;
    _listenRequested = true;
    currentPollStartedAt = null;
    if (currentPhone.isEmpty || _password == null || _password!.isEmpty) {
      _listenRequested = false;
      lastError = '请先去设置页登录账号';
      logs.add(LogLevel.error, '启动失败：请先去设置页登录账号');
      notifyListeners();
      return false;
    }
    // Cold start leaves `session` null until the background restore
    // finishes: build it now so the engine reuses a live session
    // instead of logging in again (and so the hero shows the shop
    // from the moment listening starts). The engine still logs in
    // itself when this fails.
    await ensureSession();
    if (!_listenAttemptIsCurrent(generation, accountGeneration)) {
      if (generation == _listenGeneration &&
          accountGeneration != _accountGeneration) {
        _cancelListeningSupport();
      }
      return false;
    }
    final activeEngine = engine;
    if (activeEngine == null) return false;
    final ok = await activeEngine.start(
      currentPhone,
      _password!,
      initialSession: session,
    );
    if (!_listenAttemptIsCurrent(generation, accountGeneration)) {
      if (generation == _listenGeneration &&
          accountGeneration != _accountGeneration) {
        _cancelListeningSupport();
      }
      return false;
    }
    if (!ok) {
      _listenRequested = false;
      lastError = '启动失败，请查看运行日志';
      notifyListeners();
      return false;
    }
    listening = true;
    _startWatchTimer();
    _startRotateTimerIfNeeded();
    notifyListeners();
    await _synchronizeKeepAlive();
    if (!_listenAttemptIsCurrent(generation, accountGeneration)) {
      if (generation == _listenGeneration &&
          accountGeneration != _accountGeneration) {
        _cancelListeningSupport();
      }
      return false;
    }
    return true;
  }

  void stopListening() {
    _cancelListeningSupport();
  }

  bool _listenAttemptIsCurrent(int generation, int accountGeneration) =>
      _listenRequested &&
      generation == _listenGeneration &&
      accountGeneration == _accountGeneration;

  void _cancelListeningSupport({bool stopEngine = true, bool notify = true}) {
    _listenGeneration++;
    _listenRequested = false;
    currentPollStartedAt = null;
    _startListeningFuture = null;
    if (stopEngine) engine?.stop();
    listening = false;
    _watchTimer?.cancel();
    _watchTimer = null;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    unawaited(_synchronizeKeepAlive());
    if (notify) notifyListeners();
  }

  /// Serialize native transitions so an older start cannot overtake a newer
  /// stop after an account change or a quick stop/start sequence.
  Future<T> _serializeKeepAlive<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _keepAliveQueue = _keepAliveQueue.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _synchronizeKeepAlive() async {
    await _serializeKeepAlive(() async {
      final shouldRun = _listenRequested && (engine?.isRunning ?? false);
      if (shouldRun) {
        final started = await keepAlive?.start() ?? false;
        if (Platform.isIOS) {
          keepAliveStatus = await keepAlive?.status;
          if (!started) {
            logs.add(LogLevel.warning, 'iOS 音频保活未运行，当前只可在前台监听');
          }
        }
      } else {
        await keepAlive?.stop();
        if (Platform.isIOS) {
          keepAliveStatus = await keepAlive?.status;
        }
      }
    });
    if (!_disposed) notifyListeners();
  }

  Future<void> _refreshKeepAliveStatus({bool repair = false}) async {
    if (!Platform.isIOS || _disposed) return;
    if (_keepAliveCheckInFlight) {
      _keepAliveRepairRequested |= repair;
      return;
    }
    _keepAliveCheckInFlight = true;
    try {
      await _serializeKeepAlive(() async {
        final status = await keepAlive?.status;
        keepAliveStatus = status;
        if (repair &&
            _listenRequested &&
            (engine?.isRunning ?? false) &&
            status?.isRunning != true) {
          final started = await keepAlive?.start() ?? false;
          keepAliveStatus = await keepAlive?.status;
          if (!started) {
            logs.add(LogLevel.warning, '返回前台后音频保活恢复失败');
          }
        }
      });
    } finally {
      _keepAliveCheckInFlight = false;
      if (!_disposed) notifyListeners();
      if (!_disposed && _keepAliveRepairRequested) {
        _keepAliveRepairRequested = false;
        unawaited(_refreshKeepAliveStatus(repair: true));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lastLifecycleState = state;
    final changedAt = DateTime.now().toUtc();
    lastLifecycleChangeAt = changedAt;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      lastBackgroundedAt = changedAt;
    } else if (state == AppLifecycleState.resumed) {
      lastResumedAt = changedAt;
    }
    if (!_disposed) notifyListeners();
    if (state == AppLifecycleState.resumed && _listenRequested) {
      unawaited(_refreshKeepAliveStatus(repair: true));
    }
  }

  /// Watches `engine.isRunning` once a second while listening, so an
  /// engine-side stop (e.g. auto-stop after a grab) is reflected in
  /// the UI. Only runs while listening — a permanent timer would keep
  /// widget tests from settling.
  void _startWatchTimer() {
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncListeningFlag();
      if (!listening) {
        _watchTimer?.cancel();
        _watchTimer = null;
        return;
      }
      if (DateTime.now().second % 5 == 0) {
        unawaited(_refreshKeepAliveStatus());
      }
    });
  }

  /// Online switch (§10.3): calls `setOnline`, rolls back on failure.
  Future<bool> setOnline(bool value) async {
    if (!await ensureSession()) {
      logs.add(LogLevel.error, '在线状态切换失败：未登录');
      notifyListeners();
      return false;
    }
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
    if (!await ensureSession()) {
      logs.add(LogLevel.error, '接单类型切换失败：未登录');
      notifyListeners();
      return false;
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
      // A null session here used to call the API with no auth headers
      // and log a 401: build the session from the saved credentials
      // first, and skip the call entirely when there is nothing to
      // log in with.
      if (!await ensureSession()) {
        logs.add(LogLevel.warning, '本周统计拉取失败：未登录');
        return;
      }
      final result = await fetchWeekStatistics(client, session: session);
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

  void _onGrab(Map<String, dynamic> order, String orderId, int confirmCalls) {
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
      logs.add(LogLevel.warning, '账号轮换已开启，但只有一个账号，轮换不生效');
      return;
    }
    _rotateTimer = Timer(
      Duration(minutes: config.rotateMinutes),
      _rotateToNextAccount,
    );
  }

  Future<void> _rotateToNextAccount() async {
    final phones = savedAccounts
        .map((a) => (a['phone'] ?? '').toString())
        .toList();
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
    _disposed = true;
    _invalidateAccountWork();
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    _watchTimer?.cancel();
    _rotateTimer?.cancel();
    _cancelListeningSupport(notify: false);
    super.dispose();
  }
}
