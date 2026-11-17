/// Secure credential store (PORTING_CONTRACT §1.7, §2, Q-12).
///
/// Production implementation of [CredentialStore] backed by
/// `flutter_secure_storage`:
/// - Android: EncryptedSharedPreferences (AndroidX Security, AES-256-GCM,
///   key in the Android Keystore) — the plugin's default on Android.
/// - iOS: Keychain, accessibility `first_unlock` (readable after first
///   unlock, so the engine can read credentials while backgrounded) —
///   same as the reference `CredentialStore.swift`.
///
/// Key layout (all values are the raw phone/password strings; the token
/// is NEVER persisted, §4.4):
/// - `dpgrabber_active_phone` — digits-only phone of the active account.
/// - `dpgrabber_phone_<digits>` / `dpgrabber_password_<digits>` — one
///   pair per account, mirroring the multi-account behaviour of
///   [FileCredentialStore] / PC `accounts.py` (Q-12): switching accounts
///   switches the whole config; logging in creates the entry.
///
/// Config (non-credential) is a PC-compatible JSON file handled by
/// [ConfigFileStore] in the app documents directory, exactly like
/// [FileCredentialStore] does — so the secure store is a drop-in
/// replacement for the dev store.
///
/// ENCRYPTION FAILURE — never silently downgrade (§1.7). If the secure
/// backend throws (e.g. a broken Keystore), the operation throws
/// [SecureStorageUnavailable], [isSecureStorage] flips to false and
/// [secureStorageError] records the cause; the UI must show
/// [unencryptedWarning]. No plaintext fallback is ever written.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/config.dart';
import '../core/credential_store.dart';

/// Thrown when the platform secure storage cannot be used at all.
/// The caller must surface this to the user, not retry silently and
/// never fall back to a plaintext file.
class SecureStorageUnavailable implements Exception {
  final String message;
  const SecureStorageUnavailable(this.message);
  @override
  String toString() => 'SecureStorageUnavailable: $message';
}

/// Minimal secure-storage surface, injectable so unit tests can run
/// without the platform plugin.
abstract class SecureStorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// `flutter_secure_storage` backend.
///
/// Android: EncryptedSharedPreferences (plugin default in v11).
/// iOS: Keychain with `first_unlock` accessibility — matches the
/// reference `CredentialStore.swift`
/// (`kSecAttrAccessibleAfterFirstUnlock`).
class FlutterSecureStorageBackend implements SecureStorageBackend {
  final FlutterSecureStorage _storage;

  FlutterSecureStorageBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

class SecureCredentialStore implements CredentialStore {
  static const String _activePhoneKey = 'dpgrabber_active_phone';
  static const String _phonePrefix = 'dpgrabber_phone_';
  static const String _passwordPrefix = 'dpgrabber_password_';

  /// Warning the UI must show while [isSecureStorage] is false.
  static const String unencryptedWarning =
      '系统安全存储不可用，凭据无法加密保存（请检查设备 Keystore/Keychain 设置）';

  final SecureStorageBackend _backend;
  final Directory _directory;

  /// Phone of the account currently active in the UI; null means
  /// "the single stored account, if there is exactly one".
  String? activePhone;

  bool _secureAvailable = true;
  String? _secureStorageError;

  SecureCredentialStore(
    this._directory, {
    SecureStorageBackend? backend,
    this.activePhone,
  }) : _backend = backend ?? FlutterSecureStorageBackend();

  /// True while the secure backend has not reported a failure.
  /// Flips to false (and stays false) after the first backend error.
  @override
  bool get isSecureStorage => _secureAvailable;

  /// Cause of the last secure-storage failure, if any.
  String? get secureStorageError => _secureStorageError;

  File get _configFile =>
      File('${_directory.path}/dpgrabber_config.json');

  static String digitsOf(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');

  Future<T> _guard<T>(Future<T> Function() run, String what) async {
    try {
      return await run();
    } on PlatformException catch (e) {
      _secureAvailable = false;
      _secureStorageError = e.message ?? e.code;
      throw SecureStorageUnavailable(
        '$what 失败：系统安全存储不可用 (${_secureStorageError ?? e.code})',
      );
    } on MissingPluginException catch (e) {
      _secureAvailable = false;
      _secureStorageError = e.message;
      throw SecureStorageUnavailable(
        '$what 失败：系统安全存储不可用 (${e.message})',
      );
    }
  }

  @override
  Future<void> saveAccount({
    required String phone,
    required String password,
  }) async {
    final digits = digitsOf(phone);
    if (digits.isEmpty) {
      throw ArgumentError('phone number is required');
    }
    await _guard(() async {
      await _backend.write('$_phonePrefix$digits', digits);
      await _backend.write('$_passwordPrefix$digits', password);
      await _backend.write(_activePhoneKey, digits);
    }, '保存账号');
    activePhone = digits;
  }

  @override
  Future<({String phone, String password})?> loadAccount() async {
    final all = await _guard(_backend.readAll, '读取账号');
    final phones = all.keys
        .where((k) => k.startsWith(_phonePrefix))
        .map((k) => k.substring(_phonePrefix.length))
        .where((d) => d.isNotEmpty)
        .toList();
    if (phones.isEmpty) return null;
    // Active account: the in-memory pointer wins (mirrors
    // FileCredentialStore), then the stored pointer, then the single
    // stored account. Two accounts and no pointer is ambiguous.
    final storedActive = all[_activePhoneKey];
    final key = activePhone != null && phones.contains(activePhone)
        ? activePhone!
        : storedActive != null && phones.contains(storedActive)
            ? storedActive
            : (phones.length == 1 ? phones.single : null);
    if (key == null) return null;
    final password = all['$_passwordPrefix$key'];
    if (password == null) return null;
    return (phone: key, password: password);
  }

  /// All stored account phones (digits-only), for the account switcher.
  Future<List<String>> listAccountPhones() async {
    final all = await _guard(_backend.readAll, '读取账号');
    return all.keys
        .where((k) => k.startsWith(_phonePrefix))
        .map((k) => k.substring(_phonePrefix.length))
        .where((d) => d.isNotEmpty)
        .toList()
      ..sort();
  }

  @override
  Future<void> clearAccount() async {
    final current = activePhone ??
        (await loadAccount())?.phone;
    await _guard(() async {
      if (current != null) {
        final digits = digitsOf(current);
        await _backend.delete('$_phonePrefix$digits');
        await _backend.delete('$_passwordPrefix$digits');
      } else {
        // No active account: remove every stored account rather than
        // leaving orphaned credentials behind.
        final all = await _backend.readAll();
        for (final key in all.keys) {
          if (key.startsWith(_phonePrefix) ||
              key.startsWith(_passwordPrefix)) {
            await _backend.delete(key);
          }
        }
      }
      await _backend.delete(_activePhoneKey);
    }, '清除账号');
    activePhone = null;
  }

  @override
  Future<AppConfig> loadConfig() async {
    return ConfigFileStore(_configFile).load();
  }

  @override
  Future<void> saveConfig(AppConfig config) async {
    ConfigFileStore(_configFile).save(config);
  }
}
