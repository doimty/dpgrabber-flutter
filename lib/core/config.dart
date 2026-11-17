/// Configuration model, defaults, validation and file persistence
/// (PORTING_CONTRACT §2).
///
/// JSON key names follow PC `config.py` snake_case; Dart fields are
/// camelCase. PC is the only complete implementation, so PC defaults
/// and PC validation rules win (D-01/D-02/D-09/D-26...).
///
/// Credentials: `phone`/`password` are accepted when *reading* a
/// PC-compatible JSON file, but [AppConfig.toJson] omits `password` by
/// default — the Flutter config file must not hold the password
/// (§1.7 / D-48); credentials live in the [CredentialStore].
library;

import 'dart:convert';
import 'dart:io';

/// Thrown when a config value is invalid.
class ConfigError implements Exception {
  final String message;
  const ConfigError(this.message);
  @override
  String toString() => 'ConfigError: $message';
}

/// AES protocol constants (PROTOCOL.md §4, contract §5). These are the
/// only key material that may be copied verbatim.
class AesDefaults {
  static const String keyHex =
      'faf6bcb4eeaa8aa62154ed3b8c14cf5bce08cdf83086b9188abdca6f2c8bcbb1';
  static const String ivHex = 'd45df726d59d21fac023cdad3dfcea86';
  static const String keyHexAlt = '81b120ef00216c33b266763abb02e6d1';
  static const String ivHexAlt = 'e6a4cc0507dfe344b042289eeb945dce';
}

/// All known theme ids (§9); unknown ids fall back to 'day'.
const List<String> themeIds = [
  'day',
  'night',
  'blue',
  'sakura',
  'mint',
  'violet',
];

const List<String> notifyProviders = ['bark', 'serverchan', 'pushplus', 'webhook'];

/// The PC default config, transcribed from `pc/config.py`.
Map<String, dynamic> defaultConfigJson() => {
      'phone': '',
      'password': '',
      'shop_id': 0,
      'min_amount': 10.0,
      'max_amount': 0.0,
      'random_confirm_window_sec': 20,
      'random_confirm_fallback_sec': 20,
      'confirm_retry_delay_sec': 0.5,
      'poll_interval_sec': 0.6,
      'poll_jitter_sec': 0.2,
      'poll_failure_max_sec': 20.0,
      'memo_mode': 0,
      'memo_keywords': <String>[],
      'memo_exclude_keywords': <String>[],
      'memo_include_keywords': <String>[],
      'blacklist': <String>[],
      // No per-shop confirm wait by default: the upstream poller proved
      // that confirm works without entering the order page first, so
      // waiting only delays the first confirm and loses orders. The
      // table stays available for user-tuned shops.
      'confirm_wait_by_shop': <String, double>{},
      'rotate_enabled': false,
      'rotate_minutes': 30,
      'confirm_wait_min': 0.0,
      'confirm_wait_max': 0.0,
      'auto_wait_offset': 0.0,
      'run_rest_enabled': true,
      'risk_run_min': 50,
      'risk_run_max': 60,
      'risk_rest_min': 10,
      'risk_rest_max': 20,
      'aes_key_hex': AesDefaults.keyHex,
      'aes_iv_hex': AesDefaults.ivHex,
      'aes_key_hex_alt': AesDefaults.keyHexAlt,
      'aes_iv_hex_alt': AesDefaults.ivHexAlt,
      'request_timeout_sec': 15,
      'verify_tls': true,
      'voice_enabled': true,
      'auto_stop_after_grab': true,
      'notify_enabled': false,
      'notify_provider': 'serverchan',
      'notify_bark_server': 'https://api.day.app',
      'notify_key': '',
      'notify_webhook': '',
      'seen_ttl_sec': 60,
      'theme': 'day',
      'ui_scale': 'auto',
      'item_switch_ids': <int>[],
      'item_switch_known': false,
      'item_switch_names': <String, String>{},
      'item_name_map': {
        '465': ['连麦'],
        '2666': ['视频'],
        '2667': ['游戏'],
      },
      'item_always_types': ['文字语音条', '文语体验单'],
      'clerk_name': '',
      'updated_at': '',
      'busy_cooldown_sec': 60.0,
    };

/// Validates the confirm-wait part of a config map; returns an error
/// message or null (PC `config.confirm_wait_error`).
String? confirmWaitError(Map<String, dynamic> cfg) {
  double minW, maxW;
  try {
    minW = _asDouble(cfg['confirm_wait_min'] ?? 0);
    maxW = _asDouble(cfg['confirm_wait_max'] ?? 0);
  } catch (_) {
    return 'confirm_wait_min/max must be numbers';
  }
  if (minW < 0) return 'confirm_wait_min must be >= 0';
  if (maxW < 0) return 'confirm_wait_max must be >= 0';
  if (maxW < minW) return 'confirm_wait_max must be >= confirm_wait_min';
  if (minW > 120 || maxW > 120) {
    return 'confirm_wait_min/max must be <= 120 seconds';
  }
  final table = cfg['confirm_wait_by_shop'];
  if (table != null && table is! Map) {
    return 'confirm_wait_by_shop must be a mapping of shop id -> seconds';
  }
  if (table is Map) {
    for (final entry in table.entries) {
      double seconds;
      try {
        seconds = _asDouble(entry.value);
      } catch (_) {
        return 'confirm_wait_by_shop[${entry.key}] must be a number';
      }
      if (seconds < 0 || seconds > 120) {
        return 'confirm_wait_by_shop[${entry.key}] must be between 0 and 120';
      }
    }
  }
  return null;
}

/// True when saving [newList] would remove/change entries of a non-empty
/// [oldList] (PC `config.blacklist_would_overwrite`).
bool blacklistWouldOverwrite(List<String>? oldList, List<String>? newList) {
  final old = {
    for (final x in (oldList ?? [])) x.trim(),
  }..remove('');
  if (old.isEmpty) return false;
  final next = {
    for (final x in (newList ?? [])) x.trim(),
  }..remove('');
  return next.length != old.length || !next.containsAll(old);
}

double _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final parsed = double.tryParse(v.trim());
    if (parsed != null) return parsed;
  }
  throw const ConfigError('value must be a number');
}

int _asInt(dynamic v, String name) {
  if (v is bool) throw ConfigError('$name must be an integer');
  if (v is int) return v;
  if (v is double && v == v.truncateToDouble()) return v.toInt();
  if (v is String) {
    final parsed = int.tryParse(v.trim());
    if (parsed != null) return parsed;
    final asDouble = double.tryParse(v.trim());
    if (asDouble != null && asDouble == asDouble.truncateToDouble()) {
      return asDouble.toInt();
    }
  }
  throw ConfigError('$name must be an integer');
}

List<int> _hexBytes(String value, String name) {
  final text = value.trim().toLowerCase();
  if (text.isEmpty || text.length.isOdd) {
    throw ConfigError('$name has an odd length or is empty');
  }
  final out = <int>[];
  for (var i = 0; i < text.length; i += 2) {
    final byte = int.tryParse(text.substring(i, i + 2), radix: 16);
    if (byte == null) throw ConfigError('$name is not valid hex');
    out.add(byte);
  }
  return out;
}

List<String> _cleanStringList(dynamic v, String name) {
  if (v is! List) throw ConfigError('$name must be a list');
  return [
    for (final x in v)
      if (x.toString().trim().isNotEmpty) x.toString().trim(),
  ];
}

/// Number of decimal places of a double, as PC does with
/// `Decimal(str(offset))` (e.g. 0.123 -> 3, 0.5 -> 1, 1.0 -> 0).
int _decimalPlaces(double value) {
  final text = value.toString();
  if (text.contains('e') || text.contains('E')) {
    // Scientific notation: parse via fixed expansion; offsets in range
    // [-0.5, 0.5] with >3 decimals are rejected either way by magnitude.
    final asFixed = value.toStringAsFixed(10);
    final trimmed = asFixed.replaceAll(RegExp(r'0+$'), '');
    final dot = trimmed.indexOf('.');
    return dot < 0 ? 0 : trimmed.length - dot - 1;
  }
  final dot = text.indexOf('.');
  if (dot < 0) return 0;
  return text.length - dot - 1;
}

/// Immutable application configuration.
class AppConfig {
  final String phone;
  final String password; // in-memory only; never written by toJson default
  final int shopId;
  final double minAmount;
  final double maxAmount;
  final double randomConfirmWindowSec;
  final double randomConfirmFallbackSec;
  final double confirmRetryDelaySec;
  final double pollIntervalSec;
  final double pollJitterSec;
  final double pollFailureMaxSec;
  final int memoMode;
  final List<String> memoKeywords; // legacy field, migration source
  final List<String> memoExcludeKeywords;
  final List<String> memoIncludeKeywords;
  final List<String> blacklist;
  final Map<String, double> confirmWaitByShop;
  final bool rotateEnabled;
  final int rotateMinutes;
  final double confirmWaitMin;
  final double confirmWaitMax;
  final double autoWaitOffset;
  final bool runRestEnabled;
  final int riskRunMin;
  final int riskRunMax;
  final int riskRestMin;
  final int riskRestMax;
  final String aesKeyHex;
  final String aesIvHex;
  final String aesKeyHexAlt;
  final String aesIvHexAlt;
  final double requestTimeoutSec;
  final bool verifyTls;
  final bool voiceEnabled;
  final bool autoStopAfterGrab;
  final bool notifyEnabled;
  final String notifyProvider;
  final String notifyBarkServer;
  final String notifyKey;
  final String notifyWebhook;
  final double seenTtlSec;
  final String theme;
  final Object uiScale; // 'auto' or a double in [0.8, 1.6]
  final List<int> itemSwitchIds; // runtime-written, not a default
  final bool itemSwitchKnown;
  final Map<String, String> itemSwitchNames;
  final Map<String, List<String>> itemNameMap;
  final List<String> itemAlwaysTypes;
  final String clerkName;
  final String updatedAt;
  final double busyCooldownSec;

  /// Keys present in the source JSON that are not known config keys.
  /// Unknown keys are retained on save (PC merge semantics, §2 rule 12).
  final Map<String, dynamic> extra;

  const AppConfig({
    required this.phone,
    required this.password,
    required this.shopId,
    required this.minAmount,
    required this.maxAmount,
    required this.randomConfirmWindowSec,
    required this.randomConfirmFallbackSec,
    required this.confirmRetryDelaySec,
    required this.pollIntervalSec,
    required this.pollJitterSec,
    required this.pollFailureMaxSec,
    required this.memoMode,
    required this.memoKeywords,
    required this.memoExcludeKeywords,
    required this.memoIncludeKeywords,
    required this.blacklist,
    required this.confirmWaitByShop,
    required this.rotateEnabled,
    required this.rotateMinutes,
    required this.confirmWaitMin,
    required this.confirmWaitMax,
    required this.autoWaitOffset,
    required this.runRestEnabled,
    required this.riskRunMin,
    required this.riskRunMax,
    required this.riskRestMin,
    required this.riskRestMax,
    required this.aesKeyHex,
    required this.aesIvHex,
    required this.aesKeyHexAlt,
    required this.aesIvHexAlt,
    required this.requestTimeoutSec,
    required this.verifyTls,
    required this.voiceEnabled,
    required this.autoStopAfterGrab,
    required this.notifyEnabled,
    required this.notifyProvider,
    required this.notifyBarkServer,
    required this.notifyKey,
    required this.notifyWebhook,
    required this.seenTtlSec,
    required this.theme,
    required this.uiScale,
    required this.itemSwitchIds,
    required this.itemSwitchKnown,
    required this.itemSwitchNames,
    required this.itemNameMap,
    required this.itemAlwaysTypes,
    required this.clerkName,
    required this.updatedAt,
    required this.busyCooldownSec,
    this.extra = const {},
  });

  factory AppConfig.defaults() => AppConfig.fromJson(const {});

  /// Merge [json] over the defaults, validate (PC `config.validate`
  /// semantics) and return the config. Unknown keys are retained in
  /// [extra]; the legacy `user_delay` key is dropped.
  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final merged = Map<String, dynamic>.from(defaultConfigJson())
      ..addAll(json);
    merged.remove('user_delay');

    // AES keys.
    for (final name in <String>['aes_key_hex', 'aes_key_hex_alt']) {
      final raw = merged[name];
      if (raw is! String) throw ConfigError('$name must be a hex string');
      final bytes = _hexBytes(raw, name);
      if (bytes.length != 16 && bytes.length != 32) {
        throw ConfigError(
            '$name must decode to 16 bytes (AES-128) or 32 bytes (AES-256)');
      }
    }
    for (final name in <String>['aes_iv_hex', 'aes_iv_hex_alt']) {
      final raw = merged[name];
      if (raw is! String) throw ConfigError('$name must be a hex string');
      if (_hexBytes(raw, name).length != 16) {
        throw ConfigError('$name must decode to 16 bytes');
      }
    }

    String provider = (merged['notify_provider'] ?? 'serverchan').toString();
    if (!notifyProviders.contains(provider)) provider = 'serverchan';

    final rotateMinutes = _asInt(merged['rotate_minutes'] ?? 30, 'rotate_minutes');
    if (rotateMinutes < 5 || rotateMinutes > 600) {
      throw const ConfigError('rotate_minutes must be between 5 and 600');
    }

    final shopId = _asInt(merged['shop_id'] ?? 0, 'shop_id');
    if (shopId < 0) {
      throw const ConfigError('shop_id must be 0 (auto) or a positive shop id');
    }

    final minAmount = _asDouble(merged['min_amount'] ?? 10.0);
    final maxAmount = _asDouble(merged['max_amount'] ?? 0.0);
    if (minAmount < 0 || maxAmount < 0) {
      throw const ConfigError('amounts must not be negative');
    }
    if (maxAmount > 0 && maxAmount < minAmount) {
      throw const ConfigError('max_amount must be 0 (unlimited) or >= min_amount');
    }
    if (_asDouble(merged['poll_interval_sec'] ?? 0.6) <= 0) {
      throw const ConfigError('poll_interval_sec must be positive');
    }
    final memoMode = _asInt(merged['memo_mode'] ?? 0, 'memo_mode');
    if (memoMode < 0 || memoMode > 3) {
      throw const ConfigError(
          'memo_mode must be 0..3 (ignore / drop-memo / exclude-keywords / include-keywords)');
    }
    for (final name in <String>[
      'random_confirm_window_sec',
      'random_confirm_fallback_sec',
    ]) {
      final value = _asDouble(merged[name] ?? 20);
      if (value < 0.1 || value > 86400) {
        throw ConfigError('$name must be between 0.1 and 86400');
      }
    }
    final retry = _asDouble(merged['confirm_retry_delay_sec'] ?? 0.5);
    if (retry < 0 || retry > 60) {
      throw const ConfigError('confirm_retry_delay_sec must be between 0 and 60');
    }

    final waitError = confirmWaitError(merged);
    if (waitError != null) throw ConfigError(waitError);

    final offset = _asDouble(merged['auto_wait_offset'] ?? 0.0);
    if (offset < -0.5 || offset > 0.5) {
      throw const ConfigError('auto_wait_offset must be between -0.5 and +0.5');
    }
    if (_decimalPlaces(offset) > 3) {
      throw const ConfigError('auto_wait_offset must have at most 3 decimal places');
    }

    if (merged['run_rest_enabled'] is! bool) {
      throw const ConfigError('run_rest_enabled must be true or false');
    }
    int riskMin(String name) {
      final v = merged[name];
      if (v is bool || v is! num) {
        throw ConfigError('$name must be an integer number of minutes');
      }
      final d = v.toDouble();
      if (d != d.truncateToDouble()) {
        throw ConfigError('$name must be an integer number of minutes');
      }
      return d.toInt();
    }

    final riskRunMin = riskMin('risk_run_min');
    final riskRunMax = riskMin('risk_run_max');
    final riskRestMin = riskMin('risk_rest_min');
    final riskRestMax = riskMin('risk_rest_max');
    if (riskRunMin < 1) throw const ConfigError('risk_run_min must be >= 1');
    if (riskRunMax < riskRunMin) {
      throw const ConfigError('risk_run_max must be >= risk_run_min');
    }
    if (riskRestMin < 0) throw const ConfigError('risk_rest_min must be >= 0');
    if (riskRestMax < riskRestMin) {
      throw const ConfigError('risk_rest_max must be >= risk_rest_min');
    }
    if (_asDouble(merged['request_timeout_sec'] ?? 15) <= 0) {
      throw const ConfigError('request_timeout_sec must be positive');
    }
    if (_asDouble(merged['seen_ttl_sec'] ?? 60) <= 0) {
      throw const ConfigError('seen_ttl_sec must be positive');
    }

    final memoKeywords = _cleanStringList(merged['memo_keywords'], 'memo_keywords');
    var memoExclude =
        _cleanStringList(merged['memo_exclude_keywords'], 'memo_exclude_keywords');
    var memoInclude =
        _cleanStringList(merged['memo_include_keywords'], 'memo_include_keywords');
    final blacklist = _cleanStringList(merged['blacklist'], 'blacklist');
    // Legacy migration: a non-empty old memo_keywords moves to the list
    // matching the mode (mode 3 -> include, else exclude), only when the
    // target list is empty.
    if (memoKeywords.isNotEmpty) {
      if (memoMode == 3) {
        if (memoInclude.isEmpty) memoInclude = List.of(memoKeywords);
      } else {
        if (memoExclude.isEmpty) memoExclude = List.of(memoKeywords);
      }
    }

    final alwaysRaw = merged['item_always_types'];
    List<String> always;
    if (alwaysRaw is String) {
      always = [
        for (final w in alwaysRaw.replaceAll('，', ',').split(','))
          if (w.trim().isNotEmpty) w.trim(),
      ];
    } else {
      always = _cleanStringList(alwaysRaw, 'item_always_types');
    }

    final nameMapRaw = merged['item_name_map'];
    if (nameMapRaw is! Map) {
      throw const ConfigError('item_name_map must be an object');
    }
    final nameMap = <String, List<String>>{};
    for (final entry in nameMapRaw.entries) {
      final words = entry.value;
      List<String> list;
      if (words is String) {
        list = [
          for (final w in words.replaceAll('，', ',').split(','))
            if (w.trim().isNotEmpty) w.trim(),
        ];
      } else if (words is List) {
        list = [
          for (final w in words)
            if (w.toString().trim().isNotEmpty) w.toString().trim(),
        ];
      } else {
        throw const ConfigError('item_name_map values must be lists');
      }
      nameMap[entry.key.toString().trim()] = list;
    }

    Object uiScale;
    final scaleRaw = merged['ui_scale'] ?? 'auto';
    if (scaleRaw is String && scaleRaw.trim().toLowerCase() == 'auto') {
      uiScale = 'auto';
    } else {
      final value = _asDouble(scaleRaw);
      if (value < 0.8 || value > 1.6) {
        throw const ConfigError("ui_scale must be 'auto' or between 0.8 and 1.6");
      }
      uiScale = double.parse(value.toStringAsFixed(2));
    }

    final themeRaw = (merged['theme'] ?? 'day').toString().trim();
    final theme = themeIds.contains(themeRaw) ? themeRaw : 'day';

    final waitTableRaw = merged['confirm_wait_by_shop'];
    final waitTable = <String, double>{};
    if (waitTableRaw is Map) {
      for (final entry in waitTableRaw.entries) {
        waitTable[entry.key.toString()] = _asDouble(entry.value);
      }
    }

    final switchNamesRaw = merged['item_switch_names'];
    final switchNames = <String, String>{};
    if (switchNamesRaw is Map) {
      for (final entry in switchNamesRaw.entries) {
        switchNames[entry.key.toString()] = entry.value.toString();
      }
    }

    final switchIdsRaw = merged['item_switch_ids'];
    final switchIds = <int>[];
    if (switchIdsRaw is List) {
      for (final v in switchIdsRaw) {
        try {
          switchIds.add(_asInt(v, 'item_switch_ids'));
        } catch (_) {
          // Ignore non-integer ids rather than failing the whole config.
        }
      }
    }

    final knownKeys = defaultConfigJson().keys.toSet();
    final extra = <String, dynamic>{};
    for (final entry in merged.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }

    return AppConfig(
      phone: (merged['phone'] ?? '').toString().trim(),
      password: (merged['password'] ?? '').toString(),
      shopId: shopId,
      minAmount: minAmount,
      maxAmount: maxAmount,
      randomConfirmWindowSec:
          _asDouble(merged['random_confirm_window_sec'] ?? 20),
      randomConfirmFallbackSec:
          _asDouble(merged['random_confirm_fallback_sec'] ?? 20),
      confirmRetryDelaySec: retry,
      pollIntervalSec: _asDouble(merged['poll_interval_sec'] ?? 0.6),
      pollJitterSec: _asDouble(merged['poll_jitter_sec'] ?? 0.2),
      pollFailureMaxSec: _asDouble(merged['poll_failure_max_sec'] ?? 20.0),
      memoMode: memoMode,
      memoKeywords: memoKeywords,
      memoExcludeKeywords: memoExclude,
      memoIncludeKeywords: memoInclude,
      blacklist: blacklist,
      confirmWaitByShop: waitTable,
      rotateEnabled: merged['rotate_enabled'] == true,
      rotateMinutes: rotateMinutes,
      confirmWaitMin: _asDouble(merged['confirm_wait_min'] ?? 0),
      confirmWaitMax: _asDouble(merged['confirm_wait_max'] ?? 0),
      autoWaitOffset: offset,
      runRestEnabled: merged['run_rest_enabled'] == true,
      riskRunMin: riskRunMin,
      riskRunMax: riskRunMax,
      riskRestMin: riskRestMin,
      riskRestMax: riskRestMax,
      aesKeyHex: (merged['aes_key_hex'] as String).trim().toLowerCase(),
      aesIvHex: (merged['aes_iv_hex'] as String).trim().toLowerCase(),
      aesKeyHexAlt: (merged['aes_key_hex_alt'] as String).trim().toLowerCase(),
      aesIvHexAlt: (merged['aes_iv_hex_alt'] as String).trim().toLowerCase(),
      requestTimeoutSec: _asDouble(merged['request_timeout_sec'] ?? 15),
      verifyTls: merged['verify_tls'] != false,
      voiceEnabled: merged['voice_enabled'] != false,
      autoStopAfterGrab: merged['auto_stop_after_grab'] != false,
      notifyEnabled: merged['notify_enabled'] == true,
      notifyProvider: provider,
      notifyBarkServer:
          (merged['notify_bark_server'] ?? 'https://api.day.app').toString(),
      notifyKey: (merged['notify_key'] ?? '').toString(),
      notifyWebhook: (merged['notify_webhook'] ?? '').toString(),
      seenTtlSec: _asDouble(merged['seen_ttl_sec'] ?? 60),
      theme: theme,
      uiScale: uiScale,
      itemSwitchIds: switchIds,
      itemSwitchKnown: merged['item_switch_known'] == true,
      itemSwitchNames: switchNames,
      itemNameMap: nameMap,
      itemAlwaysTypes: always,
      clerkName: (merged['clerk_name'] ?? '').toString(),
      updatedAt: (merged['updated_at'] ?? '').toString(),
      busyCooldownSec: _asDouble(merged['busy_cooldown_sec'] ?? 60.0),
      extra: extra,
    );
  }

  /// Serialize to the PC-compatible snake_case JSON. By default the
  /// `password` is omitted (credentials live in secure storage, §1.7);
  /// pass [includeCredentials] only for an explicit PC-interop export.
  Map<String, dynamic> toJson({bool includeCredentials = false}) {
    final map = <String, dynamic>{
      'phone': phone,
      if (includeCredentials) 'password': password,
      'shop_id': shopId,
      'min_amount': minAmount,
      'max_amount': maxAmount,
      'random_confirm_window_sec': randomConfirmWindowSec,
      'random_confirm_fallback_sec': randomConfirmFallbackSec,
      'confirm_retry_delay_sec': confirmRetryDelaySec,
      'poll_interval_sec': pollIntervalSec,
      'poll_jitter_sec': pollJitterSec,
      'poll_failure_max_sec': pollFailureMaxSec,
      'memo_mode': memoMode,
      'memo_keywords': memoKeywords,
      'memo_exclude_keywords': memoExcludeKeywords,
      'memo_include_keywords': memoIncludeKeywords,
      'blacklist': blacklist,
      'confirm_wait_by_shop': confirmWaitByShop,
      'rotate_enabled': rotateEnabled,
      'rotate_minutes': rotateMinutes,
      'confirm_wait_min': confirmWaitMin,
      'confirm_wait_max': confirmWaitMax,
      'auto_wait_offset': autoWaitOffset,
      'run_rest_enabled': runRestEnabled,
      'risk_run_min': riskRunMin,
      'risk_run_max': riskRunMax,
      'risk_rest_min': riskRestMin,
      'risk_rest_max': riskRestMax,
      'aes_key_hex': aesKeyHex,
      'aes_iv_hex': aesIvHex,
      'aes_key_hex_alt': aesKeyHexAlt,
      'aes_iv_hex_alt': aesIvHexAlt,
      'request_timeout_sec': requestTimeoutSec,
      'verify_tls': verifyTls,
      'voice_enabled': voiceEnabled,
      'auto_stop_after_grab': autoStopAfterGrab,
      'notify_enabled': notifyEnabled,
      'notify_provider': notifyProvider,
      'notify_bark_server': notifyBarkServer,
      'notify_key': notifyKey,
      'notify_webhook': notifyWebhook,
      'seen_ttl_sec': seenTtlSec,
      'theme': theme,
      'ui_scale': uiScale,
      'item_switch_ids': itemSwitchIds,
      'item_switch_known': itemSwitchKnown,
      'item_switch_names': itemSwitchNames,
      'item_name_map': itemNameMap,
      'item_always_types': itemAlwaysTypes,
      'clerk_name': clerkName,
      'updated_at': updatedAt,
      'busy_cooldown_sec': busyCooldownSec,
    };
    map.addAll(extra);
    return map;
  }

  AppConfig copyWith({
    String? phone,
    String? password,
    int? shopId,
    double? minAmount,
    double? maxAmount,
    double? randomConfirmWindowSec,
    double? randomConfirmFallbackSec,
    double? confirmRetryDelaySec,
    double? pollIntervalSec,
    double? pollJitterSec,
    double? pollFailureMaxSec,
    int? memoMode,
    List<String>? memoKeywords,
    List<String>? memoExcludeKeywords,
    List<String>? memoIncludeKeywords,
    List<String>? blacklist,
    Map<String, double>? confirmWaitByShop,
    bool? rotateEnabled,
    int? rotateMinutes,
    double? confirmWaitMin,
    double? confirmWaitMax,
    double? autoWaitOffset,
    bool? runRestEnabled,
    int? riskRunMin,
    int? riskRunMax,
    int? riskRestMin,
    int? riskRestMax,
    String? aesKeyHex,
    String? aesIvHex,
    String? aesKeyHexAlt,
    String? aesIvHexAlt,
    double? requestTimeoutSec,
    bool? verifyTls,
    bool? voiceEnabled,
    bool? autoStopAfterGrab,
    bool? notifyEnabled,
    String? notifyProvider,
    String? notifyBarkServer,
    String? notifyKey,
    String? notifyWebhook,
    double? seenTtlSec,
    String? theme,
    Object? uiScale,
    List<int>? itemSwitchIds,
    bool? itemSwitchKnown,
    Map<String, String>? itemSwitchNames,
    Map<String, List<String>>? itemNameMap,
    List<String>? itemAlwaysTypes,
    String? clerkName,
    String? updatedAt,
    double? busyCooldownSec,
    Map<String, dynamic>? extra,
  }) {
    return AppConfig(
      phone: phone ?? this.phone,
      password: password ?? this.password,
      shopId: shopId ?? this.shopId,
      minAmount: minAmount ?? this.minAmount,
      maxAmount: maxAmount ?? this.maxAmount,
      randomConfirmWindowSec:
          randomConfirmWindowSec ?? this.randomConfirmWindowSec,
      randomConfirmFallbackSec:
          randomConfirmFallbackSec ?? this.randomConfirmFallbackSec,
      confirmRetryDelaySec: confirmRetryDelaySec ?? this.confirmRetryDelaySec,
      pollIntervalSec: pollIntervalSec ?? this.pollIntervalSec,
      pollJitterSec: pollJitterSec ?? this.pollJitterSec,
      pollFailureMaxSec: pollFailureMaxSec ?? this.pollFailureMaxSec,
      memoMode: memoMode ?? this.memoMode,
      memoKeywords: memoKeywords ?? this.memoKeywords,
      memoExcludeKeywords: memoExcludeKeywords ?? this.memoExcludeKeywords,
      memoIncludeKeywords: memoIncludeKeywords ?? this.memoIncludeKeywords,
      blacklist: blacklist ?? this.blacklist,
      confirmWaitByShop: confirmWaitByShop ?? this.confirmWaitByShop,
      rotateEnabled: rotateEnabled ?? this.rotateEnabled,
      rotateMinutes: rotateMinutes ?? this.rotateMinutes,
      confirmWaitMin: confirmWaitMin ?? this.confirmWaitMin,
      confirmWaitMax: confirmWaitMax ?? this.confirmWaitMax,
      autoWaitOffset: autoWaitOffset ?? this.autoWaitOffset,
      runRestEnabled: runRestEnabled ?? this.runRestEnabled,
      riskRunMin: riskRunMin ?? this.riskRunMin,
      riskRunMax: riskRunMax ?? this.riskRunMax,
      riskRestMin: riskRestMin ?? this.riskRestMin,
      riskRestMax: riskRestMax ?? this.riskRestMax,
      aesKeyHex: aesKeyHex ?? this.aesKeyHex,
      aesIvHex: aesIvHex ?? this.aesIvHex,
      aesKeyHexAlt: aesKeyHexAlt ?? this.aesKeyHexAlt,
      aesIvHexAlt: aesIvHexAlt ?? this.aesIvHexAlt,
      requestTimeoutSec: requestTimeoutSec ?? this.requestTimeoutSec,
      verifyTls: verifyTls ?? this.verifyTls,
      voiceEnabled: voiceEnabled ?? this.voiceEnabled,
      autoStopAfterGrab: autoStopAfterGrab ?? this.autoStopAfterGrab,
      notifyEnabled: notifyEnabled ?? this.notifyEnabled,
      notifyProvider: notifyProvider ?? this.notifyProvider,
      notifyBarkServer: notifyBarkServer ?? this.notifyBarkServer,
      notifyKey: notifyKey ?? this.notifyKey,
      notifyWebhook: notifyWebhook ?? this.notifyWebhook,
      seenTtlSec: seenTtlSec ?? this.seenTtlSec,
      theme: theme ?? this.theme,
      uiScale: uiScale ?? this.uiScale,
      itemSwitchIds: itemSwitchIds ?? this.itemSwitchIds,
      itemSwitchKnown: itemSwitchKnown ?? this.itemSwitchKnown,
      itemSwitchNames: itemSwitchNames ?? this.itemSwitchNames,
      itemNameMap: itemNameMap ?? this.itemNameMap,
      itemAlwaysTypes: itemAlwaysTypes ?? this.itemAlwaysTypes,
      clerkName: clerkName ?? this.clerkName,
      updatedAt: updatedAt ?? this.updatedAt,
      busyCooldownSec: busyCooldownSec ?? this.busyCooldownSec,
      extra: extra ?? this.extra,
    );
  }
}

/// JSON-file persistence for [AppConfig] (PC `config.load`/`save`):
/// atomic write (temp file + rename); a corrupt file is backed up as
/// `<name>.broken-<yyyyMMddHHmmss>` and rebuilt from defaults.
class ConfigFileStore {
  final File file;
  ConfigFileStore(this.file);

  AppConfig load() {
    if (!file.existsSync()) {
      final cfg = AppConfig.defaults();
      save(cfg);
      return cfg;
    }
    final text = file.readAsStringSync(encoding: utf8);
    Map<String, dynamic> raw;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const ConfigError('config file must contain a JSON object');
      }
      raw = decoded;
    } on FormatException {
      _backupBroken();
      final cfg = AppConfig.defaults();
      save(cfg);
      return cfg.copyWith(extra: {
        ...cfg.extra,
        '_recovered_from': _lastBrokenPath ?? '',
      });
    }
    final cfg = AppConfig.fromJson(raw);
    // Write back so newly added default keys are persisted.
    if (raw.keys.toSet() != cfg.toJson().keys.toSet()) {
      save(cfg);
    }
    return cfg;
  }

  String? _lastBrokenPath;

  void _backupBroken() {
    final stamp = _brokenStamp(DateTime.now());
    final broken = File('${file.path}.broken-$stamp');
    try {
      file.copySync(broken.path);
      _lastBrokenPath = broken.path;
    } catch (_) {
      _lastBrokenPath = '(备份失败)';
    }
  }

  void save(AppConfig cfg) {
    final dir = file.parent;
    dir.createSync(recursive: true);
    final tmp = File(
        '${dir.path}/.cfg-${DateTime.now().microsecondsSinceEpoch}.tmp');
    tmp.writeAsStringSync(
        '${jsonEncode(cfg.toJson())}\n',
        encoding: utf8);
    tmp.renameSync(file.path);
  }
}

String _brokenStamp(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}${two(dt.month)}${two(dt.day)}'
      '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}
