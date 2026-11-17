import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeMs', () {
    test('seconds become milliseconds, ms stay ms', () {
      expect(normalizeMs(1700000000), 1700000000000);
      expect(normalizeMs(1700000000000), 1700000000000);
      expect(normalizeMs('1700000000'), 1700000000000);
    });
    test('zero, negative and invalid become 0', () {
      expect(normalizeMs(0), 0);
      expect(normalizeMs(-5), 0);
      expect(normalizeMs(null), 0);
      expect(normalizeMs(true), 0);
      expect(normalizeMs('abc'), 0);
      expect(normalizeMs(double.nan), 0);
    });
  });

  group('amountYuanFromCents', () {
    test('cents to yuan', () {
      expect(amountYuanFromCents(3000), 30.0);
      expect(amountYuanFromCents('2500'), 25.0);
      expect(amountYuanFromCents(null), 0.0);
      expect(amountYuanFromCents('bad'), 0.0);
    });
  });

  group('parseCode', () {
    test('numbers and numeric strings parse', () {
      expect(parseCode({'code': 0}), 0);
      expect(parseCode({'code': '401'}), 401);
      expect(parseCode({'code': 1.0}), 1);
      expect(parseCode({'code': ' 403 '}), 403);
    });
    test('bool, missing, non-integral and garbage are null', () {
      expect(parseCode({'code': true}), isNull);
      expect(parseCode({}), isNull);
      expect(parseCode({'code': 1.5}), isNull);
      expect(parseCode({'code': 'abc'}), isNull);
      expect(parseCode({'code': '1.5'}), isNull);
    });
  });

  group('orderIdOf / Order accessors', () {
    test('numeric id becomes a string, missing id is empty', () {
      expect(orderIdOf({'id': 15650502}), '15650502');
      expect(orderIdOf({}), '');
    });
    test('no falls back to id; amount falls back to servicePrice', () {
      final o = Order({'id': 7, 'totalAmount': 0, 'servicePrice': 2500});
      expect(o.no, '7');
      expect(o.amountYuan, 25.0);
      expect(Order({'totalAmount': 3000}).amountYuan, 30.0);
      expect(Order({}).amountYuan, 0.0);
    });
    test('createTime/status/clerkId accessors', () {
      final o = Order({
        'createTime': 1700000000,
        'status': '2',
        'clerkId': '42',
        'userWechatId': 'wx1',
        'userMemo': 'hello',
      });
      expect(o.createTimeMs, 1700000000000);
      expect(o.status, 2);
      expect(o.clerkId, 42);
      expect(o.userWechatId, 'wx1');
      expect(o.userMemo, 'hello');
      expect(Order({}).status, isNull);
      expect(Order({}).clerkId, 0);
    });
  });

  group('extractClerk', () {
    test('tries clerk, then data, then top level', () {
      expect(
          extractClerk({
            'clerk': {'id': 11, 'name': 'A'},
            'data': {'id': 22},
          })?.id,
          11);
      expect(
          extractClerk({
            'data': {'id': 22, 'name': 'B'},
          })?.id,
          22);
      // data itself is the clerk object (PC accepts this).
      expect(extractClerk({'id': 33, 'name': 'C'})?.id, 33);
    });
    test('no positive id gives null', () {
      expect(extractClerk({'data': {'id': 0}}), isNull);
      expect(extractClerk({'data': {}}), isNull);
      expect(extractClerk({}), isNull);
    });
  });

  group('maskPhone', () {
    test('keeps first 3 and last 4', () {
      expect(maskPhone('13800000000'), '138****0000');
    });
    test('short numbers become ***', () {
      expect(maskPhone('1234567'), '***');
      expect(maskPhone(''), '***');
    });
  });

  group('HistoryEntry.fromJson', () {
    test('missing outcome reads as success; unknown outcome as unknown', () {
      final old = HistoryEntry.fromJson({
        'grabbed_at': '2026-11-14T01:58:33',
        'no': '1',
        'id': '2',
        'amount': 30.0,
      });
      expect(old.outcome, HistoryOutcome.success);
      expect(old.reason, '');
      final weird = HistoryEntry.fromJson({
        'grabbed_at': '2026-11-14T01:58:33',
        'no': '1',
        'id': '2',
        'amount': 30.0,
        'outcome': 'weird',
        'reason': 'x',
      });
      expect(weird.outcome, HistoryOutcome.unknown);
      expect(weird.reason, 'x');
    });
  });
}
