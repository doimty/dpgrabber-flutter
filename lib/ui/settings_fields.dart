/// Shared auto-save machinery for the settings pages (§10.4/§10.5).
///
/// The settings form used to stage every text field in controllers
/// and validate the whole form at once on "保存设置". That model had
/// a real bug: a switch toggle calls `updateConfig` with the config
/// as it stands, silently discarding textbox edits that had not been
/// saved yet (the screen showed the new value, the engine ran the
/// old one). Auto-save removes the staging: each field commits on
/// submit / blur — never per keystroke — through [AppConfig.fromJson]
/// full validation, so the cross-field rules (confirm-wait min/max,
/// amount max >= min, run/rest min <= max) still gate every write.
///
/// Commit rules:
/// - parse fails -> inline error under the field, nothing written,
///   the typed text stays visible (never silently clamped, never
///   swallowed).
/// - full validation fails -> the ConfigError message (mapped to
///   Chinese for the cross-field groups) under the field, nothing
///   written.
/// - unchanged text and in-flight commits are skipped.
/// - switches / dropdowns already auto-save via `updateConfig`
///   directly and do not go through the committer.
library;

import 'package:flutter/material.dart';

import '../core.dart';
import 'app_state.dart';
import 'widgets.dart';

/// Map an [AppConfig.fromJson] (English) error onto a Chinese inline
/// message. Parse errors raised by the field builders are already
/// Chinese and pass through unchanged; unknown messages are shown
/// as-is rather than hidden.
String chineseConfigError(String message) {
  const mapping = {
    'confirm_wait_max must be >= confirm_wait_min': '等待最大不能小于等待最小',
    'confirm_wait_min must be >= 0': '等待时间不能小于 0 秒',
    'confirm_wait_max must be >= 0': '等待时间不能小于 0 秒',
    'confirm_wait_min/max must be <= 120 seconds': '等待时间不能超过 120 秒',
    'max_amount must be 0 (unlimited) or >= min_amount':
        '最大金额不能小于最小金额（填 0 不限制）',
    'amounts must not be negative': '金额不能为负数',
    'risk_run_max must be >= risk_run_min': '刷新最长不能小于刷新最短',
    'risk_rest_max must be >= risk_rest_min': '休息最长不能小于休息最短',
    'risk_run_min must be >= 1': '刷新最短不能小于 1 分钟',
    'risk_rest_min must be >= 0': '休息最短不能小于 0 分钟',
    'poll_interval_sec must be positive': '轮询间隔必须大于 0',
    'request_timeout_sec must be positive': '请求超时必须大于 0',
    'seen_ttl_sec must be positive': '订单去重时间必须大于 0',
    'auto_wait_offset must be between -0.5 and +0.5':
        '自动等待偏移必须在 -0.5 到 +0.5 之间',
    'auto_wait_offset must have at most 3 decimal places':
        '自动等待偏移最多 3 位小数',
    'rotate_minutes must be between 5 and 600': '轮换间隔必须在 5 到 600 分钟之间',
    'shop_id must be 0 (auto) or a positive shop id':
        '优先店铺填 0 为自动，或填店铺号',
    'confirm_wait_by_shop must be a mapping of shop id -> seconds':
        '按店铺等待格式应为「店铺=秒」，一行一个',
  };
  for (final entry in mapping.entries) {
    if (message.contains(entry.key)) return entry.value;
  }
  if (message.startsWith('confirm_wait_by_shop[')) {
    return '按店铺等待里的秒数必须在 0 到 120 之间';
  }
  return message;
}

/// One field's commit: parse the raw text, apply it to a candidate
/// config, run the full [AppConfig.fromJson] validation. Throws
/// [ConfigError] on any failure (parse or validation).
typedef FieldBuilder = AppConfig Function(AppConfig cfg, String rawText);

/// Owns one page's text-field controllers and their per-field commit
/// state. Constructed with the page's [AppState]; [onChanged] is
/// called after every commit attempt so the page rebuilds and shows
/// (or clears) the inline error.
class SettingsFieldCommitter {
  SettingsFieldCommitter({required this.state, required this.onChanged});

  final AppState state;
  final void Function() onChanged;

  final Map<String, TextEditingController> controllers = {};
  final Map<String, String?> errors = {};
  final Map<String, String> _lastCommitted = {};
  final Set<String> _inFlight = {};

  void register(String key, TextEditingController controller) {
    controllers[key] = controller;
    _lastCommitted[key] = controller.text;
  }

  String? error(String key) => errors[key];

  Future<void> commit(String key, FieldBuilder build) async {
    final controller = controllers[key];
    if (controller == null || _inFlight.contains(key)) return;
    final raw = controller.text;
    if (_lastCommitted[key] == raw) {
      // Text matches what is already persisted: a stale inline error
      // (e.g. user reverted to the old value) clears itself.
      if (errors.remove(key) != null) onChanged();
      return;
    }
    _inFlight.add(key);
    try {
      final candidate = build(state.config, raw);
      final validated = AppConfig.fromJson(candidate.toJson());
      await state.updateConfig(validated);
      _lastCommitted[key] = raw;
      errors.remove(key);
    } on ConfigError catch (e) {
      errors[key] = chineseConfigError(e.message);
    } catch (e) {
      errors[key] = '保存失败：$e';
    } finally {
      _inFlight.remove(key);
    }
    onChanged();
  }

  // -- parse helpers (throw ConfigError with Chinese messages) ------

  static double parseDouble(String raw, String label) {
    final v = double.tryParse(raw.trim());
    if (v == null) throw ConfigError('$label 必须是数字');
    return v;
  }

  static int parseInt(String raw, String label) {
    final v = int.tryParse(raw.trim());
    if (v == null) throw ConfigError('$label 必须是整数');
    return v;
  }

  /// One item per line, blank lines dropped.
  static List<String> parseLines(String raw) => raw
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// Comma- or Chinese-comma-separated words, blanks dropped.
  static List<String> parseWords(String raw) => raw
      .replaceAll('，', ',')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// `shop=seconds` table, one per line (PC confirm-wait table).
  static Map<String, double> parseWaitTable(String raw) {
    final table = <String, double>{};
    for (final line in parseLines(raw)) {
      final parts = line.split('=');
      if (parts.length != 2) {
        throw const ConfigError('按店铺等待格式应为「店铺=秒」，一行一个');
      }
      final seconds = double.tryParse(parts[1].trim());
      if (seconds == null) {
        throw ConfigError('按店铺等待「$line」中的秒数不是数字');
      }
      table[parts[0].trim()] = seconds;
    }
    return table;
  }
}

/// Mixin for a settings page state: owns the page's text-field
/// controllers (built from key -> initial text) plus the committer,
/// and the `LabeledField` builders that wire each field to its commit.
///
/// Usage: call [initFieldControllers] from `initState` (after `super`)
/// and [disposeFieldControllers] from `dispose`. The page's
/// `AppState` is passed in — the committer reads `state.config` at
/// commit time, so it always builds on the latest config.
mixin SettingsFieldPageState<T extends StatefulWidget> on State<T> {
  late final SettingsFieldCommitter _committer;
  final Map<String, TextEditingController> _fieldControllers = {};

  void initFieldControllers(AppState state, Map<String, String> initial) {
    _committer = SettingsFieldCommitter(
      state: state,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    for (final entry in initial.entries) {
      final controller = TextEditingController(text: entry.value);
      _fieldControllers[entry.key] = controller;
      _committer.register(entry.key, controller);
    }
  }

  void disposeFieldControllers() {
    for (final controller in _fieldControllers.values) {
      controller.dispose();
    }
  }

  TextEditingController fieldController(String key) =>
      _fieldControllers[key]!;

  /// Display labels carry their unit in full-width parentheses, e.g.
  /// '最小金额（元）'. Parse errors use the bare field name, matching
  /// the old `_double`/`_int` messages ('最小金额 必须是数字').
  static String _parseLabel(String label) {
    final i = label.lastIndexOf('（');
    if (i > 0 && label.endsWith('）')) return label.substring(0, i);
    return label;
  }

  Future<void> commitField(String key, FieldBuilder build) =>
      _committer.commit(key, build);

  LabeledField doubleField({
    required String key,
    required String label,
    String? hint,
    required AppConfig Function(AppConfig cfg, double value) apply,
  }) {
    return LabeledField(
      label: label,
      controller: fieldController(key),
      hint: hint,
      keyboardType: TextInputType.number,
      errorText: _committer.error(key),
      onSubmitted: (_) => commitField(
        key,
        (cfg, text) =>
            apply(cfg, SettingsFieldCommitter.parseDouble(text, _parseLabel(label))),
      ),
    );
  }

  LabeledField intField({
    required String key,
    required String label,
    String? hint,
    required AppConfig Function(AppConfig cfg, int value) apply,
  }) {
    return LabeledField(
      label: label,
      controller: fieldController(key),
      hint: hint,
      keyboardType: TextInputType.number,
      errorText: _committer.error(key),
      onSubmitted: (_) => commitField(
        key,
        (cfg, text) =>
            apply(cfg, SettingsFieldCommitter.parseInt(text, _parseLabel(label))),
      ),
    );
  }

  /// Multi-line list field (one item per line, 4 visible rows).
  LabeledField linesField({
    required String key,
    required String label,
    String? hint,
    required AppConfig Function(AppConfig cfg, List<String> value) apply,
  }) {
    return LabeledField(
      label: label,
      controller: fieldController(key),
      hint: hint,
      maxLines: 4,
      errorText: _committer.error(key),
      onSubmitted: (_) => commitField(
        key,
        (cfg, text) =>
            apply(cfg, SettingsFieldCommitter.parseLines(text)),
      ),
    );
  }

  /// Comma-separated words, single line.
  LabeledField wordsField({
    required String key,
    required String label,
    String? hint,
    required AppConfig Function(AppConfig cfg, List<String> value) apply,
  }) {
    return LabeledField(
      label: label,
      controller: fieldController(key),
      hint: hint,
      errorText: _committer.error(key),
      onSubmitted: (_) => commitField(
        key,
        (cfg, text) =>
            apply(cfg, SettingsFieldCommitter.parseWords(text)),
      ),
    );
  }

  /// Plain string field (keys, URLs — no numeric parse).
  LabeledField textField({
    required String key,
    required String label,
    String? hint,
    required AppConfig Function(AppConfig cfg, String value) apply,
  }) {
    return LabeledField(
      label: label,
      controller: fieldController(key),
      hint: hint,
      errorText: _committer.error(key),
      onSubmitted: (_) => commitField(
        key,
        (cfg, text) => apply(cfg, text.trim()),
      ),
    );
  }

  /// `shop=seconds` table, one per line, 4 visible rows.
  LabeledField waitTableField({
    required String key,
    required String label,
    String? hint,
    required AppConfig Function(AppConfig cfg, Map<String, double> value)
        apply,
  }) {
    return LabeledField(
      label: label,
      controller: fieldController(key),
      hint: hint,
      maxLines: 4,
      errorText: _committer.error(key),
      onSubmitted: (_) => commitField(
        key,
        (cfg, text) =>
            apply(cfg, SettingsFieldCommitter.parseWaitTable(text)),
      ),
    );
  }
}
