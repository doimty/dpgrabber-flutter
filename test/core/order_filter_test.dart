import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  OrderFilter base({
    double minAmount = 10,
    double maxAmount = 0,
    int memoMode = 0,
    List<String> memoKeywords = const [],
    List<String> memoExcludeKeywords = const [],
    List<String> memoIncludeKeywords = const [],
    List<String> blacklist = const [],
    List<int> enabledItems = const [],
    bool switchListKnown = false,
  }) =>
      OrderFilter(
        minAmount: minAmount,
        maxAmount: maxAmount,
        memoMode: memoMode,
        memoKeywords: memoKeywords,
        memoExcludeKeywords: memoExcludeKeywords,
        memoIncludeKeywords: memoIncludeKeywords,
        blacklist: blacklist,
        enabledItems: enabledItems,
        switchListKnown: switchListKnown,
      );

  group('basic chain', () {
    test('a normal order passes', () {
      expect(base().check(fakeOrder()).passed, isTrue);
    });
    test('missing amount field fails (both total and servicePrice absent)',
        () {
      final order = fakeOrder()..remove('totalAmount');
      expect(base().check(order).passed, isFalse);
      expect(base().check(order).reason, '订单缺少金额字段');
    });
    test('missing id fails', () {
      final order = fakeOrder()..remove('id');
      expect(base().check(order).reason, '订单缺少 id 字段');
    });
    test('blacklist is an exact, case-sensitive match', () {
      final f = base(blacklist: ['A_sweet_moon']);
      expect(f.check(fakeOrder()).passed, isFalse);
      expect(f.check(fakeOrder()).reason, contains('客户在黑名单中'));
      expect(f.check(fakeOrder(userWechatId: 'a_sweet_moon')).passed,
          isTrue);
      expect(f.check(fakeOrder(userWechatId: '')).passed, isTrue);
    });
    test('min/max amount', () {
      expect(base(minAmount: 50).check(fakeOrder()).reason,
          '金额 30.00 元低于最低金额');
      expect(base(maxAmount: 20).check(fakeOrder()).reason,
          '金额 30.00 元高于最高金额');
      expect(base(maxAmount: 30).check(fakeOrder()).passed, isTrue);
      expect(base(maxAmount: 0).check(fakeOrder(totalAmount: 999999)).passed,
          isTrue);
    });
  });

  group('servicePrice fallback (Q-05)', () {
    test('totalAmount 0 falls back to servicePrice', () {
      final order = fakeOrder(totalAmount: 0)..['servicePrice'] = 5000;
      expect(base().check(order).passed, isTrue);
      final tooCheap = fakeOrder(totalAmount: 0)
        ..['servicePrice'] = 500;
      expect(base(minAmount: 10).check(tooCheap).passed, isFalse);
    });
    test('missing totalAmount with servicePrice present passes', () {
      final order = fakeOrder()..remove('totalAmount');
      order['servicePrice'] = 3000;
      expect(base().check(order).passed, isTrue);
    });
  });

  group('memo modes', () {
    test('mode 1: any memo blocks', () {
      final f = base(memoMode: 1);
      expect(f.check(fakeOrder(userMemo: 'hi')).passed, isFalse);
      expect(f.check(fakeOrder()).passed, isTrue);
    });
    test('mode 2: exclude keywords, case-insensitive substring', () {
      final f = base(
          memoMode: 2, memoExcludeKeywords: ['加急', '代抢']);
      expect(f.check(fakeOrder(userMemo: '请加急处理')).reason,
          '订单备注命中关键词[加急]');
      expect(f.check(fakeOrder(userMemo: 'ADD urgent 加急')).passed,
          isFalse);
      expect(f.check(fakeOrder(userMemo: '普通单')).passed, isTrue);
      expect(f.check(fakeOrder()).passed, isTrue);
    });
    test('mode 2 via the legacy memo_keywords list', () {
      final f = base(memoMode: 2, memoKeywords: ['加急']);
      expect(f.check(fakeOrder(userMemo: '加急单')).passed, isFalse);
    });
    test('mode 0 + legacy keywords auto-upgrades to mode 2', () {
      final f = base(memoMode: 0, memoKeywords: ['加急']);
      expect(f.memoMode, 2);
      expect(f.check(fakeOrder(userMemo: '加急单')).passed, isFalse);
    });
    test('mode 0 without keywords does not check memos', () {
      final f = base(memoMode: 0);
      expect(f.check(fakeOrder(userMemo: '加急单')).passed, isTrue);
    });
    test('mode 3: memo must contain an include keyword', () {
      final f = base(memoMode: 3, memoIncludeKeywords: ['新客']);
      expect(f.check(fakeOrder(userMemo: '新客首单')).passed, isTrue);
      expect(f.check(fakeOrder(userMemo: '老客')).reason,
          '订单备注不含指定关键词');
      expect(f.check(fakeOrder()).passed, isFalse);
    });
    test('mode 3 with an empty include list does not block', () {
      expect(base(memoMode: 3).check(fakeOrder()).passed, isTrue);
    });
  });

  group('item switch linkage (§6.5)', () {
    test('type id field decides directly', () {
      final f = base(enabledItems: [465]);
      final video = fakeOrder()..['itemId'] = 2666;
      expect(f.check(video).passed, isFalse);
      final voice = fakeOrder()..['itemId'] = 465;
      expect(f.check(voice).passed, isTrue);
    });
    test('name matching: enabled keyword passes, disabled blocks', () {
      final f = base(enabledItems: [465]);
      final voice = fakeOrder()..['itemName'] = '默认-语音连麦-60分钟';
      expect(f.check(voice).passed, isTrue);
      final video = fakeOrder()..['itemName'] = '视频陪玩-30分钟';
      expect(f.check(video).passed, isFalse);
      expect(f.check(video).reason, contains('该接单类型已关闭'));
    });
    test('base types always pass', () {
      final f = base(enabledItems: [465]);
      final baseOrder = fakeOrder()..['itemName'] = '文字语音条';
      expect(f.check(baseOrder).passed, isTrue);
    });
    test('unrecognised type passes (never drop an order)', () {
      final f = base(enabledItems: [465]);
      expect(f.check(fakeOrder()).passed, isTrue);
      expect(orderMatchesItems(fakeOrder(), {465}), isNull);
    });
    test('all-closed with a known list blocks named types only', () {
      final f = base(enabledItems: [], switchListKnown: true);
      final video = fakeOrder()..['itemName'] = '视频陪玩';
      expect(f.check(video).passed, isFalse);
      expect(f.check(video).reason, contains('接单类型已全部关闭'));
      final baseOrder = fakeOrder()..['itemName'] = '文字语音条';
      expect(f.check(baseOrder).passed, isTrue);
      expect(f.check(fakeOrder()).passed, isTrue);
    });
    test('no fetched list means no restriction', () {
      final f = base(enabledItems: [], switchListKnown: false);
      expect(f.check(fakeOrder()..['itemName'] = '视频陪玩').passed,
          isTrue);
    });
    test('item = {names, ids} structure is read', () {
      expect(
          orderItemNames({
            'item': {
              'names': ['视频陪玩'],
              'ids': [59245],
            }
          }),
          ['视频陪玩']);
    });
  });

  group('fromConfig', () {
    test('builds from AppConfig', () {
      final cfg = testConfig(minAmount: 50, memoMode: 1);
      final f = OrderFilter.fromConfig(cfg);
      expect(f.minAmount, 50);
      expect(f.check(fakeOrder()).passed, isFalse); // 30 < 50
    });
  });
}
