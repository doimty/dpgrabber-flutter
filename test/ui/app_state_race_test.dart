import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dpgrabber/core.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'clearing an account invalidates an in-flight session restore',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'dpgrabber_restore_race_',
      );
      final transport = _DelayedLoginTransport();
      _installLoginFlow(transport);

      await FileCredentialStore(dir)
          .saveAccount(phone: '13800000000', password: 'fake-pw');
      final state = AppState(appDir: dir, transport: transport);
      addTearDown(state.dispose);
      await state.init();

      for (var i = 0; i < 100 && !transport.loginStarted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(transport.loginStarted, isTrue);

      await state.clearAccount();
      transport.loginResponse.complete(
        _jsonResponse({
          'code': 0,
          'data': {'token': 'base-tok', 'shopId': 92},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(state.loggedIn, isFalse);
      expect(state.loginPhone, isNull);
      expect(state.session, isNull);
      expect(state.sessionRestoring, isFalse);
    },
  );

  test('concurrent start requests share one listening attempt', () async {
    final dir = await Directory.systemTemp.createTemp('dpgrabber_start_race_');
    final transport = _DelayedLoginTransport();
    _installLoginFlow(transport);
    transport.onJson('/s/c/order/randomList', {'code': 0, 'list': []});

    await FileCredentialStore(dir)
        .saveAccount(phone: '13800000000', password: 'fake-pw');
    final state = AppState(appDir: dir, transport: transport);
    addTearDown(state.dispose);
    await state.init();

    final firstStart = state.startListening();
    final secondStart = state.startListening();
    for (var i = 0; i < 100 && !transport.loginStarted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(transport.loginStarted, isTrue);
    transport.loginResponse.complete(
      _jsonResponse({
        'code': 0,
        'data': {'token': 'base-tok', 'shopId': 92},
      }),
    );

    expect(await Future.wait([firstStart, secondStart]), [true, true]);
    expect(state.listening, isTrue);
    for (var i = 0; i < 100 && state.lastPollAt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(state.lastPollStartedAt, isNotNull);
    expect(state.lastPollAt, isNotNull);
    expect(state.currentPollStartedAt, isNull);
    expect(state.lastPollDuration, isNotNull);
    expect(state.lastPollSucceeded, isTrue);
    expect(state.completedPollCount, 1);
    expect(state.failedPollCount, 0);
    state.stopListening();
  });
}

void _installLoginFlow(FakeTransport transport) {
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
    'clerk': {'id': 230313, 'name': '加冰', 'status': 1},
  });
  transport.onJson('/s/c/clerk/getItemSwitchList', {
    'code': 0,
    'itemSwitchList': [],
    'clerkItemSwitchIds': [],
  });
}

class _DelayedLoginTransport extends FakeTransport {
  final loginResponse = Completer<HttpResponse>();
  bool loginStarted = false;

  @override
  Future<HttpResponse> request({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) {
    if (url.path == '/s/duopei-account/login') {
      loginStarted = true;
      return loginResponse.future;
    }
    return super.request(
      method: method,
      url: url,
      headers: headers,
      body: body,
      timeout: timeout,
    );
  }
}

HttpResponse _jsonResponse(Map<String, dynamic> response) => HttpResponse(
  statusCode: 200,
  bodyBytes: utf8.encode(
    jsonEncode({'response': response, 'isEncrypted': false}),
  ),
);
