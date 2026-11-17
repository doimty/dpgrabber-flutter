import 'dart:math';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('classifyConfirm', () {
    test('code 0 wins over any message', () {
      expect(classifyConfirm({'code': 0, 'msg': '已被抢走'}).outcome,
          ConfirmOutcome.ok);
      expect(classifyConfirm({'code': '0'}).outcome, ConfirmOutcome.ok);
    });
    test('confirmed words win when code is not 0', () {
      expect(
          classifyConfirm({'code': 1, 'msg': '接单成功'}).outcome,
          ConfirmOutcome.ok);
      expect(
          classifyConfirm({'code': 2, 'msg': '已确认'}).outcome,
          ConfirmOutcome.ok);
    });
    test('busy words classify as busy with the platform message', () {
      final r = classifyConfirm({'code': 1, 'msg': '同时接单数超过限制的2单'});
      expect(r.outcome, ConfirmOutcome.busy);
      expect(r.reason, '同时接单数超过限制的2单');
    });
    test('terminal words classify as fail with a mapped reason', () {
      expect(classifyConfirm({'code': 1, 'msg': '订单已被其他人抢走'}).outcome,
          ConfirmOutcome.fail);
      expect(
          classifyConfirm({'code': 1, 'msg': '订单已被其他人抢走'}).reason,
          '被其他人抢走');
      expect(
          classifyConfirm({'code': 1, 'msg': '哎呀订单好像跑走了，再试试~'})
              .outcome,
          ConfirmOutcome.fail);
      expect(
          classifyConfirm({'code': 1, 'msg': '订单已取消'}).reason, '已取消');
    });
    test('qualification words end the task immediately, verbatim reason',
        () {
      const msg = '本周订单8单，当前续费率22%，需要达标续费率30%';
      final r = classifyConfirm({'code': 1, 'msg': msg});
      expect(r.outcome, ConfirmOutcome.fail);
      expect(r.reason, msg);
    });
    test('anything else retries; non-dict retries', () {
      expect(classifyConfirm({'code': 1, 'msg': '请稍后再试'}).outcome,
          ConfirmOutcome.retry);
      expect(classifyConfirm({'code': 5, 'msg': ''}).outcome,
          ConfirmOutcome.retry);
      expect(classifyConfirm(null).outcome, ConfirmOutcome.retry);
    });
  });

  group('terminalReason', () {
    test('each branch', () {
      expect(terminalReason('订单不存在'), '订单不存在');
      expect(terminalReason('无确认权限'), '无确认权限');
      expect(terminalReason('订单已失效'), '订单已失效');
      expect(terminalReason('确认超时'), '确认超时');
      expect(terminalReason(''), '平台拒绝确认');
      expect(terminalReason('需要达标续费率30%'), '需要达标续费率30%');
      expect(terminalReason(null), '平台拒绝确认');
    });
  });

  group('busyCapFrom', () {
    test('parses the cap, never hard-codes it', () {
      expect(busyCapFrom('同时接单数超过限制的2单'), 2);
      expect(busyCapFrom('同时接单数超过限制的5单'), 5);
      expect(busyCapFrom('超过限制的 3 单'), 3);
      expect(busyCapFrom('没有数字'), isNull);
      expect(busyCapFrom(null), isNull);
    });
  });

  group('reconcileOrder', () {
    test('status 2/3 confirms; clerk mismatch fails', () {
      expect(reconcileOrder({'order': {'status': 2, 'clerkId': 9}}, 9)
          .verdict, ReconcileVerdict.ok);
      expect(reconcileOrder({'order': {'status': 3, 'clerkId': 9}}, 9)
          .verdict, ReconcileVerdict.ok);
      final mismatch =
          reconcileOrder({'order': {'status': 2, 'clerkId': 8}}, 9);
      expect(mismatch.verdict, ReconcileVerdict.fail);
      expect(mismatch.reason, '被其他人抢走');
      // No own clerk id -> no clerk check.
      expect(reconcileOrder({'order': {'status': 2, 'clerkId': 8}}, 0)
          .verdict, ReconcileVerdict.ok);
    });
    test('payload selection prefers order, then data.order, then data', () {
      expect(
          reconcileOrder({
            'data': {
              'order': {'status': 0},
            }
          }, 0)
              .verdict,
          ReconcileVerdict.pending);
      expect(reconcileOrder({'data': {'status': -1}}, 0).verdict,
          ReconcileVerdict.fail);
      expect(reconcileOrder({'status': 0}, 0).verdict,
          ReconcileVerdict.pending);
    });
    test('terminal message or status -1 fails; unknown otherwise', () {
      expect(
          reconcileOrder({'order': {'status': 1, 'msg': '订单已被抢走'}}, 0)
              .verdict,
          ReconcileVerdict.fail);
      expect(reconcileOrder({'order': {'status': -1}}, 0).verdict,
          ReconcileVerdict.fail);
      expect(reconcileOrder({'order': {'status': 1, 'msg': '处理中'}}, 0)
          .verdict, ReconcileVerdict.unknown);
      // A null response has no status at all, so PC reads status 0 and
      // returns pending (not unknown).
      expect(reconcileOrder(null, 0).verdict, ReconcileVerdict.pending);
    });
  });

  group('confirmBudgetSeconds', () {
    test('createTime present -> window, absent -> fallback', () {
      expect(
          confirmBudgetSeconds({'createTime': 1700000000000}, 20, 5), 20);
      expect(confirmBudgetSeconds({}, 20, 5), 5);
      expect(confirmBudgetSeconds(null, 20, 5), 5);
    });
    test('invalid budget falls back to 20', () {
      expect(confirmBudgetSeconds({'createTime': 1}, 0, 5), 20.0);
      expect(confirmBudgetSeconds({'createTime': 1}, -3, 5), 20.0);
    });
  });

  group('confirmWaitForOrder / confirmWaitSeconds', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000005000);

    test('shop table: 92 waits 5s, 50/105/1391 wait 3s', () {
      final cfg = testConfig(confirmWaitByShop: {
        '92': 5.0,
        '50': 3.0,
        '105': 3.0,
        '1391': 3.0,
      });
      final order = {'createTime': 1700000000000}; // 5s ago
      expect(confirmWaitForOrder(cfg, order, shopId: 92, now: now), 0.0);
      // 50 shop: target 3s, 5s elapsed -> 0.
      expect(confirmWaitForOrder(cfg, order, shopId: 50, now: now), 0.0);
      final fresh = {'createTime': 1700000004000}; // 1s ago
      expect(confirmWaitForOrder(cfg, fresh, shopId: 92, now: now), 4.0);
      expect(confirmWaitForOrder(cfg, fresh, shopId: 50, now: now), 2.0);
    });
    test('offset applies to 50/105/1391 only, never to 92', () {
      final cfg = testConfig(confirmWaitByShop: {
        '92': 5.0,
        '50': 3.0,
      }).copyWith(autoWaitOffset: 0.5);
      final fresh = {'createTime': 1700000004000};
      expect(confirmWaitForOrder(cfg, fresh, shopId: 92, now: now), 4.0);
      expect(confirmWaitForOrder(cfg, fresh, shopId: 50, now: now), 2.5);
    });
    test('no createTime blind-waits the full target', () {
      final cfg = testConfig(confirmWaitByShop: {'92': 5.0});
      expect(confirmWaitForOrder(cfg, {}, shopId: 92, now: now), 5.0);
    });
    test('unknown shop falls back to min/max random wait', () {
      final cfg = testConfig(confirmWaitByShop: {'92': 5.0}).copyWith(
        confirmWaitMin: 2.0,
        confirmWaitMax: 2.0,
      );
      final fresh = {'createTime': 1700000004000};
      expect(confirmWaitForOrder(cfg, fresh, shopId: 777, now: now), 1.0);
    });
    test('confirmWaitSeconds: max 0 -> 0; range respected; offset shops',
        () {
      final cfg = AppConfig.defaults();
      expect(confirmWaitSeconds(cfg), 0.0);
      final fixed = cfg.copyWith(
          confirmWaitMin: 3.0, confirmWaitMax: 3.0, autoWaitOffset: 0.5);
      expect(confirmWaitSeconds(fixed, shopId: 50, rng: Random(1)), 3.5);
      expect(confirmWaitSeconds(fixed, shopId: 92, rng: Random(1)), 3.0);
      expect(confirmWaitSeconds(fixed, rng: Random(1)), 3.0);
    });
  });

  group('history outcome mapping (§3.7)', () {
    test('every task outcome maps as specified', () {
      expect(historyOutcomeFor(ConfirmTaskOutcome.ok),
          HistoryOutcome.success);
      expect(historyOutcomeFor(ConfirmTaskOutcome.fail),
          HistoryOutcome.failed);
      expect(historyOutcomeFor(ConfirmTaskOutcome.unknown),
          HistoryOutcome.unknown);
      expect(historyOutcomeFor(ConfirmTaskOutcome.auth),
          HistoryOutcome.unknown);
      expect(historyOutcomeFor(ConfirmTaskOutcome.pending),
          HistoryOutcome.skipped);
      expect(historyOutcomeFor(ConfirmTaskOutcome.busy),
          HistoryOutcome.skipped);
      expect(historyOutcomeFor(ConfirmTaskOutcome.ip), HistoryOutcome.risk);
      expect(historyOutcomeFor(ConfirmTaskOutcome.cancelled), isNull);
    });
  });
}
