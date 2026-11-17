/// LocalNotifications tests (fake backend).
///
/// Copy assertions pin the contract wording exactly (§1.7 / iOS
/// snapshot): title `抢单成功`, body `已抢到一单，金额 X 元，请去查看订单。`
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dpgrabber/bridge/local_notifications.dart';

class FakeBackend implements LocalNotificationBackend {
  final List<({int id, String title, String body})> shown = [];
  bool initialized = false;
  bool permissionRequested = false;
  bool permissionResult = true;
  bool failShow = false;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequested = true;
    return permissionResult;
  }

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (failShow) return false;
    shown.add((id: id, title: title, body: body));
    return true;
  }
}

void main() {
  test('grabBody pins the contract wording with 2 decimals', () {
    expect(
      LocalNotifications.grabBody(30),
      '已抢到一单，金额 30.00 元，请去查看订单。',
    );
    expect(
      LocalNotifications.grabBody(12.5),
      '已抢到一单，金额 12.50 元，请去查看订单。',
    );
  });

  test('showGrabSuccess posts title/body through the backend', () async {
    final backend = FakeBackend();
    final notes = LocalNotifications(backend: backend);
    await notes.initialize();
    expect(backend.initialized, isTrue);
    expect(
      await notes.showGrabSuccess(orderNo: '26111401581302023638', amount: 30),
      isTrue,
    );
    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.title, '抢单成功');
    expect(
      backend.shown.single.body,
      '已抢到一单，金额 30.00 元，请去查看订单。',
    );
  });

  test('showNotification posts a raw title/body pair', () async {
    final backend = FakeBackend();
    final notes = LocalNotifications(backend: backend);
    expect(
      await notes.showNotification(title: '抢单成功', body: '已抢到一单，金额 30.00 元，请去查看订单。'),
      isTrue,
    );
    expect(backend.shown.single.title, '抢单成功');
    expect(
      backend.shown.single.body,
      '已抢到一单，金额 30.00 元，请去查看订单。',
    );
  });

  test('requestPermission delegates to the backend', () async {
    final backend = FakeBackend();
    final notes = LocalNotifications(backend: backend);
    expect(await notes.requestPermission(), isTrue);
    expect(backend.permissionRequested, isTrue);
  });

  test('onGrabHandler maps an engine grab to the notification', () async {
    final backend = FakeBackend();
    final notes = LocalNotifications(backend: backend);
    // Fake order map: totalAmount is cents (3000 = ¥30.00).
    notes.onGrabHandler(
      {
        'id': '15650502',
        'no': '26111401581302023638',
        'totalAmount': 3000,
      },
      '15650502',
      5,
    );
    // Fire-and-forget handler: let the microtask run.
    await Future<void>.delayed(Duration.zero);
    expect(backend.shown, hasLength(1));
    expect(
      backend.shown.single.body,
      '已抢到一单，金额 30.00 元，请去查看订单。',
    );
  });

  test('onGrabHandler falls back to the order id when no is missing',
      () async {
    final backend = FakeBackend();
    final notes = LocalNotifications(backend: backend);
    notes.onGrabHandler({'id': '15650502', 'totalAmount': 1000}, '15650502', 1);
    await Future<void>.delayed(Duration.zero);
    expect(backend.shown, hasLength(1));
    expect(
      backend.shown.single.body,
      '已抢到一单，金额 10.00 元，请去查看订单。',
    );
  });

  test('backend failure returns false, never throws', () async {
    final backend = FakeBackend()..failShow = true;
    final notes = LocalNotifications(backend: backend);
    expect(
      await notes.showGrabSuccess(orderNo: 'x', amount: 1),
      isFalse,
    );
  });

  test('distinct order numbers get distinct notification ids', () {
    expect(
      LocalNotifications.grabIdFor('111'),
      isNot(LocalNotifications.grabIdFor('222')),
    );
  });
}
