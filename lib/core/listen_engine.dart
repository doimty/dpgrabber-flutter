/// Listening engine: poll loop + confirm task (PORTING_CONTRACT §3, §6).
///
/// Ported from `pc/engine.py` (`Engine`). One order at a time, serial;
/// polling pauses while a confirm task runs. Progress is reported
/// through the [log] / [speak] / [onGrab] / [onOutcome] / [onSession]
/// callbacks; the engine never touches UI directly and never imports
/// any Flutter UI package.
library;

import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import 'api_client.dart';
import 'config.dart';
import 'confirm.dart';
import 'models.dart';
import 'order_filter.dart';

enum LogLevel { debug, info, warning, error, success }

typedef LogCallback = void Function(LogLevel level, String message);
typedef SpeakCallback = void Function(String text);

/// Outcome of one poll round's confirm handling, for the loop.
typedef ConfirmTaskResult = ({ConfirmTaskOutcome outcome, String reason});

class ListenEngine {
  final ApiClient client;
  AppConfig config;
  final LogCallback log;
  final SpeakCallback? speak;
  final void Function(Map<String, dynamic> order, String orderId,
      int confirmCalls)? onGrab;
  final void Function(Map<String, dynamic> order, HistoryOutcome outcome,
      String reason)? onOutcome;
  final void Function(Session session)? onSession;
  final DateTime Function()? now;
  final Duration Function()? monotonic;
  final Random _rng;

  bool _running = false;
  bool _stopped = false;
  Clerk? _clerk;
  final Map<String, DateTime> _seen = {};
  int _consecutiveFailures = 0;
  bool _shapeLogged = false;
  bool _itemDecisionLogged = false;
  bool _noItemFieldNoted = false;
  bool _continueNoted = false;
  final Set<String> _grabbedKeys = {};

  ListenEngine({
    required this.client,
    required this.config,
    required this.log,
    this.speak,
    this.onGrab,
    this.onOutcome,
    this.onSession,
    this.now,
    this.monotonic,
    Random? rng,
  }) : _rng = rng ?? Random();

  bool get isRunning => _running;
  Clerk? get clerk => _clerk;

  /// Replace the live config (e.g. after the user edits settings while
  /// listening). The filter is rebuilt every poll round (§6.2), so the
  /// new config takes effect on the next round.
  void updateConfig(AppConfig next) => config = next;

  DateTime _now() => now?.call() ?? DateTime.now();

  Duration _monotonic() =>
      monotonic?.call() ??
      Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);

  void _speak(String text) {
    if (text.isEmpty) return;
    try {
      speak?.call(text);
    } catch (_) {
      // Speaking must never break listening.
    }
  }

  /// Start listening. Returns false when already running or when the
  /// confirm-wait config is invalid (the error is logged). The loop
  /// runs asynchronously; this future completes as soon as the loop
  /// has been kicked off.
  Future<bool> start(String phone, String password,
      {Session? initialSession}) async {
    if (_running) return false;
    final waitError = confirmWaitError(config.toJson());
    if (waitError != null) {
      log(LogLevel.error, '确认等待配置无效，无法开始监听：$waitError');
      return false;
    }
    _stopped = false;
    _running = true;
    unawaited(_run(phone, password, initialSession));
    return true;
  }

  /// Ask the loop (and any confirm task) to stop. The loop logs
  /// '监听已停止' when it actually exits.
  void stop() {
    _stopped = true;
    _running = false;
  }

  // -- sleep / seen ---------------------------------------------------

  /// Interruptible sleep; false when asked to stop.
  Future<bool> sleep(double seconds) async {
    if (seconds <= 0) return !_stopped;
    final deadline = _monotonic() +
        Duration(milliseconds: (seconds * 1000).round());
    while (!_stopped) {
      if (_monotonic() >= deadline) return true;
      final remaining = deadline - _monotonic();
      final step = remaining < const Duration(milliseconds: 50)
          ? remaining
          : const Duration(milliseconds: 50);
      await Future.delayed(step);
    }
    return false;
  }

  @visibleForTesting
  void markSeen(String orderId) {
    final nowDt = _now();
    final ttl = Duration(
        milliseconds: (config.seenTtlSec * 1000).round());
    _seen.removeWhere((_, seenAt) => nowDt.difference(seenAt) >= ttl);
    if (orderId.isNotEmpty) _seen[orderId] = nowDt;
  }

  @visibleForTesting
  bool isSeen(String orderId) {
    if (orderId.isEmpty) return false;
    final seenAt = _seen[orderId];
    if (seenAt == null) return false;
    final ttl =
        Duration(milliseconds: (config.seenTtlSec * 1000).round());
    return _now().difference(seenAt) < ttl;
  }

  @visibleForTesting
  void releaseSeen(String orderId) => _seen.remove(orderId);

  int _ownClerkId() => _clerk?.id ?? 0;

  // -- delays ---------------------------------------------------------

  /// Poll delay: `poll_interval_sec ± uniform(-jitter, +jitter)`,
  /// floored at 0.1 s (§6.1, D-02).
  @visibleForTesting
  double pollDelay() {
    final base = config.pollIntervalSec;
    final jitter = config.pollJitterSec;
    if (jitter <= 0) return base < 0.1 ? 0.1 : base;
    final delay = base + _rng.nextDouble() * (2 * jitter) - jitter;
    return delay < 0.1 ? 0.1 : delay;
  }

  /// Consecutive-failure backoff (§6.3): `min(cap, 1.0 * 1.7^(n-1))`
  /// with ±20% jitter, clamped to [0.2, cap].
  @visibleForTesting
  double failureDelay(int fails) {
    final cap = config.pollFailureMaxSec;
    var delay = 1.0 * pow(1.7, (fails - 1).clamp(0, 1 << 30)).toDouble();
    if (delay > cap) delay = cap;
    final jittered = delay * (1.0 + _rng.nextDouble() * 0.4 - 0.2);
    final clamped = jittered.clamp(0.2, cap);
    return clamped;
  }

  @visibleForTesting
  OrderFilter buildFilter() => OrderFilter.fromConfig(config);

  int? currentShopId() {
    final sid = client.session?.sid;
    if (sid != null) {
      final parsed = int.tryParse(sid.trim());
      if (parsed != null) return parsed;
    }
    final configured = config.shopId;
    return configured == 0 ? null : configured;
  }

  double _nextRunSeconds() {
    final min = config.riskRunMin.toDouble();
    var max = config.riskRunMax.toDouble();
    if (max < min) max = min;
    return _rng.nextDouble() * (max - min) + min;
  }

  double _nextRestSeconds() {
    final min = config.riskRestMin.toDouble();
    var max = config.riskRestMax.toDouble();
    if (max < min) max = min;
    return _rng.nextDouble() * (max - min) + min;
  }

  // -- lifecycle ------------------------------------------------------

  Future<void> _run(
      String phone, String password, Session? initialSession) async {
    try {
      Session session;
      if (initialSession != null && initialSession.token.isNotEmpty) {
        session = initialSession;
        client.session = session;
        log(LogLevel.info, '复用已登录会话，店铺 sid=${session.sid}');
      } else {
        log(LogLevel.info, '正在登录…');
        session = await client.sessionForAccount(
          phone,
          password,
          preferredShopId: config.shopId,
        );
        log(LogLevel.success, '登录成功，店铺 sid=${session.sid}');
      }
      try {
        onSession?.call(session);
      } catch (_) {}
      try {
        final decoded = await client.clerkGet(session: session);
        final found = extractClerk(decoded);
        if (found != null) {
          _clerk = found;
          log(LogLevel.info,
              '当前账号：${found.name ?? ''}（ID：${found.id}）');
        }
      } on ApiError catch (e) {
        log(LogLevel.warning, '店员信息读取失败，不影响监听：${e.message}');
      }
      await _pollLoop(phone, password);
    } on ApiError catch (e) {
      log(LogLevel.error, '启动失败：${e.message}');
      _speak('启动失败');
    } finally {
      _running = false;
      log(LogLevel.info, '监听已停止');
    }
  }

  Future<bool> refreshSession(String phone, String password) async {
    try {
      final session = await client.sessionForAccount(
        phone,
        password,
        preferredShopId: config.shopId,
      );
      log(LogLevel.success, '会话已重新建立，店铺 sid=${session.sid}');
      try {
        onSession?.call(session);
      } catch (_) {}
      return true;
    } on ApiError catch (e) {
      log(LogLevel.error, '重新登录失败：${e.message}');
      return false;
    }
  }

  // -- poll loop (§6.1) ------------------------------------------------

  Future<void> _pollLoop(String phone, String password) async {
    final pageSize = 20;
    final timeout = config.requestTimeoutSec;
    final runRestEnabled = config.runRestEnabled;
    Duration? runDeadline;
    if (runRestEnabled) {
      runDeadline = _monotonic() +
          Duration(milliseconds: (_nextRunSeconds() * 60 * 1000).round());
    }
    log(LogLevel.info, '开始监听新订单');
    while (!_stopped) {
      if (runRestEnabled &&
          runDeadline != null &&
          _monotonic() >= runDeadline) {
        final rest = _nextRestSeconds();
        if (rest > 0) {
          log(LogLevel.info,
              '进入休息：暂停监听约 ${(rest / 60.0).toStringAsFixed(1)} 分钟');
          if (!await sleep(rest * 60)) return;
          log(LogLevel.info, '休息结束，恢复监听');
        }
        runDeadline = _monotonic() +
            Duration(milliseconds: (_nextRunSeconds() * 60 * 1000).round());
      }
      List<Map<String, dynamic>> orders;
      try {
        orders = await client.randomList(
            pageSize: pageSize, timeoutSec: timeout);
      } on ApiError catch (e) {
        if (e.kind == ApiErrorKind.auth) {
          log(LogLevel.warning, '登录态失效，尝试重新登录…');
          if (!await refreshSession(phone, password)) return;
          continue;
        }
        if (e.kind == ApiErrorKind.ip) {
          log(LogLevel.warning, 'IP 风控，暂停 60 秒');
          if (!await sleep(60)) return;
          continue;
        }
        _consecutiveFailures += 1;
        final fails = _consecutiveFailures;
        if (fails == 1 || fails % 10 == 0) {
          log(LogLevel.warning, '监听请求失败（连续 $fails 次）：${e.message}');
        }
        if (!await sleep(failureDelay(fails))) return;
        continue;
      }
      if (_consecutiveFailures > 0) {
        log(LogLevel.info,
            '网络恢复，继续监听（此前连续失败 $_consecutiveFailures 次）');
      }
      _consecutiveFailures = 0;
      if (orders.isNotEmpty && !_shapeLogged) {
        _shapeLogged = true;
        final keys = orders[0].keys.toList()..sort();
        log(LogLevel.debug, '订单字段：${keys.join(', ')}');
        final related = <String, dynamic>{};
        for (final entry in orders[0].entries) {
          final lower = entry.key.toLowerCase();
          if (lower.contains('item') ||
              lower.contains('service') ||
              lower.contains('type') ||
              lower.contains('category')) {
            related[entry.key] = entry.value;
          }
        }
        if (related.isNotEmpty) {
          log(LogLevel.debug, '订单类型相关字段：$related');
        }
        final names = orderItemNames(orders[0]);
        if (names.isNotEmpty) {
          log(LogLevel.info, '订单类型名称：${names.join('、')}');
        }
      }
      if (orders.isEmpty) {
        if (!await sleep(pollDelay())) return;
        continue;
      }
      final order = orders[0];
      final orderId = orderIdOf(order);
      if (isSeen(orderId)) {
        if (!await sleep(pollDelay())) return;
        continue;
      }
      markSeen(orderId);
      final filter = buildFilter();
      if (filter.enabledItems.isNotEmpty && !_itemDecisionLogged) {
        _itemDecisionLogged = true;
        final names = orderItemNames(order);
        final decision = orderMatchesItems(order, filter.enabledItems,
            nameMap: filter.itemNameMap,
            alwaysTypes: filter.itemAlwaysTypes);
        log(LogLevel.info,
            '订单类型判定：${names.isEmpty ? '无类型信息' : names.join('、')} → '
            '${decision == true ? '允许' : decision == false ? '已关闭' : '无法判定，放行'}');
      }
      if (filter.enabledItems.isNotEmpty &&
          orderMatchesItems(order, filter.enabledItems,
                  nameMap: filter.itemNameMap,
                  alwaysTypes: filter.itemAlwaysTypes) ==
              null &&
          !_noItemFieldNoted) {
        _noItemFieldNoted = true;
        log(LogLevel.warning, '订单不带类型字段，接单类型联动暂不生效（其他过滤正常）');
      }
      final amount = Order(order).amountYuan;
      log(LogLevel.info,
          '检测到新订单：金额 ${amount.toStringAsFixed(2)} 元，客户微信 ${order['userWechatId'] ?? '未知'}');
      final check = filter.check(order);
      if (!check.passed) {
        log(LogLevel.info, '订单不符合要求：${check.reason}');
        _speak(check.reason);
        continue; // re-poll immediately
      }
      final outcome = await handleOrder(order, orderId, phone, password);
      if (outcome == ConfirmTaskOutcome.busy) {
        final cooldown = config.busyCooldownSec;
        log(LogLevel.info, '等待 ${cooldown.toStringAsFixed(0)} 秒后继续（等店铺释放接单名额）');
        if (!await sleep(cooldown)) return;
        continue;
      }
    }
  }

  // -- confirm task (§3.8) ----------------------------------------------

  /// One confirm task; reports exactly one [onOutcome] for every
  /// terminal outcome except `cancelled` (and except `success` when
  /// the same order was already reported by [onGrab] — §1.6 dedup).
  Future<ConfirmTaskOutcome> handleOrder(Map<String, dynamic> order,
      String orderId, String phone, String password) async {
    final result = await confirmTask(order, orderId, phone, password);
    if (result.outcome != ConfirmTaskOutcome.cancelled) {
      _emitOutcome(order, result.outcome, result.reason);
    }
    return result.outcome;
  }

  void _emitOutcome(Map<String, dynamic> order, ConfirmTaskOutcome outcome,
      String reason) {
    if (onOutcome == null) return;
    final mapped = historyOutcomeFor(outcome);
    if (mapped == null) return;
    // Success is recorded by onGrab; a second success report for the
    // same (no, id) must be skipped (§1.6 / §7.3 dedup).
    if (outcome == ConfirmTaskOutcome.ok) {
      final key = '${Order(order).no}|${Order(order).id}';
      if (_grabbedKeys.contains(key)) return;
    }
    final finalReason =
        reason.isNotEmpty ? reason : defaultReasonFor(mapped);
    try {
      onOutcome!(order, mapped, finalReason);
    } catch (_) {
      // History recording must never break the grab flow.
    }
  }

  Future<({ReconcileVerdict verdict, String reason})> readback(
      String orderId) async {
    try {
      final response = await client.orderGet(orderId, timeoutSec: 15);
      return reconcileOrder(response, _ownClerkId());
    } on ApiError catch (e) {
      log(LogLevel.warning, '订单状态查询失败 id=$orderId：${e.message}');
      return (verdict: ReconcileVerdict.unknown, reason: '');
    }
  }

  Future<bool> _sleepRetry(Duration deadlineMono) async {
    final delay = config.confirmRetryDelaySec;
    final remaining = deadlineMono - _monotonic();
    final wait = delay < remaining.inMicroseconds / 1e6
        ? delay
        : (remaining.inMicroseconds / 1e6).clamp(0.0, double.infinity);
    return sleep(wait);
  }

  /// The confirm loop itself (§3.8). Returns the task outcome + reason.
  @visibleForTesting
  Future<ConfirmTaskResult> confirmTask(Map<String, dynamic> order,
      String orderId, String phone, String password) async {
    final budget = confirmBudgetSeconds(order, config.randomConfirmWindowSec,
        config.randomConfirmFallbackSec);
    final deadlineMono = _monotonic() +
        Duration(milliseconds: (budget * 1000).round());
    final amount = Order(order).amountYuan;
    final number = order['no']?.toString() ?? orderId;
    log(LogLevel.info, '尝试接单 $number ￥${amount.toStringAsFixed(2)}');
    final wait = confirmWaitForOrder(
      config,
      order,
      shopId: currentShopId(),
      now: _now(),
    );
    if (wait > 0) {
      log(LogLevel.info, '确认前等待 ${wait.toStringAsFixed(2)} 秒');
      if (!await sleep(wait)) {
        return (outcome: ConfirmTaskOutcome.cancelled, reason: '');
      }
    }
    var confirmCalls = 0;
    while (!_stopped) {
      final remaining = deadlineMono - _monotonic();
      if (remaining <= Duration.zero) break;
      final timeout = [
        config.requestTimeoutSec,
        remaining.inMicroseconds / 1e6 < 0.1
            ? 0.1
            : remaining.inMicroseconds / 1e6,
      ].reduce((a, b) => a < b ? a : b);
      Map<String, dynamic> result;
      try {
        confirmCalls += 1;
        result = await client.orderConfirm(orderId, timeoutSec: timeout);
      } on ApiError catch (e) {
        if (e.kind == ApiErrorKind.auth) {
          releaseSeen(orderId);
          log(LogLevel.warning, '确认认证失败，等待账号单飞刷新: $number');
          await refreshSession(phone, password);
          return (outcome: ConfirmTaskOutcome.auth, reason: '确认认证失败');
        }
        if (e.kind == ApiErrorKind.ip) {
          releaseSeen(orderId);
          log(LogLevel.warning, '确认触发IP风控，账号共享暂停60s，不重登录');
          await sleep(60);
          return (outcome: ConfirmTaskOutcome.ip, reason: 'IP风控');
        }
        if (e.kind == ApiErrorKind.cancelled) {
          return (outcome: ConfirmTaskOutcome.cancelled, reason: '');
        }
        final read = await readback(orderId);
        if (read.verdict == ReconcileVerdict.ok) {
          return _grabSuccess(order, orderId, confirmCalls);
        }
        if (read.verdict == ReconcileVerdict.fail) {
          log(LogLevel.warning, '✗ 状态查询确认终态失败: ${read.reason}');
          return (outcome: ConfirmTaskOutcome.fail, reason: read.reason);
        }
        if (read.verdict == ReconcileVerdict.pending) {
          if (!await _sleepRetry(deadlineMono)) {
            return (outcome: ConfirmTaskOutcome.cancelled, reason: '');
          }
          continue;
        }
        log(LogLevel.warning, '⚠ 确认结果未知，停止盲重试: $number');
        return (
          outcome: ConfirmTaskOutcome.unknown,
          reason: read.reason.isNotEmpty ? read.reason : '确认结果未知',
        );
      }
      final classified = classifyConfirm(result);
      if (classified.outcome == ConfirmOutcome.ok) {
        return _grabSuccess(order, orderId, confirmCalls);
      }
      if (classified.outcome == ConfirmOutcome.busy) {
        final cap = busyCapFrom(classified.reason);
        if (cap != null) {
          log(LogLevel.warning,
              '⛔ 已达同时接单上限（$cap 单），本次跳过；完成一单后可继续');
        } else {
          log(LogLevel.warning, '⛔ 同时接单数已满，本次跳过: ${classified.reason}');
        }
        return (outcome: ConfirmTaskOutcome.busy, reason: classified.reason);
      }
      if (classified.outcome == ConfirmOutcome.fail) {
        log(LogLevel.warning, '✗ 确认终态失败 $number: ${classified.reason}');
        return (
          outcome: ConfirmTaskOutcome.fail,
          reason: classified.reason,
        );
      }
      if (confirmCalls == 1 || confirmCalls % 10 == 0) {
        log(LogLevel.info,
            '[confirm] retry $number confirm_calls=$confirmCalls reason=${classified.reason}');
      }
      if (!await _sleepRetry(deadlineMono)) {
        return (outcome: ConfirmTaskOutcome.cancelled, reason: '');
      }
    }
    if (_stopped) {
      return (outcome: ConfirmTaskOutcome.cancelled, reason: '');
    }
    // Deadline reached: one final verification.
    final read = await readback(orderId);
    if (read.verdict == ReconcileVerdict.ok) {
      return _grabSuccess(order, orderId, confirmCalls);
    }
    if (read.verdict == ReconcileVerdict.fail) {
      log(LogLevel.warning,
          '✗ 窗口结束，订单已不可确认: $number confirm_calls=$confirmCalls');
      return (
        outcome: ConfirmTaskOutcome.fail,
        reason: read.reason.isNotEmpty ? read.reason : '订单已不可确认',
      );
    }
    if (read.verdict == ReconcileVerdict.pending) {
      releaseSeen(orderId);
      log(LogLevel.info,
          '↻ 本轮确认预算耗尽，订单仍待确认: $number confirm_calls=$confirmCalls');
      return (
        outcome: ConfirmTaskOutcome.pending,
        reason: '本轮确认预算耗尽，订单仍待确认',
      );
    }
    log(LogLevel.warning,
        '⚠ 窗口结束，确认结果未知: $number confirm_calls=$confirmCalls');
    return (
      outcome: ConfirmTaskOutcome.unknown,
      reason: read.reason.isNotEmpty ? read.reason : '确认结果未知',
    );
  }

  ConfirmTaskResult _grabSuccess(Map<String, dynamic> order, String orderId,
      int confirmCalls) {
    final number = order['no']?.toString() ?? orderId;
    log(LogLevel.success,
        '✓ 确认成功: $number (id=$orderId) confirm_calls=$confirmCalls');
    log(LogLevel.success,
        '抢单成功，请去查看订单，金额 ${Order(order).amountYuan.toStringAsFixed(2)} 元');
    _speak('抢单成功');
    _grabbedKeys.add('${Order(order).no}|${Order(order).id}');
    try {
      onGrab?.call(order, orderId, confirmCalls);
    } catch (_) {
      // History recording must never break the grab flow.
    }
    if (config.autoStopAfterGrab) {
      stop();
    } else if (!_continueNoted) {
      _continueNoted = true;
      log(LogLevel.info, '未开启「接到单后自动停止监听」，抢完继续轮询（只提示这一次）');
    }
    return (outcome: ConfirmTaskOutcome.ok, reason: '');
  }
}
