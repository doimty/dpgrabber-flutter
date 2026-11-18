/// Advanced settings sub-page (PORTING_CONTRACT §10.5).
///
/// Reached from the main settings page's "高级设置 ›" row. Holds the
/// rarely-touched knobs, moved verbatim (same controls, order and
/// copy): 优先店铺 / 请求超时 / 订单去重 / 名额占满冷却 / 轮询抖动 /
/// 失败退避 / TLS / 账号轮换 / 接单类型匹配词 / 抢单推送. Same
/// auto-save semantics as the main page: text fields commit on
/// submit / blur through [SettingsFieldCommitter], switches and
/// dropdowns save immediately. No save button, no AES keys anywhere.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core.dart';
import 'app_state.dart';
import 'settings_fields.dart';
import 'widgets.dart';

const _notifyProviderLabels = {
  'bark': 'Bark',
  'serverchan': 'Server酱',
  'pushplus': 'PushPlus',
  'webhook': '自定义 Webhook',
};

class AdvancedSettingsPage extends StatefulWidget {
  final AppState state;

  const AdvancedSettingsPage({super.key, required this.state});

  /// Text-field keys owned by this page (for the field-disjointness
  /// test: no key may also appear on the main SettingsPage).
  static const List<String> fieldKeys = [
    'shop_id',
    'request_timeout_sec',
    'seen_ttl_sec',
    'busy_cooldown_sec',
    'poll_jitter_sec',
    'poll_failure_max_sec',
    'rotate_minutes',
    'item_465',
    'item_2666',
    'item_2667',
    'item_always_types',
    'notify_key',
    'notify_bark_server',
    'notify_webhook',
  ];

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage>
    with SettingsFieldPageState<AdvancedSettingsPage> {
  String? _pushTestResult;

  AppState get _state => widget.state;
  AppConfig get _cfg => _state.config;

  @override
  void initState() {
    super.initState();
    final cfg = _cfg;
    initFieldControllers(_state, {
      'shop_id': cfg.shopId.toString(),
      'request_timeout_sec': _num(cfg.requestTimeoutSec),
      'seen_ttl_sec': _num(cfg.seenTtlSec),
      'busy_cooldown_sec': _num(cfg.busyCooldownSec),
      'poll_jitter_sec': _num(cfg.pollJitterSec),
      'poll_failure_max_sec': _num(cfg.pollFailureMaxSec),
      'rotate_minutes': cfg.rotateMinutes.toString(),
      'item_465': (cfg.itemNameMap['465'] ?? []).join('，'),
      'item_2666': (cfg.itemNameMap['2666'] ?? []).join('，'),
      'item_2667': (cfg.itemNameMap['2667'] ?? []).join('，'),
      'item_always_types': cfg.itemAlwaysTypes.join('，'),
      'notify_key': cfg.notifyKey,
      'notify_bark_server': cfg.notifyBarkServer,
      'notify_webhook': cfg.notifyWebhook,
    });
  }

  static String _num(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    disposeFieldControllers();
    super.dispose();
  }

  Future<void> _setProvider(String provider) async {
    await _state.updateConfig(
      _state.config.copyWith(notifyProvider: provider),
    );
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
              title: const Text('高级设置'),
            ),
            body: ListView(
              // Above AppShell: no floating pill to clear, just air.
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                // Advanced (§10.5).
                const SectionTitle('高级设置'),
                AppCard(
                  child: Column(
                    children: [
                      intField(
                        key: 'shop_id',
                        label: '优先店铺（0=自动）',
                        hint: '0 = 自动挑选有店员权限的店铺',
                        apply: (cfg, v) => cfg.copyWith(shopId: v),
                      ),
                      doubleField(
                        key: 'request_timeout_sec',
                        label: '请求超时（秒）',
                        hint: '单次请求最长等待时间',
                        apply: (cfg, v) =>
                            cfg.copyWith(requestTimeoutSec: v),
                      ),
                      doubleField(
                        key: 'seen_ttl_sec',
                        label: '订单去重时间（秒）',
                        hint: '默认 60',
                        apply: (cfg, v) => cfg.copyWith(seenTtlSec: v),
                      ),
                      doubleField(
                        key: 'busy_cooldown_sec',
                        label: '名额占满冷却（秒）',
                        hint: '默认 60',
                        apply: (cfg, v) => cfg.copyWith(busyCooldownSec: v),
                      ),
                      doubleField(
                        key: 'poll_jitter_sec',
                        label: '轮询抖动（秒）',
                        hint: '默认 0.2',
                        apply: (cfg, v) => cfg.copyWith(pollJitterSec: v),
                      ),
                      doubleField(
                        key: 'poll_failure_max_sec',
                        label: '失败退避上限（秒）',
                        hint: '默认 20',
                        apply: (cfg, v) =>
                            cfg.copyWith(pollFailureMaxSec: v),
                      ),
                      SwitchRow(
                        label: '验证服务器 TLS 证书',
                        subtitle:
                            '关闭后将接受任意证书，仅用于排障；正常使用请保持开启。',
                        value: cfg.verifyTls,
                        onChanged: (v) async {
                          await _state.updateConfig(
                            cfg.copyWith(verifyTls: v),
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
                        intField(
                          key: 'rotate_minutes',
                          label: '轮换间隔（分钟）',
                          hint: '5–600 分钟',
                          apply: (cfg, v) => cfg.copyWith(rotateMinutes: v),
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
                      wordsField(
                        key: 'item_465',
                        label: '连麦（465）',
                        hint: '例如：连麦',
                        apply: (cfg, v) => cfg.copyWith(itemNameMap: {
                          ...cfg.itemNameMap,
                          '465': v,
                        }),
                      ),
                      wordsField(
                        key: 'item_2666',
                        label: '视频（2666）',
                        hint: '例如：视频',
                        apply: (cfg, v) => cfg.copyWith(itemNameMap: {
                          ...cfg.itemNameMap,
                          '2666': v,
                        }),
                      ),
                      wordsField(
                        key: 'item_2667',
                        label: '游戏（2667）',
                        hint: '例如：游戏',
                        apply: (cfg, v) => cfg.copyWith(itemNameMap: {
                          ...cfg.itemNameMap,
                          '2667': v,
                        }),
                      ),
                      wordsField(
                        key: 'item_always_types',
                        label: '基础类型（出现即放行）',
                        hint: '例如：文字语音条，文语体验单',
                        apply: (cfg, v) => cfg.copyWith(itemAlwaysTypes: v),
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
                        decoration:
                            const InputDecoration(labelText: '推送渠道'),
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
                      textField(
                        key: 'notify_key',
                        label: '推送密钥',
                        hint: 'Bark 设备 Key / Server酱 SendKey / PushPlus token',
                        apply: (cfg, v) => cfg.copyWith(notifyKey: v),
                      ),
                      textField(
                        key: 'notify_bark_server',
                        label: 'Bark 服务端',
                        hint: '默认 https://api.day.app；自建填自己的域名',
                        apply: (cfg, v) =>
                            cfg.copyWith(notifyBarkServer: v),
                      ),
                      textField(
                        key: 'notify_webhook',
                        label: '推送 Webhook',
                        hint: '自定义地址，收到 {title, body} JSON；仅渠道为自定义 Webhook 时使用',
                        apply: (cfg, v) => cfg.copyWith(notifyWebhook: v),
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
              ],
            ),
          );
        },
      ),
    );
  }
}
