import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('ClerkStatistics rates', () {
    ClerkStatistics stats({
      int orderCount = 8,
      int continuedCount = 2,
      int continuedUserCount = 3,
      int totalOrderCount = 10,
      double continuedAmount = 600000, // cents
      double orderAmount = 2450000, // cents
    }) =>
        ClerkStatistics(
          orderCount: orderCount,
          continuedCount: continuedCount,
          continuedUserCount: continuedUserCount,
          totalOrderCount: totalOrderCount,
          continuedAmount: continuedAmount,
          orderAmount: orderAmount,
          firstCount: 1,
          refundedCount: 0,
          raw: const {},
        );

    test('the three rates use the PC formulas', () {
      final s = stats();
      expect(s.renewalRate, closeTo(24.4898, 0.001)); // 600000/2450000
      expect(s.orderRate, 25.0); // 2/8
      // Q-10: denominator is totalOrderCount (PC code), not orderCount.
      expect(s.userRate, 30.0); // 3/10
    });

    test('zero denominators give null, not a crash', () {
      final s = stats(
          orderCount: 0, totalOrderCount: 0, orderAmount: 0);
      expect(s.renewalRate, isNull);
      expect(s.orderRate, isNull);
      expect(s.userRate, isNull);
    });

    test('detail lines carry the §10.8 wording and yuan amounts', () {
      final lines = stats().detailLines();
      expect(lines.first, contains('续费率（金额比）24.5%'));
      expect(lines.first, contains('6000.00'));
      expect(lines.first, contains('24500.00'));
      expect(lines[1], '续单率（单数比）25.0% = 2/8 单');
      expect(lines[2], '续客率（人数比）30.0% = 3/10 人');
    });

    test('fromMap keeps unknown server fields in raw', () {
      final s = ClerkStatistics.fromMap({
        'orderCount': 8,
        'continuedCount': 2,
        'continuedUserCount': 3,
        'totalOrderCount': 10,
        'continuedAmount': 600000,
        'orderAmount': 2450000,
        'firstCount': 1,
        'refundedCount': 0,
        'someFutureField': 'kept',
      });
      expect(s.raw['someFutureField'], 'kept');
      expect(s.firstCount, 1);
    });
  });

  group('fetchWeekStatistics', () {
    test('statistics path wins when non-empty', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/statistics/statisticsClerkOrder', {
        'code': 0,
        'list': {
          'orderCount': 8,
          'continuedCount': 2,
          'continuedUserCount': 3,
          'totalOrderCount': 10,
          'continuedAmount': 600000,
          'orderAmount': 2450000,
          'firstCount': 1,
          'refundedCount': 0,
        },
      });
      final result = await fetchWeekStatistics(testClient(transport),
          now: DateTime(2026, 11, 14)); // Saturday; Monday is 11-09
      expect(result.stats?.orderCount, 8);
      expect(result.fallbackOrderTotal, isNull);
      final req = transport.requests.single;
      expect(req.url.queryParameters['startTime'], '2026-11-09');
      expect(req.url.queryParameters['endTime'], '2026-11-14');
    });

    test('empty statistics fall back to orderTotal', () async {
      final transport = FakeTransport();
      transport.onJson('/s/c/statistics/statisticsClerkOrder',
          {'code': 0, 'list': {}});
      transport.onJson('/s/c/order/list', {'code': 0, 'total': 5});
      final result = await fetchWeekStatistics(testClient(transport),
          now: DateTime(2026, 11, 14));
      expect(result.stats, isNull);
      expect(result.fallbackOrderTotal, 5);
      final totalReq = transport.requests
          .firstWhere((r) => r.url.path.contains('/s/c/order/list'));
      expect(totalReq.url.queryParameters['startTime'],
          '2026-11-09 00:00:00');
      expect(totalReq.url.queryParameters['endTime'],
          '2026-11-14 23:59:59');
    });
  });

  group('weekMonday', () {
    test('Monday stays Monday, Sunday goes back 6 days', () {
      expect(weekMonday(DateTime(2026, 11, 9)), DateTime(2026, 11, 9));
      expect(weekMonday(DateTime(2026, 11, 15)), DateTime(2026, 11, 9));
      expect(weekMonday(DateTime(2026, 11, 14)), DateTime(2026, 11, 9));
    });
  });
}
