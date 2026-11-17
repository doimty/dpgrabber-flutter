/// AppBridges wiring test: initialize with injected fakes, verify the
/// pieces fit together and the engine onGrab hook posts a notification.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dpgrabber/bridge/app_bridges.dart';
import 'package:dpgrabber/bridge/keep_alive.dart';
import 'package:dpgrabber/bridge/secure_credential_store.dart';
import 'package:dpgrabber/core/credential_store.dart';

import 'local_notifications_test.dart' show FakeBackend;
import 'secure_credential_store_test.dart' show MemoryBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize wires store + keep-alive + notifications', () async {
    final dir = await Directory.systemTemp.createTemp('dpgrabber_app_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    const channel = MethodChannel(KeepAlive.channelName);
    var started = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') started = true;
      return switch (call.method) {
        'start' => true,
        'stop' => true,
        'isRunning' => true,
        _ => null,
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final backend = FakeBackend();
    final bridges = await AppBridges.initialize(
      storageBackend: MemoryBackend(),
      configDirectory: dir,
      keepAliveChannel: channel,
      notificationBackend: backend,
    );

    // Windows intentionally uses the plain-file store (same as the DPPP
    // PC build); other platforms use the secure store.
    if (Platform.isWindows) {
      expect(bridges.credentialStore, isA<FileCredentialStore>());
      expect(bridges.credentialStore.isSecureStorage, isFalse);
    } else {
      expect(bridges.credentialStore, isA<SecureCredentialStore>());
      expect(bridges.credentialStore.isSecureStorage, isTrue);
    }
    expect(backend.initialized, isTrue);

    // Credential round-trip through the wired store.
    await bridges.credentialStore.saveAccount(
      phone: '13800000000',
      password: 'fake-pw',
    );
    expect(
      (await bridges.credentialStore.loadAccount())?.phone,
      '13800000000',
    );

    // Engine onGrab hook -> local notification. The keep-alive channel
    // mock is on the default channel name; force-supported is not set,
    // so start() is a no-op on the Linux host — assert the tray/keep
    // alive calls degrade silently instead.
    await bridges.startBackgroundSupport(
      onTrayShow: () {},
      onTrayQuit: () {},
    );
    expect(started, isFalse); // Linux host: KeepAlive unsupported.

    bridges.onGrab(
      {'id': '15650502', 'no': '26111401581302023638', 'totalAmount': 3000},
      '15650502',
      5,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.title, '抢单成功');

    await bridges.stopBackgroundSupport();
  });
}
