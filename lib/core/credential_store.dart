/// Credential storage abstraction + multi-account file store
/// (PORTING_CONTRACT §1.7, §2, D-42, Q-12).
///
/// Contract shape: [CredentialStore] is the abstract interface the core
/// depends on; the production implementation is platform secure storage
/// (Android EncryptedSharedPreferences / iOS Keychain via
/// `flutter_secure_storage`) and is owned by the bridge sub-agent.
///
/// [FileCredentialStore] is a DEVELOPMENT-ONLY implementation that keeps
/// credentials in a plain JSON file under the app documents directory.
/// It exists so the core can be exercised end-to-end before the bridge
/// lands; it must be replaced by the secure implementation before any
/// release. It reports [isSecureStorage] == false, and the UI must show
/// the "credentials are not encrypted" warning whenever it is in use
/// (§1.7: never silently downgrade).
///
/// Tokens are never persisted by any implementation (§4.4).
///
/// Multi-account behaviour follows PC `accounts.py`: one account = one
/// config file under `accounts/<digits-only phone>.json`; switching
/// accounts switches the whole config; logging in creates the file.
/// [AccountStore] implements that; the legacy single
/// `dpgrabber_config.json` is migrated once by [AccountStore.migrateLegacy].
library;

import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'models.dart';

abstract class CredentialStore {
  Future<void> saveAccount({required String phone, required String password});
  Future<({String phone, String password})?> loadAccount();
  Future<void> clearAccount();

  /// The platform must surface this warning when the store is not
  /// encrypted (Android snapshot behaviour, §1.7).
  bool get isSecureStorage;

  Future<AppConfig> loadConfig();
  Future<void> saveConfig(AppConfig config);
}

/// Development-only plain-file credential store.
///
/// File: `<directory>/credentials_dev.json` — a JSON map
/// `{digitsPhone: password}`. Plaintext. Never ship this.
class FileCredentialStore implements CredentialStore {
  final Directory directory;

  /// Phone of the account currently active in the UI; null means
  /// "the single stored account, if there is exactly one".
  String? activePhone;

  FileCredentialStore(this.directory, {this.activePhone});

  @override
  bool get isSecureStorage => false;

  /// Warning the UI must show while this store is in use.
  static const String unencryptedWarning =
      '凭据保存在本机用户目录下的文件中（与 PC 版一致），未加密';

  File get _credentialsFile =>
      File('${directory.path}/credentials_dev.json');

  File get _configFile => File(
      '${directory.path}/dpgrabber_config.json');

  Map<String, String> _readAll() {
    if (!_credentialsFile.existsSync()) return {};
    try {
      final decoded =
          jsonDecode(_credentialsFile.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          e.key.toString(): e.value.toString(),
      };
    } catch (_) {
      return {};
    }
  }

  void _writeAll(Map<String, String> all) {
    directory.createSync(recursive: true);
    _credentialsFile.writeAsStringSync(
        '${jsonEncode(all)}\n',
        encoding: utf8);
  }

  static String digitsOf(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');

  @override
  Future<void> saveAccount(
      {required String phone, required String password}) async {
    final all = _readAll();
    all[digitsOf(phone)] = password;
    _writeAll(all);
    activePhone = digitsOf(phone);
  }

  @override
  Future<({String phone, String password})?> loadAccount() async {
    final all = _readAll();
    if (all.isEmpty) return null;
    final key = activePhone != null && all.containsKey(activePhone)
        ? activePhone!
        : (all.length == 1 ? all.keys.single : null);
    if (key == null) return null;
    return (phone: key, password: all[key]!);
  }

  @override
  Future<void> clearAccount() async {
    final all = _readAll();
    if (activePhone != null) {
      all.remove(activePhone);
    } else {
      all.clear();
    }
    _writeAll(all);
    if (activePhone != null && !all.containsKey(activePhone)) {
      activePhone = null;
    }
  }

  @override
  Future<AppConfig> loadConfig() async {
    final store = ConfigFileStore(_configFile);
    final cfg = store.load();
    return cfg;
  }

  @override
  Future<void> saveConfig(AppConfig config) async {
    ConfigFileStore(_configFile).save(config);
  }
}

/// Per-account config files (PC `accounts.py` behaviour).
class AccountStore {
  final Directory directory;
  AccountStore(this.directory);

  Directory get _accountsDir =>
      Directory('${directory.path}/accounts');

  File get legacyFile =>
      File('${directory.path}/dpgrabber_config.json');

  String pathFor(String phone) {
    final digits = FileCredentialStore.digitsOf(phone);
    if (digits.isEmpty) throw ArgumentError('phone number is required');
    return '${_accountsDir.path}/$digits.json';
  }

  /// All known accounts, newest change first. Metadata:
  /// `{phone, path, clerk_name, shop, updated}` (mtime seconds).
  List<Map<String, dynamic>> listAccounts() {
    _accountsDir.createSync(recursive: true);
    final items = <Map<String, dynamic>>[];
    for (final entity in _accountsDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final name = entity.uri.pathSegments.last;
      final phone = name.substring(0, name.length - 5);
      final meta = <String, dynamic>{
        'phone': phone,
        'path': entity.path,
        'clerk_name': '',
        'shop': '',
        'updated': entity.lastModifiedSync().millisecondsSinceEpoch / 1000,
      };
      try {
        final raw = jsonDecode(entity.readAsStringSync(encoding: utf8));
        if (raw is Map) {
          meta['clerk_name'] = (raw['clerk_name'] ?? '').toString();
          meta['shop'] = (raw['shop_id'] ?? '').toString();
        }
      } catch (_) {}
      items.add(meta);
    }
    items.sort((a, b) =>
        (b['updated'] as num).compareTo(a['updated'] as num));
    return items;
  }

  /// Picker label: `店员名 · 138****1234 · 店 92` (name/phone/shop
  /// omitted when missing).
  static String labelFor(Map<String, dynamic> meta) {
    final phone = maskPhone((meta['phone'] ?? '').toString());
    final name = (meta['clerk_name'] ?? '').toString().trim();
    final shop = (meta['shop'] ?? '').toString().trim();
    final parts = <String>[name.isNotEmpty ? name : phone];
    if (name.isNotEmpty) parts.add(phone);
    if (shop.isNotEmpty && shop != '0') parts.add('店 $shop');
    return parts.join(' · ');
  }

  AppConfig loadAccount(String phone) {
    final file = File(pathFor(phone));
    if (!file.existsSync()) {
      final cfg = AppConfig.defaults()
          .copyWith(phone: FileCredentialStore.digitsOf(phone));
      ConfigFileStore(file).save(cfg);
      return cfg;
    }
    final cfg = ConfigFileStore(file).load();
    return cfg.phone.isEmpty
        ? cfg.copyWith(phone: FileCredentialStore.digitsOf(phone))
        : cfg;
  }

  String saveAccount(AppConfig config, {String? phone}) {
    final targetPhone =
        phone ?? config.phone;
    final file = File(pathFor(targetPhone));
    final stamped = config.copyWith(
      phone: FileCredentialStore.digitsOf(targetPhone),
      updatedAt: formatLocalIso(DateTime.now()),
    );
    ConfigFileStore(file).save(stamped);
    return file.path;
  }

  bool deleteAccount(String phone) {
    try {
      final file = File(pathFor(phone));
      if (file.existsSync()) {
        file.deleteSync();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Move the legacy single config into `accounts/<phone>.json` once.
  /// Returns the new path, or null when there is nothing to migrate.
  String? migrateLegacy() {
    if (!legacyFile.existsSync()) return null;
    AppConfig cfg;
    try {
      cfg = ConfigFileStore(legacyFile).load();
    } catch (_) {
      return null;
    }
    final phone = cfg.phone.trim();
    if (phone.isEmpty) return null;
    final target = File(pathFor(phone));
    if (target.existsSync()) return target.path;
    ConfigFileStore(target).save(cfg);
    try {
      legacyFile.renameSync('${legacyFile.path}.migrated');
    } catch (_) {}
    return target.path;
  }
}
