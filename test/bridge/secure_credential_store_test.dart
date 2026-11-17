/// SecureCredentialStore tests (in-memory fake backend + temp dir).
///
/// All test data uses obviously fake values (13800000000); no real
/// credentials anywhere.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dpgrabber/bridge/secure_credential_store.dart';
import 'package:dpgrabber/core.dart';

class MemoryBackend implements SecureStorageBackend {
  final Map<String, String> map = {};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async {
    map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    map.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(map);
}

class FailingBackend implements SecureStorageBackend {
  @override
  Future<String?> read(String key) =>
      throw PlatformException(code: 'ERR', message: 'keystore broken');
  @override
  Future<void> write(String key, String value) =>
      throw PlatformException(code: 'ERR', message: 'keystore broken');
  @override
  Future<void> delete(String key) =>
      throw PlatformException(code: 'ERR', message: 'keystore broken');
  @override
  Future<Map<String, String>> readAll() =>
      throw PlatformException(code: 'ERR', message: 'keystore broken');
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dpgrabber_bridge_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('save/load round-trip, secure flag true', () async {
    final store =
        SecureCredentialStore(dir, backend: MemoryBackend());
    expect(store.isSecureStorage, isTrue);

    await store.saveAccount(phone: '13800000000', password: 'fake-pw');
    final loaded = await store.loadAccount();
    expect(loaded, isNotNull);
    expect(loaded!.phone, '13800000000');
    expect(loaded.password, 'fake-pw');
  });

  test('loadAccount returns null when nothing was saved', () async {
    final store =
        SecureCredentialStore(dir, backend: MemoryBackend());
    expect(await store.loadAccount(), isNull);
  });

  test('multi-account: active account wins, ambiguous without one',
      () async {
    final backend = MemoryBackend();
    final store = SecureCredentialStore(dir, backend: backend);
    await store.saveAccount(phone: '13800000000', password: 'pw-one');
    await store.saveAccount(phone: '13900000000', password: 'pw-two');
    // Last save wins as active.
    expect((await store.loadAccount())?.phone, '13900000000');

    // No active pointer + two accounts -> ambiguous -> null.
    store.activePhone = null;
    await backend.delete('dpgrabber_active_phone');
    expect(await store.loadAccount(), isNull);

    // Pointing at one account resolves it.
    store.activePhone = '13800000000';
    expect((await store.loadAccount())?.password, 'pw-one');

    expect(
      await store.listAccountPhones(),
      ['13800000000', '13900000000'],
    );
  });

  test('clearAccount removes only the active account', () async {
    final store =
        SecureCredentialStore(dir, backend: MemoryBackend());
    await store.saveAccount(phone: '13800000000', password: 'pw-one');
    await store.saveAccount(phone: '13900000000', password: 'pw-two');
    store.activePhone = '13800000000';
    await store.clearAccount();
    expect((await store.loadAccount())?.phone, '13900000000');
  });

  test('config round-trips through the PC-compatible JSON file',
      () async {
    final store =
        SecureCredentialStore(dir, backend: MemoryBackend());
    final cfg = AppConfig.defaults();
    await store.saveConfig(cfg);
    final loaded = await store.loadConfig();
    expect(loaded.minAmount, cfg.minAmount);
    expect(loaded.shopId, cfg.shopId);
    expect(loaded.theme, cfg.theme);
    // Password never lands in the config file.
    expect(File('${dir.path}/dpgrabber_config.json').existsSync(), isTrue);
  });

  test('backend failure: throws, flips isSecureStorage, never writes '
      'plaintext', () async {
    final store =
        SecureCredentialStore(dir, backend: FailingBackend());
    expect(store.isSecureStorage, isTrue);
    await expectLater(
      store.saveAccount(phone: '13800000000', password: 'fake-pw'),
      throwsA(isA<SecureStorageUnavailable>()),
    );
    expect(store.isSecureStorage, isFalse);
    expect(store.secureStorageError, contains('keystore broken'));
    expect(SecureCredentialStore.unencryptedWarning, isNotEmpty);
    // No plaintext credential file was created.
    expect(
      File('${dir.path}/credentials_dev.json').existsSync(),
      isFalse,
    );
    Object? loadError;
    try {
      await store.loadAccount();
    } catch (e) {
      loadError = e;
    }
    expect(loadError, isA<SecureStorageUnavailable>());
  });
}
