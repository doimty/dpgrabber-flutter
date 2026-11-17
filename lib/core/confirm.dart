/// Confirm classification, readback reconciliation, window budget
/// and first-confirm wait (PORTING_CONTRACT §3).
///
/// Pure functions: no network, no clock (the caller injects `now`).
/// Ported from `pc/engine.py` (`classify_confirm` / `reconcile_order` /
/// `confirm_budget_seconds` / `confirm_wait_for_order` /
/// `confirm_wait_seconds` / `terminal_reason` / `busy_cap_from`).
library;

import 'dart:math';

import 'config.dart';
import 'models.dart';

/// Words whose presence in a confirm reply means success.
const List<String> confirmedWords = ['已接单', '已确认', '接单成功', '确认成功'];

/// Words that mean the account's standing blocks the grab (PC only).
const List<String> qualificationWords = [
  '续费率',
  '达标',
  '资质',
  '额度',
  '次数不足',
  '上限',
  '本周订单',
];

/// Words that mean the shop's simultaneous-grab quota is full (PC only).
const List<String> busyWords = ['同时接单数超过限制', '接单数超过限制', '超过限制的'];

/// Terminal words: the 7 base words + 跑走/跑掉 + qualification words.
const List<String> terminalWords = [
  '取消',
  '已被',
  '不存在',
  '无权',
  '权限',
  '失效',
  '超时',
  '跑走',
  '跑掉',
  ...qualificationWords,
];

/// Shops the auto-wait offset applies to (50 / 105 / 1391 only; 92 does not).
const Set<int> autoWaitOffsetShops = {50, 105, 1391};

enum ConfirmOutcome { ok, fail, retry, busy }

enum ReconcileVerdict { ok, fail, pending, unknown }

/// Confirm-task terminal outcomes (the `_confirm_task` return set).
enum ConfirmTaskOutcome { ok, fail, pending, unknown, auth, ip, busy, cancelled }

/// Task outcome -> history outcome (PC `_OUTCOME_MAP`, §3.7).
/// `cancelled` maps to nothing: no history entry is written.
HistoryOutcome? historyOutcomeFor(ConfirmTaskOutcome outcome) {
  switch (outcome) {
    case ConfirmTaskOutcome.ok:
      return HistoryOutcome.success;
    case ConfirmTaskOutcome.fail:
      return HistoryOutcome.failed;
    case ConfirmTaskOutcome.unknown:
    case ConfirmTaskOutcome.auth:
      return HistoryOutcome.unknown;
    case ConfirmTaskOutcome.pending:
    case ConfirmTaskOutcome.busy:
      return HistoryOutcome.skipped;
    case ConfirmTaskOutcome.ip:
      return HistoryOutcome.risk;
    case ConfirmTaskOutcome.cancelled:
      return null;
  }
}

/// Fallback human-readable reasons when a task outcome has none (§3.7).
/// Note: PC's `_OUTCOME_DEFAULT_REASON` for `skipped` is
/// '本轮确认未完成，订单仍待确认'; the per-site reasons in §3.7
/// ('本轮确认预算耗尽，订单仍待确认' for pending, the platform message
/// for busy) take precedence because the engine always supplies them.
String defaultReasonFor(HistoryOutcome outcome) {
  switch (outcome) {
    case HistoryOutcome.success:
      return '';
    case HistoryOutcome.failed:
      return '平台拒绝确认';
    case HistoryOutcome.unknown:
      return '确认结果未知';
    case HistoryOutcome.skipped:
      return '本轮确认未完成，订单仍待确认';
    case HistoryOutcome.risk:
      return 'IP风控';
  }
}

/// Human-readable reason for a terminal confirm failure (PC
/// `terminal_reason`). A qualification refusal returns the platform
/// message verbatim.
String terminalReason(String? message) {
  final text = message ?? '';
  if (qualificationWords.any(text.contains)) {
    return text.isEmpty ? '平台拒绝（资质/额度）' : text;
  }
  if (['已被', '被其他', '他人抢', '别人抢', '抢走'].any(text.contains)) {
    return '被其他人抢走';
  }
  if (text.contains('取消')) return '已取消';
  if (text.contains('不存在')) return '订单不存在';
  if (text.contains('无权') || text.contains('权限')) return '无确认权限';
  if (text.contains('失效')) return '订单已失效';
  if (text.contains('超时')) return '确认超时';
  return text.isEmpty ? '平台拒绝确认' : text;
}

/// Parse the simultaneous-grab cap from e.g. '同时接单数超过限制的2单'.
/// The cap varies with account level and must never be hard-coded.
/// Returns null when it cannot be parsed.
int? busyCapFrom(String? message) {
  final text = message ?? '';
  var m = RegExp(r'超过限制的\s*(\d+)\s*单').firstMatch(text);
  m ??= RegExp(r'限制的\s*(\d+)').firstMatch(text);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// Classify one confirm response. Priority (strict): `code == 0` wins
/// over all wording; confirmed words next; busy next; terminal next;
/// otherwise retry.
({ConfirmOutcome outcome, String reason}) classifyConfirm(
    Map<String, dynamic>? result) {
  if (result == null) return (outcome: ConfirmOutcome.retry, reason: '');
  final code = parseCode(result);
  final msg = _confirmMessage(result);
  if (code == 0) return (outcome: ConfirmOutcome.ok, reason: '');
  if (confirmedWords.any(msg.contains)) {
    return (outcome: ConfirmOutcome.ok, reason: '');
  }
  if (busyWords.any(msg.contains)) {
    return (outcome: ConfirmOutcome.busy, reason: msg);
  }
  if (terminalWords.any(msg.contains)) {
    return (outcome: ConfirmOutcome.fail, reason: terminalReason(msg));
  }
  return (outcome: ConfirmOutcome.retry, reason: msg);
}

/// `msg` if non-empty, else `message`, else '' (PC `or` semantics).
String _confirmMessage(Map<String, dynamic> result) {
  final msg = result['msg'];
  if (msg != null && msg.toString().isNotEmpty) return msg.toString();
  final message = result['message'];
  if (message != null) return message.toString();
  return '';
}

/// Verify a confirm result with one `order/get` response (§3.5).
///
/// TODO(OPEN-Q08): a grab lost to someone else ("已被/跑走") maps to
/// `fail` -> history `failed` here (PC code). HANDOFF §4.6's table says
/// `skipped` (D-40); the user still has to decide.
({ReconcileVerdict verdict, String reason}) reconcileOrder(
    Map<String, dynamic>? response, int ownClerkId) {
  Map<String, dynamic> payload = {};
  if (response != null) {
    final candidates = <Map<String, dynamic>?>[];
    final orderRaw = response['order'];
    candidates.add(orderRaw is Map<String, dynamic> ? orderRaw : null);
    final dataRaw = response['data'];
    if (dataRaw is Map<String, dynamic>) {
      final dataOrder = dataRaw['order'];
      candidates.add(dataOrder is Map<String, dynamic> ? dataOrder : null);
      candidates.add(dataRaw);
    }
    candidates.add(response);
    Map<String, dynamic>? picked;
    for (final cand in candidates) {
      if (cand != null &&
          (cand.containsKey('status') || cand.containsKey('msg'))) {
        picked = cand;
        break;
      }
    }
    payload = picked ?? response;
  }
  var message = (payload['msg'] ?? payload['message'] ?? '').toString();
  if (message.isEmpty && response != null) {
    message = (response['msg'] ?? '').toString();
  }
  int status = 0;
  final rawStatus = payload['status'];
  if (rawStatus is num) {
    status = rawStatus.toInt();
  } else if (rawStatus is String) {
    status = int.tryParse(rawStatus.trim()) ?? 0;
  }
  final confirmed =
      confirmedWords.any(message.contains) || status == 2 || status == 3;
  if (confirmed) {
    int clerkId = 0;
    final rawClerk = payload['clerkId'];
    if (rawClerk is num) {
      clerkId = rawClerk.toInt();
    } else if (rawClerk is String) {
      clerkId = int.tryParse(rawClerk.trim()) ?? 0;
    }
    if (ownClerkId > 0 && clerkId > 0 && clerkId != ownClerkId) {
      return (verdict: ReconcileVerdict.fail, reason: '被其他人抢走');
    }
    return (verdict: ReconcileVerdict.ok, reason: '');
  }
  if (terminalWords.any(message.contains) || status == -1) {
    return (
      verdict: ReconcileVerdict.fail,
      reason: terminalReason(message),
    );
  }
  if (status == 0) return (verdict: ReconcileVerdict.pending, reason: '');
  return (verdict: ReconcileVerdict.unknown, reason: message);
}

/// Confirm window budget in seconds (§3.2): the window when the order
/// has a `createTime`, the fallback window when it does not; 20 s when
/// the configured value is invalid. Only whether `createTime` exists
/// matters — `reTime` / `confirmCountDown` are never read (Q-04/Q-07).
double confirmBudgetSeconds(
    Map<String, dynamic>? order, double windowSec, double fallbackSec) {
  final createMs = order == null ? 0 : normalizeMs(order['createTime']);
  var budget = createMs > 0 ? windowSec : fallbackSec;
  if (budget.isNaN || budget.isInfinite) budget = 0;
  if (budget <= 0) budget = 20.0;
  return budget;
}

/// Seconds to wait before the FIRST confirm attempt, measured from
/// `createTime` (§3.3). [shopId] is the current session sid as an int
/// (not the configured `shop_id`); [now] is the wall clock (injected
/// for tests). Returns the configured wait minus time already elapsed
/// since `createTime`, never below 0; blind-waits the full target when
/// the order has no `createTime`.
double confirmWaitForOrder(AppConfig cfg, Map<String, dynamic> order,
    {int? shopId, DateTime? now}) {
  final table = cfg.confirmWaitByShop;
  double? override;
  if (shopId != null) override = table[shopId.toString()];
  double target;
  if (override != null) {
    target = override;
    final offset = cfg.autoWaitOffset;
    if (offset != 0 && autoWaitOffsetShops.contains(shopId)) {
      target += offset;
    }
    target = target < 0 ? 0 : target;
  } else {
    target = confirmWaitSeconds(cfg, shopId: shopId);
  }
  if (target <= 0) return 0.0;
  final createMs = normalizeMs(order['createTime']);
  if (createMs <= 0) return target;
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final elapsed = ((nowMs - createMs) / 1000.0).clamp(0.0, double.infinity);
  final wait = target - elapsed;
  return wait < 0 ? 0.0 : wait;
}

/// Uniform wait in [confirm_wait_min, confirm_wait_max] when max > 0,
/// else 0. The `auto_wait_offset` is added only for shops 50/105/1391;
/// the result is clamped at >= 0. [rng] supplies the uniform draw.
double confirmWaitSeconds(AppConfig cfg, {int? shopId, Random? rng}) {
  final minW = cfg.confirmWaitMin;
  final maxW = cfg.confirmWaitMax;
  if (maxW <= 0) return 0.0;
  final wait = (rng ?? Random()).nextDouble() * (maxW - minW) + minW;
  var result = wait;
  if (shopId != null && autoWaitOffsetShops.contains(shopId)) {
    result += cfg.autoWaitOffset;
  }
  return result < 0 ? 0.0 : result;
}
