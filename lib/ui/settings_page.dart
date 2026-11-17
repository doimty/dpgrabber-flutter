/// Settings page (PORTING_CONTRACT §10.2/§10.4/§10.5/§10.7).
///
/// Login lives here, in the first "账号" section (§10.2): there is no
/// standalone login page — the app always boots to the shell, and an
/// unlogged-in user logs in from Settings, like the original panel's
/// "账号与店铺" section (phone + password, saved accounts, clear with
/// confirmation). Logout clears only the in-memory session; the saved
/// account stays for one-tap re-login.
/// All config items (§2): order conditions, confirm wait, run/rest,
/// shop/timeout/dedup, push, voice, rotation, TLS, AES keys, item
/// name map, blacklist + memo keywords (advanced).
/// Theme / glass level / wallpaper are FIXED values (§9) and are not
/// editable here — the user asked for all theme customization to be
/// removed, keeping only her current settings. Other edits apply on
/// "保存设置" (validated via [AppConfig.fromJson] — invalid values
/// are rejected with the config error, never silently clamped).
/// `auto_stop_after_grab` applies immediately (§10.3).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../wenxi_ui/liquid_bottom_navigation.dart';
import '../wenxi_ui/liquid_glass.dart';
import 'app_state.dart';
import 'widgets.dart';

const _memoModeLabels = [
  '不检测备注',
  '有备注不抢',
  '排除关键词',
  '只抢关键词',
];

const _notifyProviderLabels = {
  'bark': 'Bark',
  'serverchan': 'Server酱',
  'pushplus': 'PushPlus',
  'webhook': '自定义 Webhook',
};

class SettingsPage extends StatefulWidget {
  final AppState state;

  const SettingsPage({super.key, required this.state});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Map<String, TextEditingController> _c;
  late final TextEditingController _phoneController;
  late final TextEditingController _passwordController;
  bool _showPassword = false;
  bool _loggingIn = false;
  String? _loginError;
  String? _error;
  String? _pushTestResult;

  AppState get _state => widget.state;
  AppConfig get _cfg => _state.config;

  @override
  void initState() {
    super.initState();
    final cfg = _cfg;
    String lines(List<String> items) => items.join('\n');
    String waitTable(Map<String, double> table) => table.entries
        .map((e) => '${e.key}=${e.value}')
        .join('\n');
    _c = {
      'shop_id': TextEditingController(text: cfg.shopId.toString()),
      'min_amount': TextEditingController(text: _num(cfg.minAmount)),
      'max_amount': TextEditingController(text: _num(cfg.maxAmount)),
      'poll_interval_sec':
          TextEditingController(text: _num(cfg.pollIntervalSec)),
      'poll_jitter_sec': TextEditingController(text: _num(cfg.pollJitterSec)),
      'poll_failure_max_sec':
          TextEditingController(text: _num(cfg.pollFailureMaxSec)),
      'confirm_wait_min':
          TextEditingController(text: _num(cfg.confirmWaitMin)),
      'confirm_wait_max':
          TextEditingController(text: _num(cfg.confirmWaitMax)),
      'auto_wait_offset':
          TextEditingController(text: _num(cfg.autoWaitOffset)),
      'risk_run_min': TextEditingController(text: cfg.riskRunMin.toString()),
      'risk_run_max': TextEditingController(text: cfg.riskRunMax.toString()),
      'risk_rest_min':
          TextEditingController(text: cfg.riskRestMin.toString()),
      'risk_rest_max':
          TextEditingController(text: cfg.riskRestMax.toString()),
      'random_confirm_window_sec':
          TextEditingController(text: _num(cfg.randomConfirmWindowSec)),
      'random_confirm_fallback_sec':
          TextEditingController(text: _num(cfg.randomConfirmFallbackSec)),
      'confirm_retry_delay_sec':
          TextEditingController(text: _num(cfg.confirmRetryDelaySec)),
      'request_timeout_sec':
          TextEditingController(text: _num(cfg.requestTimeoutSec)),
      'seen_ttl_sec': TextEditingController(text: _num(cfg.seenTtlSec)),
      'busy_cooldown_sec':
          TextEditingController(text: _num(cfg.busyCooldownSec)),
      'rotate_minutes': TextEditingController(text: cfg.rotateMinutes.toString()),
      'confirm_wait_by_shop':
          TextEditingController(text: waitTable(cfg.confirmWaitByShop)),
      'blacklist': TextEditingController(text: lines(cfg.blacklist)),
      'memo_exclude_keywords':
          TextEditingController(text: lines(cfg.memoExcludeKeywords)),
      'memo_include_keywords':
          TextEditingController(text: lines(cfg.memoIncludeKeywords)),
      'notify_key': TextEditingController(text: cfg.notifyKey),
      'notify_bark_server':
          TextEditingController(text: cfg.notifyBarkServer),
      'notify_webhook': TextEditingController(text: cfg.notifyWebhook),
      'aes_key_hex': TextEditingController(text: cfg.aesKeyHex),
      'aes_iv_hex': TextEditingController(text: cfg.aesIvHex),
      'aes_key_hex_alt': TextEditingController(text: cfg.aesKeyHexAlt),
      'aes_iv_hex_alt': TextEditingController(text: cfg.aesIvHexAlt),
      'item_465': TextEditingController(
        text: (cfg.itemNameMap['465'] ?? []).join('，'),
      ),
      'item_2666': TextEditingController(
        text: (cfg.itemNameMap['2666'] ?? []).join('，'),
      ),
      'item_2667': TextEditingController(
        text: (cfg.itemNameMap['2667'] ?? []).join('，'),
      ),
      'item_always_types':
          TextEditingController(text: cfg.itemAlwaysTypes.join('，')),
    };
    _phoneController = TextEditingController(text: cfg.phone);
    _passwordController = TextEditingController();
  }

  static String _num(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String get _clerkDisplayName {
    final name = _state.clerk?.name ?? _state.config.clerkName;
    return name.isEmpty ? '未获取店员信息' : name;
  }

  // -- account (§10.2: login lives in Settings) ----------------------

  String? _validateLogin() {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (phone.isEmpty) return '请输入手机号';
    if (password.isEmpty) return '请输入密码';
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length != 11) return '手机号应为 11 位数字';
    return null;
  }

  Future<void> _login() async {
    final problem = _validateLogin();
    if (problem != null) {
      setState(() => _loginError = problem);
      return;
    }
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    try {
      await _state.login(
        _phoneController.text.trim(),
        _passwordController.text,
      );
      _passwordController.clear();
    } on ApiError catch (e) {
      setState(() => _loginError = '登录失败：${e.message}');
    } catch (e) {
      setState(() => _loginError = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _switchTo(String phone) async {
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    final ok = await _state.switchAccount(phone);
    if (mounted) {
      setState(() {
        _loggingIn = false;
        if (!ok) _loginError = _state.lastError ?? '切换账号失败';
      });
    }
  }

  Future<void> _clearSaved() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final palette = _state.theme.palette;
        return AlertDialog(
          title: const Text('清除已保存账号'),
          content: const Text('将删除已保存的手机号和密码。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('取消', style: TextStyle(color: palette.accent)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('清除', style: TextStyle(color: palette.logError)),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await _state.clearAccount();
      if (mounted) {
        _phoneController.clear();
        _passwordController.clear();
        setState(() {});
      }
    }
  }

  void _logout() {
    _state.logout();
    _passwordController.clear();
    setState(() {});
  }

  List<String> _lines(String key) => _c[key]!
      .text
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  double _double(String key, String label) {
    final v = double.tryParse(_c[key]!.text.trim());
    if (v == null) throw ConfigError('$label 必须是数字');
    return v;
  }

  int _int(String key, String label) {
    final v = int.tryParse(_c[key]!.text.trim());
    if (v == null) throw ConfigError('$label 必须是整数');
    return v;
  }

  Map<String, double> _waitTable() {
    final table = <String, double>{};
    for (final line in _lines('confirm_wait_by_shop')) {
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

  List<String> _words(String key) => _c[key]!
      .text
      .replaceAll('，', ',')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _save() async {
    setState(() => _error = null);
    try {
      final json = _cfg.toJson()
        ..['shop_id'] = _int('shop_id', '优先店铺')
        ..['min_amount'] = _double('min_amount', '最小金额')
        ..['max_amount'] = _double('max_amount', '最大金额')
        ..['poll_interval_sec'] = _double('poll_interval_sec', '轮询间隔')
        ..['poll_jitter_sec'] = _double('poll_jitter_sec', '轮询抖动')
        ..['poll_failure_max_sec'] =
            _double('poll_failure_max_sec', '失败退避上限')
        ..['confirm_wait_min'] = _double('confirm_wait_min', '等待最小')
        ..['confirm_wait_max'] = _double('confirm_wait_max', '等待最大')
        ..['auto_wait_offset'] = _double('auto_wait_offset', '自动等待偏移')
        ..['risk_run_min'] = _int('risk_run_min', '刷新最短')
        ..['risk_run_max'] = _int('risk_run_max', '刷新最长')
        ..['risk_rest_min'] = _int('risk_rest_min', '休息最短')
        ..['risk_rest_max'] = _int('risk_rest_max', '休息最长')
        ..['random_confirm_window_sec'] =
            _double('random_confirm_window_sec', '确认窗口')
        ..['random_confirm_fallback_sec'] =
            _double('random_confirm_fallback_sec', '确认窗口（无时间）')
        ..['confirm_retry_delay_sec'] =
            _double('confirm_retry_delay_sec', '确认重试间隔')
        ..['request_timeout_sec'] = _double('request_timeout_sec', '请求超时')
        ..['seen_ttl_sec'] = _double('seen_ttl_sec', '订单去重时间')
        ..['busy_cooldown_sec'] = _double('busy_cooldown_sec', '名额占满冷却')
        ..['rotate_minutes'] = _int('rotate_minutes', '轮换分钟')
        ..['confirm_wait_by_shop'] = _waitTable()
        ..['blacklist'] = _lines('blacklist')
        ..['memo_exclude_keywords'] = _lines('memo_exclude_keywords')
        ..['memo_include_keywords'] = _lines('memo_include_keywords')
        ..['notify_key'] = _c['notify_key']!.text.trim()
        ..['notify_bark_server'] = _c['notify_bark_server']!.text.trim()
        ..['notify_webhook'] = _c['notify_webhook']!.text.trim()
        ..['aes_key_hex'] = _c['aes_key_hex']!.text.trim()
        ..['aes_iv_hex'] = _c['aes_iv_hex']!.text.trim()
        ..['aes_key_hex_alt'] = _c['aes_key_hex_alt']!.text.trim()
        ..['aes_iv_hex_alt'] = _c['aes_iv_hex_alt']!.text.trim()
        ..['item_name_map'] = {
          '465': _words('item_465'),
          '2666': _words('item_2666'),
          '2667': _words('item_2667'),
        }
        ..['item_always_types'] = _words('item_always_types');
      final next = AppConfig.fromJson(json);
      await _state.updateConfig(next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置已保存')),
        );
      }
    } on ConfigError catch (e) {
      setState(() => _error = '设置有误：${e.message}');
    } catch (e) {
      setState(() => _error = '保存失败：$e');
    }
  }

  Future<void> _setMemoMode(int mode) async {
    await _state.updateConfig(_state.config.copyWith(memoMode: mode));
    setState(() {});
  }

  Future<void> _setProvider(String provider) async {
    await _state.updateConfig(
      _state.config.copyWith(notifyProvider: provider),
    );
    setState(() {});
  }

  Future<void> _restoreAesDefaults() async {
    _c['aes_key_hex']!.text = AesDefaults.keyHex;
    _c['aes_iv_hex']!.text = AesDefaults.ivHex;
    _c['aes_key_hex_alt']!.text = AesDefaults.keyHexAlt;
    _c['aes_iv_hex_alt']!.text = AesDefaults.ivHexAlt;
    setState(() {});
  }

  Future<void> _testPush() async {
    final ok = await _state.sendTestPush();
    setState(
      () => _pushTestResult = ok ? '推送测试成功' : '推送测试失败，请检查密钥与网络',
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = _state.theme.palette;
    return AppStateScope(
      state: _state,
      child: AnimatedBuilder(
      animation: _state,
      builder: (context, _) {
        final cfg = _state.config;
        return Scaffold(
          appBar: AppBar(
            title: const Text('设置'),
            actions: [
              TextButton(
                onPressed: _save,
                child: Text('保存设置', style: TextStyle(color: palette.accent)),
              ),
            ],
          ),
          body: ListView(
            // The floating pill overlays the body: reserve its height
            // at the bottom so the last slider / save button clears it.
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              24 + bottomNavClearance(context),
            ),
            children: [
              if (_error != null) ErrorBanner(_error!),
              // Account (§10.2): login lives here — the app never
              // blocks on a standalone login page.
              const SectionTitle('账号'),
              if (_loginError != null) ErrorBanner(_loginError!),
              if (_state.loggedIn)
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: palette.accent,
                            foregroundColor: Colors.white,
                            backgroundImage: _state.avatarPath.isNotEmpty
                                ? FileImage(File(_state.avatarPath))
                                : null,
                            child: _state.avatarPath.isEmpty
                                ? Text(
                                    _clerkDisplayName.isEmpty
                                        ? '多'
                                        : _clerkDisplayName.characters.first
                                              .toUpperCase(),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _clerkDisplayName,
                                  style: TextStyle(
                                    color: palette.textDark,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _state.currentPhone.isEmpty
                                      ? '未登录'
                                      : maskPhone(_state.currentPhone),
                                  style: TextStyle(
                                    color: palette.hint,
                                    fontSize: 13,
                                  ),
                                ),
                                if (_state.session != null)
                                  Text(
                                    '店铺 ${_state.session!.sid}',
                                    style: TextStyle(
                                      color: palette.hint,
                                      fontSize: 13,
                                    ),
                                  ),
                                if (_state.clerk != null &&
                                    _state.clerk!.id > 0)
                                  Text(
                                    'ID：${_state.clerk!.id}',
                                    style: TextStyle(
                                      color: palette.hint,
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton(
                          onPressed: _logout,
                          child: Text(
                            '退出登录',
                            style: TextStyle(color: palette.logError),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_state.hasSecureStorage)
                        ErrorBanner(
                          FileCredentialStore.unencryptedWarning,
                        ),
                      Text(
                        _state.config.phone.isEmpty
                            ? '还没有账号配置，登录后会自动建档'
                            : '将登录 ${maskPhone(_state.config.phone)}',
                        style: TextStyle(
                          color: palette.hint,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LabeledField(
                        label: '手机号',
                        controller: _phoneController,
                        hint: '11 位手机号',
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(11),
                        ],
                      ),
                      LabeledField(
                        label: '密码',
                        controller: _passwordController,
                        hint: '账号密码',
                        obscureText: !_showPassword,
                        suffixIcon: IconButton(
                          tooltip: _showPassword ? '隐藏密码' : '显示密码',
                          onPressed: () => setState(
                            () => _showPassword = !_showPassword,
                          ),
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: palette.hint,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      LiquidGlassButton(
                        onPressed: _loggingIn ? null : _login,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                          ),
                        ),
                        child: _loggingIn
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                '登录验证',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _loggingIn ? '正在登录…' : '请输入手机号和密码后登录',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: palette.hint,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_state.savedAccounts.isNotEmpty) ...[
                const SectionTitle('已保存账号'),
                AppCard(
                  child: Column(
                    children: [
                      for (final account in _state.savedAccounts)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            AccountStore.labelFor(account),
                            style: TextStyle(color: palette.textDark),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _loggingIn
                              ? null
                              : () => _switchTo(
                                    (account['phone'] ?? '').toString(),
                                  ),
                        ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _clearSaved,
                          child: Text(
                            '清除已保存账号',
                            style: TextStyle(color: palette.logError),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // Order conditions (§10.4).
              const SectionTitle('接单条件'),
              AppCard(
                child: Column(
                  children: [
                    LabeledField(
                      label: '最小金额（元）',
                      controller: _c['min_amount']!,
                      hint: '不低于此价才抢',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '最大金额（元）',
                      controller: _c['max_amount']!,
                      hint: '填 0 不限制',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '轮询间隔（秒）',
                      controller: _c['poll_interval_sec']!,
                      hint: '列表刷新节奏，默认 0.6',
                      keyboardType: TextInputType.number,
                    ),
                    DropdownButtonFormField<int>(
                      initialValue: cfg.memoMode,
                      icon: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: palette.hint,
                      ),
                      decoration: const InputDecoration(labelText: '备注检测'),
                      items: [
                        for (var i = 0; i < _memoModeLabels.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(_memoModeLabels[i]),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) unawaited(_setMemoMode(v));
                      },
                    ),
                    const SizedBox(height: 10),
                    if (cfg.memoMode == 2) ...[
                      LabeledField(
                        label: '备注排除关键词（一行一个）',
                        controller: _c['memo_exclude_keywords']!,
                        hint: '一行一个，例如：加急',
                        maxLines: 4,
                      ),
                      Text(
                        '命中任意一个就不抢',
                        style: TextStyle(color: palette.hint, fontSize: 12),
                      ),
                    ],
                    if (cfg.memoMode == 3) ...[
                      LabeledField(
                        label: '备注白名单关键词（一行一个）',
                        controller: _c['memo_include_keywords']!,
                        hint: '一行一个，例如：加急',
                        maxLines: 4,
                      ),
                      Text(
                        '备注必须包含其中一个，否则不抢',
                        style: TextStyle(color: palette.hint, fontSize: 12),
                      ),
                    ],
                    LabeledField(
                      label: '黑名单微信号（一行一个）',
                      controller: _c['blacklist']!,
                      hint: '命中就不抢',
                      maxLines: 4,
                    ),
                  ],
                ),
              ),
              // Confirm wait (§3.3).
              const SectionTitle('确认等待'),
              AppCard(
                child: Column(
                  children: [
                    LabeledField(
                      label: '等待最小（秒）',
                      controller: _c['confirm_wait_min']!,
                      hint: '0 不等待；与最大相同即固定等待',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '等待最大（秒）',
                      controller: _c['confirm_wait_max']!,
                      hint: '0–120 秒',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '按店铺等待（一行一个，格式 店铺=秒）',
                      controller: _c['confirm_wait_by_shop']!,
                      hint: '例如：92=5.0',
                      maxLines: 4,
                    ),
                    LabeledField(
                      label: '自动等待偏移（秒）',
                      controller: _c['auto_wait_offset']!,
                      hint: '仅 50 / 105 / 1391 三店叠加，-0.5–+0.5',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '确认窗口（秒）',
                      controller: _c['random_confirm_window_sec']!,
                      hint: '默认 20',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '确认窗口（无订单时间时，秒）',
                      controller: _c['random_confirm_fallback_sec']!,
                      hint: '默认 20',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '确认重试间隔（秒）',
                      controller: _c['confirm_retry_delay_sec']!,
                      hint: '默认 0.5',
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
              // Run / rest (§6.6).
              const SectionTitle('刷新与休息'),
              AppCard(
                child: Column(
                  children: [
                    SwitchRow(
                      label: '开启刷新与休息（风控店铺轮换休息）',
                      value: cfg.runRestEnabled,
                      onChanged: (v) async {
                        await _state.updateConfig(
                          cfg.copyWith(runRestEnabled: v),
                        );
                        setState(() {});
                      },
                    ),
                    LabeledField(
                      label: '刷新最短（分钟）',
                      controller: _c['risk_run_min']!,
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '刷新最长（分钟）',
                      controller: _c['risk_run_max']!,
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '休息最短（分钟）',
                      controller: _c['risk_rest_min']!,
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '休息最长（分钟）',
                      controller: _c['risk_rest_max']!,
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
              // Advanced (§10.5).
              const SectionTitle('高级设置'),
              AppCard(
                child: Column(
                  children: [
                    LabeledField(
                      label: '优先店铺（0=自动）',
                      controller: _c['shop_id']!,
                      hint: '0 = 自动挑选有店员权限的店铺',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '请求超时（秒）',
                      controller: _c['request_timeout_sec']!,
                      hint: '单次请求最长等待时间',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '订单去重时间（秒）',
                      controller: _c['seen_ttl_sec']!,
                      hint: '默认 60',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '名额占满冷却（秒）',
                      controller: _c['busy_cooldown_sec']!,
                      hint: '默认 60',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '轮询抖动（秒）',
                      controller: _c['poll_jitter_sec']!,
                      hint: '默认 0.2',
                      keyboardType: TextInputType.number,
                    ),
                    LabeledField(
                      label: '失败退避上限（秒）',
                      controller: _c['poll_failure_max_sec']!,
                      hint: '默认 20',
                      keyboardType: TextInputType.number,
                    ),
                    SwitchRow(
                      label: '验证服务器 TLS 证书',
                      subtitle: '关闭后将接受任意证书，仅用于排障；正常使用请保持开启。',
                      value: cfg.verifyTls,
                      onChanged: (v) async {
                        await _state.updateConfig(cfg.copyWith(verifyTls: v));
                        setState(() {});
                      },
                    ),
                    SwitchRow(
                      label: '语音播报',
                      value: cfg.voiceEnabled,
                      onChanged: (v) async {
                        await _state.updateConfig(
                          cfg.copyWith(voiceEnabled: v),
                        );
                        setState(() {});
                      },
                    ),
                    SwitchRow(
                      label: '账号轮换',
                      subtitle: '每个账号跑这么久后自动换下一个（需要多个账号配置文件）',
                      value: cfg.rotateEnabled,
                      onChanged: (v) async {
                        await _state.updateConfig(
                          cfg.copyWith(rotateEnabled: v),
                        );
                        setState(() {});
                      },
                    ),
                    if (cfg.rotateEnabled)
                      LabeledField(
                        label: '轮换间隔（分钟）',
                        controller: _c['rotate_minutes']!,
                        hint: '5–600 分钟',
                        keyboardType: TextInputType.number,
                      ),
                    SwitchRow(
                      label: '接到单后自动停止监听',
                      value: cfg.autoStopAfterGrab,
                      onChanged: (v) async {
                        await _state.updateConfig(
                          cfg.copyWith(autoStopAfterGrab: v),
                        );
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
              // Item name map (§6.5).
              const SectionTitle('接单类型匹配词'),
              AppCard(
                child: Column(
                  children: [
                    Text(
                      '订单只带条目名称，按词匹配；留空或认不出的类型照常抢，不会误拦。多个词用中文逗号分隔。',
                      style: TextStyle(color: palette.hint, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    LabeledField(
                      label: '连麦（465）',
                      controller: _c['item_465']!,
                      hint: '例如：连麦',
                    ),
                    LabeledField(
                      label: '视频（2666）',
                      controller: _c['item_2666']!,
                      hint: '例如：视频',
                    ),
                    LabeledField(
                      label: '游戏（2667）',
                      controller: _c['item_2667']!,
                      hint: '例如：游戏',
                    ),
                    LabeledField(
                      label: '基础类型（出现即放行）',
                      controller: _c['item_always_types']!,
                      hint: '例如：文字语音条，文语体验单',
                    ),
                  ],
                ),
              ),
              // Push (§8).
              const SectionTitle('抢单推送'),
              AppCard(
                child: Column(
                  children: [
                    SwitchRow(
                      label: '开启抢单推送',
                      subtitle: '仅抢单成功时推送',
                      value: cfg.notifyEnabled,
                      onChanged: (v) async {
                        await _state.updateConfig(
                          cfg.copyWith(notifyEnabled: v),
                        );
                        setState(() {});
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: cfg.notifyProvider,
                      icon: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: palette.hint,
                      ),
                      decoration: const InputDecoration(labelText: '推送渠道'),
                      items: [
                        for (final entry in _notifyProviderLabels.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) unawaited(_setProvider(v));
                      },
                    ),
                    const SizedBox(height: 10),
                    LabeledField(
                      label: '推送密钥',
                      controller: _c['notify_key']!,
                      hint: 'Bark 设备 Key / Server酱 SendKey / PushPlus token',
                    ),
                    LabeledField(
                      label: 'Bark 服务端',
                      controller: _c['notify_bark_server']!,
                      hint: '默认 https://api.day.app；自建填自己的域名',
                    ),
                    LabeledField(
                      label: '推送 Webhook',
                      controller: _c['notify_webhook']!,
                      hint: '自定义地址，收到 {title, body} JSON；仅渠道为自定义 Webhook 时使用',
                    ),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: _testPush,
                          child: const Text('发送测试'),
                        ),
                        if (_pushTestResult != null) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _pushTestResult!,
                              style: TextStyle(
                                color: palette.hint,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // AES (§5; config values, UI editable like iOS).
              const SectionTitle('AES 密钥（十六进制）'),
              AppCard(
                child: Column(
                  children: [
                    Text(
                      '密钥用于解密服务端响应；主密钥解密失败时自动尝试备用密钥。以能解密为准，上线前须以真实接口验证。',
                      style: TextStyle(color: palette.hint, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    LabeledField(
                      label: '主密钥',
                      controller: _c['aes_key_hex']!,
                    ),
                    LabeledField(
                      label: '主 IV',
                      controller: _c['aes_iv_hex']!,
                    ),
                    LabeledField(
                      label: '备用密钥',
                      controller: _c['aes_key_hex_alt']!,
                    ),
                    LabeledField(
                      label: '备用 IV',
                      controller: _c['aes_iv_hex_alt']!,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: _restoreAesDefaults,
                        child: const Text('恢复默认密钥'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _save,
                child: const Text('保存设置'),
              ),
            ],
          ),
        );
      },
    ),
    );
  }
}
