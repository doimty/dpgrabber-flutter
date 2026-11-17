import 'dart:io';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('defaults', () {
    test('PC defaults are kept', () {
      final cfg = AppConfig.defaults();
      expect(cfg.shopId, 0);
      expect(cfg.minAmount, 10.0);
      expect(cfg.maxAmount, 0.0);
      expect(cfg.pollIntervalSec, 0.6);
      expect(cfg.pollJitterSec, 0.2);
      expect(cfg.pollFailureMaxSec, 20.0);
      expect(cfg.busyCooldownSec, 60.0);
      // No default confirm wait: the upstream poller proved confirm
      // works without entering the order page first, so waiting only
      // delays the first confirm. The table stays user-tunable.
      expect(cfg.confirmWaitByShop, isEmpty);
      expect(cfg.runRestEnabled, isTrue);
      expect(cfg.riskRunMin, 50);
      expect(cfg.riskRunMax, 60);
      expect(cfg.riskRestMin, 10);
      expect(cfg.riskRestMax, 20);
      expect(cfg.theme, 'day');
      expect(cfg.notifyProvider, 'serverchan');
      expect(cfg.aesKeyHex, ApiClient.defaultAesKeyHex);
      expect(cfg.aesKeyHexAlt, ApiClient.altAesKeyHex);
      expect(cfg.phone, '');
      expect(cfg.password, '');
    });

    test('toJson omits the password by default', () {
      final cfg = AppConfig.defaults().copyWith(password: 'secret');
      expect(cfg.toJson().containsKey('password'), isFalse);
      expect(cfg.toJson(includeCredentials: true)['password'], 'secret');
    });
  });

  group('validation errors', () {
    test('bad AES keys', () {
      expect(() => AppConfig.fromJson({'aes_key_hex': 'zz'}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson({'aes_key_hex': '00' * 8}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson({'aes_iv_hex': '00' * 8}),
          throwsA(isA<ConfigError>()));
    });
    test('shop_id must be >= 0', () {
      expect(() => AppConfig.fromJson({'shop_id': -1}),
          throwsA(isA<ConfigError>()));
      expect(AppConfig.fromJson({'shop_id': 0}).shopId, 0);
    });
    test('amount rules', () {
      expect(() => AppConfig.fromJson({'min_amount': -1}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson(
              {'min_amount': 20.0, 'max_amount': 10.0}),
          throwsA(isA<ConfigError>()));
      expect(
          AppConfig.fromJson({'min_amount': 20.0, 'max_amount': 20.0})
              .maxAmount,
          20.0);
    });
    test('memo_mode 0..3 only', () {
      expect(() => AppConfig.fromJson({'memo_mode': 4}),
          throwsA(isA<ConfigError>()));
      expect(() => AppConfig.fromJson({'memo_mode': -1}),
          throwsA(isA<ConfigError>()));
    });
    test('window / retry ranges', () {
      expect(
          () => AppConfig.fromJson({'random_confirm_window_sec': 0.05}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson({'confirm_retry_delay_sec': 61}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson({'poll_interval_sec': 0}),
          throwsA(isA<ConfigError>()));
      expect(() => AppConfig.fromJson({'seen_ttl_sec': 0}),
          throwsA(isA<ConfigError>()));
    });
    test('confirm wait rules', () {
      expect(
          () => AppConfig.fromJson(
              {'confirm_wait_min': 5.0, 'confirm_wait_max': 3.0}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson({'confirm_wait_max': 121.0}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson(
              {'confirm_wait_by_shop': {'92': 200.0}}),
          throwsA(isA<ConfigError>()));
      // min == max is allowed (fixed wait).
      expect(
          AppConfig.fromJson(
                  {'confirm_wait_min': 5.0, 'confirm_wait_max': 5.0})
              .confirmWaitMax,
          5.0);
    });
    test('auto_wait_offset range and decimals', () {
      expect(() => AppConfig.fromJson({'auto_wait_offset': 0.6}),
          throwsA(isA<ConfigError>()));
      expect(() => AppConfig.fromJson({'auto_wait_offset': -0.6}),
          throwsA(isA<ConfigError>()));
      expect(() => AppConfig.fromJson({'auto_wait_offset': 0.1234}),
          throwsA(isA<ConfigError>()));
      expect(AppConfig.fromJson({'auto_wait_offset': 0.123}).autoWaitOffset,
          0.123);
    });
    test('run/rest and rotate rules', () {
      expect(() => AppConfig.fromJson({'risk_run_min': 0}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson(
              {'risk_run_min': 60, 'risk_run_max': 50}),
          throwsA(isA<ConfigError>()));
      expect(
          () => AppConfig.fromJson(
              {'risk_rest_min': 20, 'risk_rest_max': 10}),
          throwsA(isA<ConfigError>()));
      expect(() => AppConfig.fromJson({'rotate_minutes': 4}),
          throwsA(isA<ConfigError>()));
      expect(() => AppConfig.fromJson({'rotate_minutes': 601}),
          throwsA(isA<ConfigError>()));
    });
    test('unknown theme falls back to day; bad provider to serverchan',
        () {
      expect(AppConfig.fromJson({'theme': 'nope'}).theme, 'day');
      expect(AppConfig.fromJson({'notify_provider': 'nope'}).notifyProvider,
          'serverchan');
    });
    test('ui_scale auto or 0.8..1.6', () {
      expect(AppConfig.fromJson({'ui_scale': 'auto'}).uiScale, 'auto');
      expect(AppConfig.fromJson({'ui_scale': 1.2}).uiScale, 1.2);
      expect(() => AppConfig.fromJson({'ui_scale': 0.5}),
          throwsA(isA<ConfigError>()));
    });
  });

  group('memo_keywords migration', () {
    test('mode 2 target: old keywords move to exclude list', () {
      final cfg = AppConfig.fromJson({
        'memo_mode': 2,
        'memo_keywords': ['加急', '  ', '代抢'],
      });
      expect(cfg.memoExcludeKeywords, ['加急', '代抢']);
    });
    test('mode 3 target: old keywords move to include list', () {
      final cfg = AppConfig.fromJson({
        'memo_mode': 3,
        'memo_keywords': ['新客'],
      });
      expect(cfg.memoIncludeKeywords, ['新客']);
    });
    test('existing target list is not overwritten', () {
      final cfg = AppConfig.fromJson({
        'memo_mode': 2,
        'memo_keywords': ['old'],
        'memo_exclude_keywords': ['keep'],
      });
      expect(cfg.memoExcludeKeywords, ['keep']);
    });
    test('user_delay is dropped and unknown keys are retained', () {
      final cfg = AppConfig.fromJson({
        'user_delay': 3,
        'some_future_key': 'kept',
      });
      expect(cfg.toJson().containsKey('user_delay'), isFalse);
      expect(cfg.toJson()['some_future_key'], 'kept');
      expect(cfg.extra['some_future_key'], 'kept');
    });
  });

  group('confirmWaitError', () {
    test('valid and invalid tables', () {
      expect(confirmWaitError({}), isNull);
      expect(
          confirmWaitError({
            'confirm_wait_min': 1,
            'confirm_wait_max': 0,
          }),
          isNotNull);
      expect(confirmWaitError({'confirm_wait_by_shop': 'nope'}), isNotNull);
    });
  });

  group('blacklistWouldOverwrite', () {
    test('empty old list never warns', () {
      expect(blacklistWouldOverwrite([], ['a']), isFalse);
      expect(blacklistWouldOverwrite(['a'], ['a']), isFalse);
      expect(blacklistWouldOverwrite(['a'], ['a', 'b']), isTrue);
      expect(blacklistWouldOverwrite(['a'], []), isTrue);
    });
  });

  group('ConfigFileStore', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dpgrabber_cfg_test_');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('creates defaults, roundtrips, and keeps unknown keys', () {
      final file = File('${tmp.path}/dpgrabber_config.json');
      final store = ConfigFileStore(file);
      final created = store.load();
      expect(created.shopId, 0);
      expect(file.existsSync(), isTrue);
      final updated = created.copyWith(
          minAmount: 25.0, extra: {'future_key': 1});
      store.save(updated);
      final reloaded = store.load();
      expect(reloaded.minAmount, 25.0);
      expect(reloaded.extra['future_key'], 1);
    });

    test('corrupt file is backed up and rebuilt from defaults', () {
      final file = File('${tmp.path}/dpgrabber_config.json');
      file.writeAsStringSync('{ not json');
      final store = ConfigFileStore(file);
      final cfg = store.load();
      expect(cfg.minAmount, 10.0);
      final broken = tmp
          .listSync()
          .where((e) => e.path.contains('.broken-'))
          .toList();
      expect(broken, hasLength(1));
      expect(file.readAsStringSync(), contains('"min_amount"'));
    });
  });
}
