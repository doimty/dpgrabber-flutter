import 'dart:io';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileCredentialStore', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dpgrabber_cred_test_');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('save/load/clear roundtrip', () async {
      final store = FileCredentialStore(tmp);
      expect(await store.loadAccount(), isNull);
      await store.saveAccount(phone: '13800000000', password: 'fake-pw');
      final loaded = await store.loadAccount();
      expect(loaded?.phone, '13800000000');
      expect(loaded?.password, 'fake-pw');
      await store.clearAccount();
      expect(await store.loadAccount(), isNull);
    });

    test('config load/save roundtrips through the same directory', () async {
      final store = FileCredentialStore(tmp);
      final saved = AppConfig.defaults().copyWith(minAmount: 42.0);
      await store.saveConfig(saved);
      final loaded = await store.loadConfig();
      expect(loaded.minAmount, 42.0);
      expect(loaded.password, ''); // never persisted in the config file
    });
  });

  group('AccountStore (PC accounts.py behaviour)', () {
    late Directory tmp;
    late AccountStore accounts;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dpgrabber_acct_test_');
      accounts = AccountStore(tmp);
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('loadAccount creates a default file; save stamps updated_at',
        () {
      final cfg = accounts.loadAccount('13800000000');
      expect(cfg.phone, '13800000000');
      expect(cfg.shopId, 0);
      final path = accounts.saveAccount(cfg);
      expect(path, endsWith('accounts/13800000000.json'));
      final reloaded = accounts.loadAccount('13800000000');
      expect(reloaded.updatedAt, isNotEmpty);
    });

    test('listAccounts newest first; labelFor formats the picker label',
        () {
      final a = accounts.loadAccount('13800000000');
      accounts.saveAccount(a.copyWith(clerkName: 'TestClerk', shopId: 92));
      final b = accounts.loadAccount('13900000000');
      accounts.saveAccount(b);
      final list = accounts.listAccounts();
      expect(list, hasLength(2));
      expect(list.first['phone'], '13900000000'); // saved last
      expect(AccountStore.labelFor(list.last),
          'TestClerk · 138****0000 · 店 92');
      expect(AccountStore.labelFor(list.first), '139****0000');
    });

    test('deleteAccount removes the file', () {
      accounts.loadAccount('13800000000');
      expect(accounts.deleteAccount('13800000000'), isTrue);
      expect(accounts.deleteAccount('13800000000'), isFalse);
      expect(accounts.listAccounts(), isEmpty);
    });

    test('migrateLegacy moves the single config once', () {
      ConfigFileStore(File('${tmp.path}/dpgrabber_config.json'))
          .save(AppConfig.defaults().copyWith(phone: '13800000000'));
      final target = accounts.migrateLegacy();
      expect(target, endsWith('accounts/13800000000.json'));
      expect(File('${tmp.path}/dpgrabber_config.json.migrated')
          .existsSync(), isTrue);
      expect(accounts.migrateLegacy(), isNull); // nothing left to migrate
    });

    test('migrateLegacy does nothing without a phone', () {
      ConfigFileStore(File('${tmp.path}/dpgrabber_config.json'))
          .save(AppConfig.defaults());
      expect(accounts.migrateLegacy(), isNull);
    });

    test('digits-only phone is required for a path', () {
      expect(() => accounts.pathFor(''), throwsArgumentError);
      expect(accounts.pathFor('+86 138-0000-0000'),
          contains('13800000000.json'));
    });
  });
}
