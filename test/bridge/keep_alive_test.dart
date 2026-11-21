/// KeepAlive Dart-side tests (mock MethodChannel).
///
/// All test data uses obviously fake values; no real credentials.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dpgrabber/bridge/keep_alive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = KeepAlive.channelName;
  late MethodChannel channel;
  late List<MethodCall> calls;
  late bool failWithMissingPlugin;
  late bool failWithPlatformError;

  setUp(() {
    channel = const MethodChannel(channelName);
    calls = [];
    failWithMissingPlugin = false;
    failWithPlatformError = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (failWithMissingPlugin) throw MissingPluginException();
          if (failWithPlatformError) {
            throw PlatformException(code: 'test', message: 'synthetic failure');
          }
          return switch (call.method) {
            'start' => true,
            'stop' => true,
            'isRunning' => true,
            'getStatus' => {'state': 'running', 'reason': 'foreground'},
            'updateNotification' => null,
            _ => throw MissingPluginException(),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  KeepAlive keepAlive() => KeepAlive(channel: channel, forceSupported: true);

  test('start/stop/isRunning forward to the native channel', () async {
    final ka = keepAlive();
    expect(await ka.start(), isTrue);
    expect(await ka.stop(), isTrue);
    expect(await ka.isRunning, isTrue);
    expect(calls.map((c) => c.method).toList(), ['start', 'stop', 'isRunning']);
  });

  test('updateNotification passes the status text through', () async {
    await keepAlive().updateStatus('监听中');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'updateNotification');
    expect(calls.single.arguments, {'text': '监听中'});
  });

  test('status parses the native state snapshot', () async {
    final status = await keepAlive().status;
    expect(status?.state, 'running');
    expect(status?.reason, 'foreground');
    expect(status?.isRunning, isTrue);
    expect(calls.single.method, 'getStatus');
  });

  test('invalid status payloads are rejected', () {
    expect(KeepAliveStatus.fromPlatform(null), isNull);
    expect(KeepAliveStatus.fromPlatform('running'), isNull);
    expect(KeepAliveStatus.fromPlatform({'state': ''}), isNull);
    expect(
      KeepAliveStatus.fromPlatform({'state': 'interrupted', 'reason': ''})
          ?.reason,
      isNull,
    );
  });

  test('updateNotification with empty text never calls the channel', () async {
    await keepAlive().updateStatus('');
    expect(calls, isEmpty);
  });

  test('missing plugin degrades to false, never throws', () async {
    failWithMissingPlugin = true;
    final ka = keepAlive();
    expect(await ka.start(), isFalse);
    expect(await ka.stop(), isFalse);
    expect(await ka.isRunning, isFalse);
    expect(await ka.status, isNull);
    // updateNotification must not throw either.
    await ka.updateStatus('监听中');
  });

  test('platform errors degrade status to null', () async {
    failWithPlatformError = true;
    expect(await keepAlive().status, isNull);
  });

  test(
    'unsupported platform returns false without calling the channel',
    () async {
      final ka = KeepAlive(channel: channel);
      // Host is Linux in `flutter test`: not Android/iOS, no override.
      expect(ka.isSupported, isFalse);
      expect(await ka.start(), isFalse);
      expect(await ka.stop(), isFalse);
      expect(await ka.isRunning, isFalse);
      expect(calls, isEmpty);
    },
  );
}
