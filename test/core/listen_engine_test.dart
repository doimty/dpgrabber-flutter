import 'dart:convert';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Drives a ListenEngine against a FakeTransport with scripted
/// randomList / confirm / order-get behaviour.
class EngineHarness {
  final FakeTransport transport;
  final List<Map<String, dynamic>> ordersToServe;
  final List<Map<String, dynamic>> confirmReplies;
  final List<Map<String, dynamic>> readbackReplies;
  int confirmCalls = 0;
  int readbackCalls = 0;

  final List<(LogLevel, String)> logs = [];
  final List<String> speaks = [];
  final List<(Map<String, dynamic>, String, int)> grabs = [];
  final List<(Map<String, dynamic>, HistoryOutcome, String)> outcomes = [];
  final List<Session> sessions = [];

  EngineHarness({
    this.ordersToServe = const [],
    this.confirmReplies = const [],
    this.readbackReplies = const [],
  }) : transport = FakeTransport();

  void install({bool loginOk = true}) {
    transport.onJson('/s/duopei-account/login', {
      'code': 0,
      'data': {'token': 'tok-1', 'shopId': 92},
    });
    transport.onJson('/s/duopei-account/list-shop-account', {
      'code': 0,
      'data': [
        {'shopId': 92, 'accountId': 'a92'},
      ],
    });
    transport.onJson('/s/duopei-account/switch-account', {
      'code': 0,
      'data': {'token': 'tok-92'},
    });
    transport.onJson('/s/balance/getBalance', {'code': 0});
    transport.onJson('/s/c/clerk/get', {
      'code': 0,
      'clerk': {'id': 9, 'name': 'TestClerk', 'shopId': 92},
    });
    transport.on('/s/c/order/randomList', (_) {
      return HttpResponse(
        statusCode: 200,
        bodyBytes: utf8.encode(
          jsonEncode({
            'response': {'code': 0, 'list': ordersToServe},
            'isEncrypted': false,
          }),
        ),
      );
    });
    transport.on('/s/c/order/confirm', (_) {
      final reply = confirmCalls < confirmReplies.length
          ? confirmReplies[confirmCalls]
          : {'code': 1, 'msg': '请稍后再试'};
      confirmCalls++;
      return HttpResponse(
        statusCode: 200,
        bodyBytes: utf8.encode(
          jsonEncode({'response': reply, 'isEncrypted': false}),
        ),
      );
    });
    transport.on('/s/c/order/get', (_) {
      final reply = readbackCalls < readbackReplies.length
          ? readbackReplies[readbackCalls]
          : {
              'code': 0,
              'order': {'status': 0},
            };
      readbackCalls++;
      return HttpResponse(
        statusCode: 200,
        bodyBytes: utf8.encode(
          jsonEncode({'response': reply, 'isEncrypted': false}),
        ),
      );
    });
  }

  ListenEngine engine(
    AppConfig config, {
    PollStartedCallback? onPollStarted,
    PollCallback? onPoll,
  }) => ListenEngine(
    client: testClient(transport),
    config: config,
    log: (level, msg) => logs.add((level, msg)),
    speak: speaks.add,
    onGrab: (order, id, calls) => grabs.add((order, id, calls)),
    onOutcome: (order, outcome, reason) =>
        outcomes.add((order, outcome, reason)),
    onSession: sessions.add,
    onPollStarted: onPollStarted,
    onPoll: onPoll,
  );
}

void main() {
  group('delays', () {
    test('pollDelay respects interval ± jitter with a 0.1 floor', () {
      final e = EngineHarness().engine(
        testConfig(pollIntervalSec: 0.6, pollJitterSec: 0.2),
      );
      for (var i = 0; i < 50; i++) {
        final d = e.pollDelay();
        expect(d, greaterThanOrEqualTo(0.4));
        expect(d, lessThanOrEqualTo(0.8));
      }
      final fixed = EngineHarness().engine(
        testConfig(pollIntervalSec: 0.05, pollJitterSec: 0),
      );
      expect(fixed.pollDelay(), 0.1); // floored
    });
    test('failureDelay grows 1 -> 1.7 -> 2.9 and caps at 20', () {
      final e = EngineHarness().engine(testConfig());
      expect(e.failureDelay(1), closeTo(1.0, 0.25));
      expect(e.failureDelay(2), closeTo(1.7, 0.4));
      expect(e.failureDelay(3), closeTo(2.89, 0.6));
      expect(e.failureDelay(100), lessThanOrEqualTo(20.0));
      expect(e.failureDelay(100), greaterThanOrEqualTo(0.2));
    });
    test('seen set: mark/isSeen/release with TTL', () async {
      final e = EngineHarness().engine(testConfig(seenTtlSec: 0.2));
      e.markSeen('1');
      expect(e.isSeen('1'), isTrue);
      expect(e.isSeen(''), isFalse);
      e.releaseSeen('1');
      expect(e.isSeen('1'), isFalse);
      e.markSeen('2');
      await Future.delayed(const Duration(milliseconds: 300));
      expect(e.isSeen('2'), isFalse);
    });
  });

  group('confirmTask', () {
    test(
      'code 0 confirm succeeds: onGrab once, no duplicate outcome',
      () async {
        final h = EngineHarness(
          confirmReplies: [
            {'code': 0},
          ],
        );
        h.install();
        final engine = h.engine(testConfig());
        // Confirm tasks need a live session (in
        // production _run sets it before the poll
        // loop); establish it first.
        expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
        // handleOrder drives the whole task: success is reported via
        // onGrab, and the duplicate success onOutcome is skipped (§1.6).
        final outcome = await engine.handleOrder(
          fakeOrder(),
          '15650502',
          '13800000000',
          'abc',
        );
        expect(outcome, ConfirmTaskOutcome.ok);
        expect(h.grabs, hasLength(1));
        expect(h.grabs.single.$3, 1);
        expect(h.outcomes, isEmpty);
        expect(h.logs.any((l) => l.$2.contains('✓ 确认成功')), isTrue);
      },
    );

    test('terminal message fails fast without burning the window', () async {
      final h = EngineHarness(
        confirmReplies: [
          {'code': 1, 'msg': '订单已被其他人抢走'},
        ],
      );
      h.install();
      final engine = h.engine(testConfig());
      // Confirm tasks need a live session (in
      // production _run sets it before the poll
      // loop); establish it first.
      expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
      final result = await engine.handleOrder(
        fakeOrder(),
        '15650502',
        '13800000000',
        'abc',
      );
      expect(result, ConfirmTaskOutcome.fail);
      expect(h.confirmCalls, 1);
      expect(h.outcomes.single.$2, HistoryOutcome.failed);
      expect(h.outcomes.single.$3, '被其他人抢走');
    });

    test(
      'busy ends the task and maps to skipped with platform wording',
      () async {
        final h = EngineHarness(
          confirmReplies: [
            {'code': 1, 'msg': '同时接单数超过限制的2单'},
          ],
        );
        h.install();
        final engine = h.engine(testConfig());
        // Confirm tasks need a live session (in
        // production _run sets it before the poll
        // loop); establish it first.
        expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
        final result = await engine.handleOrder(
          fakeOrder(),
          '15650502',
          '13800000000',
          'abc',
        );
        expect(result, ConfirmTaskOutcome.busy);
        expect(h.outcomes.single.$2, HistoryOutcome.skipped);
        expect(h.outcomes.single.$3, '同时接单数超过限制的2单');
        expect(h.logs.any((l) => l.$2.contains('已达同时接单上限（2 单）')), isTrue);
      },
    );

    test('retry then success', () async {
      final h = EngineHarness(
        confirmReplies: [
          {'code': 1, 'msg': '请稍后再试'},
          {'code': 1, 'msg': '请稍后再试'},
          {'code': 0},
        ],
      );
      h.install();
      final engine = h.engine(testConfig());
      // Confirm tasks need a live session (in
      // production _run sets it before the poll
      // loop); establish it first.
      expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
      final result = await engine.confirmTask(
        fakeOrder(),
        '15650502',
        '13800000000',
        'abc',
      );
      expect(result.outcome, ConfirmTaskOutcome.ok);
      expect(h.confirmCalls, 3);
    });

    test('network error goes to readback; pending retries; ok wins', () async {
      final h = EngineHarness(
        confirmReplies: [
          {'code': 0}, // only used after the readback retry
        ],
        readbackReplies: [
          {
            'code': 0,
            'order': {'status': 0},
          }, // pending -> retry
        ],
      );
      h.install();
      // Make the first confirm throw a network error by replacing the
      // confirm handler with one that fails once.
      var first = true;
      h.transport.handlers['* /s/c/order/confirm'] = (_) {
        if (first) {
          first = false;
          throw const FakeNetworkError();
        }
        h.confirmCalls++;
        return HttpResponse(
          statusCode: 200,
          bodyBytes: utf8.encode(
            jsonEncode({
              'response': {'code': 0},
              'isEncrypted': false,
            }),
          ),
        );
      };
      final engine = h.engine(testConfig());
      // Confirm tasks need a live session (in
      // production _run sets it before the poll
      // loop); establish it first.
      expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
      final result = await engine.confirmTask(
        fakeOrder(),
        '15650502',
        '13800000000',
        'abc',
      );
      expect(result.outcome, ConfirmTaskOutcome.ok);
      expect(h.readbackCalls, 1);
    });

    test('readback unknown stops blind retry', () async {
      final h = EngineHarness(
        readbackReplies: [
          {
            'code': 0,
            'order': {'status': 1, 'msg': '处理中'},
          },
        ],
      );
      h.install();
      h.transport.handlers['* /s/c/order/confirm'] = (_) {
        throw const FakeNetworkError();
      };
      final engine = h.engine(testConfig());
      // Confirm tasks need a live session (in
      // production _run sets it before the poll
      // loop); establish it first.
      expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
      final result = await engine.handleOrder(
        fakeOrder(),
        '15650502',
        '13800000000',
        'abc',
      );
      expect(result, ConfirmTaskOutcome.unknown);
      expect(h.outcomes.single.$2, HistoryOutcome.unknown);
      // The readback message is passed through (§3.8: reason, or the
      // '确认结果未知' default only when it is empty).
      expect(h.outcomes.single.$3, '处理中');
    });

    test(
      'deadline with pending readback releases seen and is skipped',
      () async {
        final h = EngineHarness(
          confirmReplies: [
            {'code': 1, 'msg': '请稍后再试'},
          ],
          readbackReplies: [
            {
              'code': 0,
              'order': {'status': 0},
            },
          ],
        );
        h.install();
        final engine = h.engine(
          testConfig(
            randomConfirmWindowSec: 0.15,
            randomConfirmFallbackSec: 0.15,
            confirmRetryDelaySec: 0.05,
          ),
        );
        // Confirm tasks need a live session (in
        // production _run sets it before the poll
        // loop); establish it first.
        expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
        final order = fakeOrder(createTime: 1700000000000);
        engine.markSeen('15650502');
        final result = await engine.handleOrder(
          order,
          '15650502',
          '13800000000',
          'abc',
        );
        expect(result, ConfirmTaskOutcome.pending);
        expect(engine.isSeen('15650502'), isFalse); // released
        expect(h.outcomes.single.$2, HistoryOutcome.skipped);
        expect(h.outcomes.single.$3, '本轮确认预算耗尽，订单仍待确认');
      },
    );

    test('auth error during confirm releases seen and re-logs in', () async {
      final h = EngineHarness();
      h.install();
      h.transport.handlers['* /s/c/order/confirm'] = (_) {
        return HttpResponse(statusCode: 401, bodyBytes: utf8.encode('{}'));
      };
      final engine = h.engine(testConfig());
      // Confirm tasks need a live session (in
      // production _run sets it before the poll
      // loop); establish it first.
      expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
      engine.markSeen('15650502');
      final result = await engine.handleOrder(
        fakeOrder(),
        '15650502',
        '13800000000',
        'abc',
      );
      expect(result, ConfirmTaskOutcome.auth);
      expect(engine.isSeen('15650502'), isFalse);
      expect(h.outcomes.single.$2, HistoryOutcome.unknown);
      expect(h.outcomes.single.$3, '确认认证失败');
      expect(h.sessions.length, greaterThanOrEqualTo(1));
    });

    test('stop mid-task yields cancelled with no outcome', () async {
      final h = EngineHarness(
        confirmReplies: [
          {'code': 1, 'msg': '请稍后再试'},
        ],
      );
      h.install();
      final engine = h.engine(
        testConfig(randomConfirmWindowSec: 5, randomConfirmFallbackSec: 5),
      );
      // Confirm tasks need a live session (in
      // production _run sets it before the poll
      // loop); establish it first.
      expect(await engine.refreshSession('13800000000', 'abc'), isTrue);
      final future = engine.handleOrder(
        fakeOrder(),
        '15650502',
        '13800000000',
        'abc',
      );
      await Future.delayed(const Duration(milliseconds: 100));
      engine.stop();
      expect(await future, ConfirmTaskOutcome.cancelled);
      expect(h.outcomes, isEmpty);
      expect(h.grabs, isEmpty);
    });
  });

  group('poll loop', () {
    test('poll callback failures do not stop the listen loop', () async {
      final h = EngineHarness(ordersToServe: []);
      h.install();
      late ListenEngine engine;
      var callbackCount = 0;
      final pollStarts = <DateTime>[];
      final pollCompletions = <(DateTime, DateTime, Duration, bool)>[];
      engine = h.engine(
        testConfig(pollIntervalSec: 0.1, pollJitterSec: 0),
        onPollStarted: pollStarts.add,
        onPoll: (startedAt, completedAt, duration, succeeded) {
          expect(succeeded, isTrue);
          expect(
            startedAt.isBefore(completedAt) || startedAt == completedAt,
            isTrue,
          );
          expect(duration.isNegative, isFalse);
          pollCompletions.add((startedAt, completedAt, duration, succeeded));
          callbackCount++;
          if (callbackCount == 1) throw StateError('diagnostic failed');
          if (callbackCount == 2) engine.stop();
        },
      );

      expect(await engine.start('13800000000', 'abc'), isTrue);
      await Future.delayed(const Duration(milliseconds: 500));

      expect(callbackCount, 2);
      expect(pollStarts, hasLength(2));
      expect(pollCompletions, hasLength(2));
      expect(engine.isRunning, isFalse);
    });

    test('poll callback records a failed request before backoff', () async {
      final h = EngineHarness();
      h.install();
      h.transport.on(
        '/s/c/order/randomList',
        (_) => HttpResponse(statusCode: 500, bodyBytes: utf8.encode('{}')),
      );
      late ListenEngine engine;
      final pollStarts = <DateTime>[];
      final pollCompletions = <(DateTime, DateTime, Duration, bool)>[];
      engine = h.engine(
        testConfig(),
        onPollStarted: pollStarts.add,
        onPoll: (startedAt, completedAt, duration, succeeded) {
          pollCompletions.add((startedAt, completedAt, duration, succeeded));
          engine.stop();
        },
      );

      expect(await engine.start('13800000000', 'abc'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(pollStarts, hasLength(1));
      expect(pollCompletions, hasLength(1));
      final (startedAt, completedAt, duration, succeeded) =
          pollCompletions.single;
      expect(succeeded, isFalse);
      expect(startedAt, pollStarts.single);
      expect(
        startedAt.isBefore(completedAt) || startedAt == completedAt,
        isTrue,
      );
      expect(duration.isNegative, isFalse);
      expect(engine.isRunning, isFalse);
    });

    test('full loop: detects, confirms, grabs, auto-stops', () async {
      final h = EngineHarness(
        ordersToServe: [fakeOrder()],
        confirmReplies: [
          {'code': 0},
        ],
      );
      h.install();
      final engine = h.engine(testConfig());
      expect(await engine.start('13800000000', 'abc'), isTrue);
      await Future.delayed(const Duration(milliseconds: 800));
      expect(h.grabs, hasLength(1));
      expect(engine.isRunning, isFalse); // auto_stop_after_grab
      expect(h.sessions.single.sid, '92');
      expect(engine.clerk?.id, 9);
      expect(h.logs.any((l) => l.$2.contains('开始监听新订单')), isTrue);
      expect(h.logs.any((l) => l.$2.contains('检测到新订单')), isTrue);
    });

    test('session reuse skips login', () async {
      final h = EngineHarness(ordersToServe: []);
      h.install();
      final engine = h.engine(testConfig());
      expect(
        await engine.start(
          '13800000000',
          'abc',
          initialSession: const Session(token: 'reused', sid: '50'),
        ),
        isTrue,
      );
      await Future.delayed(const Duration(milliseconds: 300));
      engine.stop();
      await Future.delayed(const Duration(milliseconds: 200));
      expect(h.logs.any((l) => l.$2.contains('复用已登录会话，店铺 sid=50')), isTrue);
      expect(
        h.transport.requests.any((r) => r.url.path.contains('login')),
        isFalse,
      );
    });

    test(
      'filtered order is skipped and re-polled without confirming',
      () async {
        final h = EngineHarness(ordersToServe: [fakeOrder()]);
        h.install();
        final engine = h.engine(testConfig(minAmount: 100));
        expect(await engine.start('13800000000', 'abc'), isTrue);
        await Future.delayed(const Duration(milliseconds: 400));
        engine.stop();
        await Future.delayed(const Duration(milliseconds: 200));
        expect(h.grabs, isEmpty);
        expect(h.confirmCalls, 0);
        expect(h.logs.any((l) => l.$2.contains('订单不符合要求')), isTrue);
      },
    );

    test(
      'config change mid-run takes effect (filter rebuilt per round)',
      () async {
        final h = EngineHarness(ordersToServe: [fakeOrder()]);
        h.install();
        // Short window: the first confirm task ends as pending (readback
        // default) and releases the order, so a second round happens.
        final engine = h.engine(
          testConfig(
            randomConfirmWindowSec: 0.3,
            randomConfirmFallbackSec: 0.3,
          ),
        );
        expect(await engine.start('13800000000', 'abc'), isTrue);
        await Future.delayed(const Duration(milliseconds: 150));
        // Blacklist the customer while listening; the next round must
        // filter the order out instead of confirming it again.
        engine.updateConfig(testConfig(blacklist: ['A_sweet_moon']));
        await Future.delayed(const Duration(milliseconds: 700));
        engine.stop();
        expect(h.grabs, isEmpty);
        expect(h.logs.any((l) => l.$2.contains('客户在黑名单中')), isTrue);
      },
    );

    test('invalid confirm-wait config refuses to start', () async {
      final h = EngineHarness();
      h.install();
      final bad = testConfig().copyWith(
        confirmWaitMin: 5.0,
        confirmWaitMax: 3.0,
      );
      // copyWith bypasses validation, so build the bad config via JSON.
      final badJson = AppConfig.defaults().toJson()
        ..['confirm_wait_min'] = 5.0
        ..['confirm_wait_max'] = 3.0;
      expect(() => AppConfig.fromJson(badJson), throwsA(isA<ConfigError>()));
      // Engine-level guard: start() must refuse when the wait is bad.
      final engine = h.engine(bad);
      expect(await engine.start('13800000000', 'abc'), isFalse);
      expect(h.logs.any((l) => l.$2.contains('确认等待配置无效')), isTrue);
    });

    test('second start while running returns false', () async {
      final h = EngineHarness(ordersToServe: []);
      h.install();
      final engine = h.engine(testConfig());
      expect(await engine.start('13800000000', 'abc'), isTrue);
      expect(await engine.start('13800000000', 'abc'), isFalse);
      engine.stop();
      await Future.delayed(const Duration(milliseconds: 200));
    });
  });
}

class FakeNetworkError implements Exception {
  const FakeNetworkError();
}
