/// Settings page (PORTING_CONTRACT §10.2/§10.4/§10.5).
///
/// Login lives here, in the first "账号" section (§10.2): there is no
/// standalone login page — the app always boots to the shell, and an
/// unlogged-in user logs in from Settings, like the original panel's
/// "账号与店铺" section (phone + password, saved accounts, clear with
/// confirmation). There is no sign-out button: a saved account stays
/// signed in across restarts (the app rebuilds the live session
/// itself on cold start), and removing the account entirely is
/// "清除已保存账号". Saved accounts live inside the same account card
/// (divider + tappable rows), not as a separate section.
///
/// Saving is automatic (§10.4): every text field commits on submit /
/// blur through [SettingsFieldCommitter] — full [AppConfig.fromJson]
/// validation, inline error under the field, never silently clamped.
/// There is no "保存设置" button anywhere. Switches and dropdowns
/// already saved immediately via `updateConfig` and are unchanged.
/// `auto_stop_after_grab` applies immediately (§10.3).
///
/// Main page keeps the daily knobs: 账号 / 接单条件 / 确认等待 /
/// 刷新与休息 / 监听行为. The rarely-touched knobs live on the
/// [AdvancedSettingsPage] behind the "高级设置 ›" row: 优先店铺、
/// 请求超时、订单去重、名额占满冷却、轮询抖动、失败退避、TLS、
/// 账号轮换、接单类型匹配词、抢单推送. AES keys are NOT editable
/// anywhere — they live only in the config defaults and the API
/// client construction.
/// Theme / glass level / wallpaper are FIXED values (§9) and are not
/// editable here — the user asked for all theme customization to be
/// removed, keeping only her current settings.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../wenxi_ui/liquid_bottom_navigation.dart';
import '../wenxi_ui/liquid_glass.dart';
import 'advanced_settings_page.dart';
import 'app_state.dart';
import 'settings_fields.dart';
import 'widgets.dart';

const _memoModeLabels = [
  '不检测备注',
  '有备注不抢',
  '排除关键词',
  '只抢关键词',
];

class SettingsPage extends StatefulWidget {
  final AppState state;

  const SettingsPage({super.key, required this.state});

  /// Text-field keys owned by this page (for the field-disjointness
  /// test: no key may also appear on [AdvancedSettingsPage]).
  static const List<String> fieldKeys = [
    'min_amount',
    'max_amount',
    'poll_interval_sec',
    'memo_exclude_keywords',
    'memo_include_keywords',
    'blacklist',
    'confirm_wait_min',
    'confirm_wait_max',
    'confirm_wait_by_shop',
    'auto_wait_offset',
    'random_confirm_window_sec',
    'random_confirm_fallback_sec',
    'confirm_retry_delay_sec',
    'risk_run_min',
    'risk_run_max',
    'risk_rest_min',
    'risk_rest_max',
  ];

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SettingsFieldPageState<SettingsPage> {
  late final TextEditingController _phoneController;
  late final TextEditingController _passwordController;
  bool _showPassword = false;
  bool _loggingIn = false;
  String? _loginError;

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
    initFieldControllers(_state, {
      'min_amount': _num(cfg.minAmount),
      'max_amount': _num(cfg.maxAmount),
      'poll_interval_sec': _num(cfg.pollIntervalSec),
      'memo_exclude_keywords': lines(cfg.memoExcludeKeywords),
      'memo_include_keywords': lines(cfg.memoIncludeKeywords),
      'blacklist': lines(cfg.blacklist),
      'confirm_wait_min': _num(cfg.confirmWaitMin),
      'confirm_wait_max': _num(cfg.confirmWaitMax),
      'confirm_wait_by_shop': waitTable(cfg.confirmWaitByShop),
      'auto_wait_offset': _num(cfg.autoWaitOffset),
      'random_confirm_window_sec': _num(cfg.randomConfirmWindowSec),
      'random_confirm_fallback_sec': _num(cfg.randomConfirmFallbackSec),
      'confirm_retry_delay_sec': _num(cfg.confirmRetryDelaySec),
      'risk_run_min': cfg.riskRunMin.toString(),
      'risk_run_max': cfg.riskRunMax.toString(),
      'risk_rest_min': cfg.riskRestMin.toString(),
      'risk_rest_max': cfg.riskRestMax.toString(),
    });
    _phoneController = TextEditingController(text: cfg.phone);
    _passwordController = TextEditingController();
  }

  static String _num(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    disposeFieldControllers();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Account card title (17/w600): clerk name, falling back to the
  /// masked phone, then to "未登录". The clerk name is the display
  /// name — the API has no separate shop-name field.
  String get _accountTitle {
    final name = _state.clerk?.name ?? _state.config.clerkName;
    if (name.isNotEmpty) return name;
    final phone = _state.currentPhone;
    if (phone.isNotEmpty) return maskPhone(phone);
    return '未登录';
  }

  /// `店铺 {sid} · ID {id}` from live values with cached fallbacks
  /// (config.shopId / config.clerkId), so the line stays visible
  /// while the live session is still being rebuilt. Null when
  /// neither is known (shopId 0 means auto — no number to show).
  String? get _accountShopLine {
    final sid = _state.session?.sid ??
        (_state.config.shopId > 0 ? _state.config.shopId.toString() : null);
    final liveId = _state.clerk?.id ?? 0;
    final id = liveId > 0
        ? liveId
        : (_state.config.clerkId > 0 ? _state.config.clerkId : null);
    final parts = <String>[
      if (sid != null && sid.isNotEmpty) '店铺 $sid',
      if (id != null) 'ID $id',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
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

  Future<void> _setMemoMode(int mode) async {
    await _state.updateConfig(_state.config.copyWith(memoMode: mode));
    setState(() {});
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
          ),
          body: ListView(
            // The floating pill overlays the body: reserve its height
            // at the bottom so the last row clears it.
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              24 + bottomNavClearance(context),
            ),
            children: [
              // Account (§10.2): login lives here — the app never
              // blocks on a standalone login page. One card holds the
              // login form (or the logged-in identity) plus, below a
              // divider, the saved accounts and the clear button.
              const SectionTitle('账号'),
              if (_loginError != null) ErrorBanner(_loginError!),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_state.loggedIn)
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
                                    _accountTitle.characters.first
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
                                  _accountTitle,
                                  style: TextStyle(
                                    color: palette.textDark,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (_accountShopLine != null)
                                  Text(
                                    _accountShopLine!,
                                    style: TextStyle(
                                      color: palette.hint,
                                      fontSize: 13,
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
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
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
                    if (_state.savedAccounts.isNotEmpty) ...[
                      const Divider(height: 24),
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
                  ],
                ),
              ),
              // Order conditions (§10.4).
              const SectionTitle('接单条件'),
              AppCard(
                child: Column(
                  children: [
                    doubleField(
                      key: 'min_amount',
                      label: '最小金额（元）',
                      hint: '不低于此价才抢',
                      apply: (cfg, v) => cfg.copyWith(minAmount: v),
                    ),
                    doubleField(
                      key: 'max_amount',
                      label: '最大金额（元）',
                      hint: '填 0 不限制',
                      apply: (cfg, v) => cfg.copyWith(maxAmount: v),
                    ),
                    doubleField(
                      key: 'poll_interval_sec',
                      label: '轮询间隔（秒）',
                      hint: '列表刷新节奏，默认 0.6',
                      apply: (cfg, v) => cfg.copyWith(pollIntervalSec: v),
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
                      linesField(
                        key: 'memo_exclude_keywords',
                        label: '备注排除关键词（一行一个）',
                        hint: '一行一个，例如：加急',
                        apply: (cfg, v) =>
                            cfg.copyWith(memoExcludeKeywords: v),
                      ),
                      Text(
                        '命中任意一个就不抢',
                        style: TextStyle(color: palette.hint, fontSize: 12),
                      ),
                    ],
                    if (cfg.memoMode == 3) ...[
                      linesField(
                        key: 'memo_include_keywords',
                        label: '备注白名单关键词（一行一个）',
                        hint: '一行一个，例如：加急',
                        apply: (cfg, v) =>
                            cfg.copyWith(memoIncludeKeywords: v),
                      ),
                      Text(
                        '备注必须包含其中一个，否则不抢',
                        style: TextStyle(color: palette.hint, fontSize: 12),
                      ),
                    ],
                    linesField(
                      key: 'blacklist',
                      label: '黑名单微信号（一行一个）',
                      hint: '命中就不抢',
                      apply: (cfg, v) => cfg.copyWith(blacklist: v),
                    ),
                  ],
                ),
              ),
              // Confirm wait (§3.3).
              const SectionTitle('确认等待'),
              AppCard(
                child: Column(
                  children: [
                    doubleField(
                      key: 'confirm_wait_min',
                      label: '等待最小（秒）',
                      hint: '0 不等待；与最大相同即固定等待',
                      apply: (cfg, v) => cfg.copyWith(confirmWaitMin: v),
                    ),
                    doubleField(
                      key: 'confirm_wait_max',
                      label: '等待最大（秒）',
                      hint: '0–120 秒',
                      apply: (cfg, v) => cfg.copyWith(confirmWaitMax: v),
                    ),
                    waitTableField(
                      key: 'confirm_wait_by_shop',
                      label: '按店铺等待（一行一个，格式 店铺=秒）',
                      hint: '例如：92=5.0',
                      apply: (cfg, v) => cfg.copyWith(confirmWaitByShop: v),
                    ),
                    doubleField(
                      key: 'auto_wait_offset',
                      label: '自动等待偏移（秒）',
                      hint: '仅 50 / 105 / 1391 三店叠加，-0.5–+0.5',
                      apply: (cfg, v) => cfg.copyWith(autoWaitOffset: v),
                    ),
                    doubleField(
                      key: 'random_confirm_window_sec',
                      label: '确认窗口（秒）',
                      hint: '默认 20',
                      apply: (cfg, v) =>
                          cfg.copyWith(randomConfirmWindowSec: v),
                    ),
                    doubleField(
                      key: 'random_confirm_fallback_sec',
                      label: '确认窗口（无订单时间时，秒）',
                      hint: '默认 20',
                      apply: (cfg, v) =>
                          cfg.copyWith(randomConfirmFallbackSec: v),
                    ),
                    doubleField(
                      key: 'confirm_retry_delay_sec',
                      label: '确认重试间隔（秒）',
                      hint: '默认 0.5',
                      apply: (cfg, v) =>
                          cfg.copyWith(confirmRetryDelaySec: v),
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
                    intField(
                      key: 'risk_run_min',
                      label: '刷新最短（分钟）',
                      apply: (cfg, v) => cfg.copyWith(riskRunMin: v),
                    ),
                    intField(
                      key: 'risk_run_max',
                      label: '刷新最长（分钟）',
                      apply: (cfg, v) => cfg.copyWith(riskRunMax: v),
                    ),
                    intField(
                      key: 'risk_rest_min',
                      label: '休息最短（分钟）',
                      apply: (cfg, v) => cfg.copyWith(riskRestMin: v),
                    ),
                    intField(
                      key: 'risk_rest_max',
                      label: '休息最长（分钟）',
                      apply: (cfg, v) => cfg.copyWith(riskRestMax: v),
                    ),
                  ],
                ),
              ),
              // Listening behaviour: the two daily switches, pulled up
              // from the old "高级设置" section.
              const SectionTitle('监听行为'),
              AppCard(
                child: Column(
                  children: [
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
              // Advanced settings live on their own sub-page.
              const SizedBox(height: 8),
              AppCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '高级设置',
                    style: TextStyle(
                      color: palette.textDark,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '优先店铺、推送、接单类型匹配词等',
                    style: TextStyle(color: palette.hint, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AdvancedSettingsPage(state: _state),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
    );
  }
}
