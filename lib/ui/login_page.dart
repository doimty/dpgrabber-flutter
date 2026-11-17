/// Login page (PORTING_CONTRACT §10.2).
///
/// Phone + password, empty-value validation, logging-in state, error
/// display. On success the credentials are saved and the app moves to
/// the main shell (driven by [AppState.loggedIn] in main.dart).
/// Also: pending-account hint, saved-account switcher, clear-saved-
/// account with confirmation, and the unencrypted-storage warning
/// (§1.7) while the dev file store is in use.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import 'app_state.dart';
import 'widgets.dart';

class LoginPage extends StatefulWidget {
  final AppState state;

  const LoginPage({super.key, required this.state});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;
  bool _loggingIn = false;
  String? _error;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    if (_state.config.phone.isNotEmpty) {
      _phoneController.text = _state.config.phone;
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validate() {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (phone.isEmpty) return '请输入手机号';
    if (password.isEmpty) return '请输入密码';
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length != 11) return '手机号应为 11 位数字';
    return null;
  }

  Future<void> _login() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      await _state.login(
        _phoneController.text.trim(),
        _passwordController.text,
      );
    } on ApiError catch (e) {
      setState(() => _error = '登录失败：${e.message}');
    } catch (e) {
      setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _switchTo(String phone) async {
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    final ok = await _state.switchAccount(phone);
    if (mounted) {
      setState(() {
        _loggingIn = false;
        if (!ok) _error = _state.lastError ?? '切换账号失败';
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

  @override
  Widget build(BuildContext context) {
    final palette = _state.theme.palette;
    final saved = _state.savedAccounts;
    final pendingPhone = _state.config.phone;
    return AppStateScope(
      state: _state,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: palette.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.radar,
                          color: palette.accent,
                          size: 32,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '多陪抢单',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: palette.textDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pendingPhone.isEmpty
                          ? '还没有账号配置，登录后会自动建档'
                          : '将登录 ${maskPhone(pendingPhone)}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.hint, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    if (!_state.hasSecureStorage)
                      ErrorBanner(FileCredentialStore.unencryptedWarning),
                    if (_error != null) ErrorBanner(_error!),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
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
                          ElevatedButton(
                            onPressed: _loggingIn ? null : _login,
                            child: _loggingIn
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('登录验证'),
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
                    if (saved.isNotEmpty) ...[
                      const SectionTitle('已保存账号'),
                      AppCard(
                        child: Column(
                          children: [
                            for (final account in saved)
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
