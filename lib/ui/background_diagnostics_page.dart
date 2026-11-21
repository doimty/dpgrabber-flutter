import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../core.dart' show formatLocalIso;
import 'app_state.dart';
import 'widgets.dart';

class BackgroundDiagnosticsPage extends StatelessWidget {
  final AppState state;

  const BackgroundDiagnosticsPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final palette = state.theme.palette;
    return AppStateScope(
      state: state,
      child: Scaffold(
        appBar: AppBar(title: const Text('后台诊断')),
        body: ListenableBuilder(
          listenable: state.diagnosticsUpdates,
          builder: (context, _) {
            final audio = state.keepAliveStatus;
            final showAudio = Platform.isIOS || audio != null;
            final lastResult = state.lastPollSucceeded;
            final inFlightAt = state.currentPollStartedAt;
            final duration = state.lastPollDuration;
            final lastBackgroundResult = state.lastBackgroundPollSucceeded;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                if (showAudio) ...[
                  const SectionTitle('后台音频'),
                  AppCard(
                    child: Column(
                      children: [
                        _DiagnosticRow(
                          '上次检查',
                          value: _audioStatus(audio?.state),
                          color: switch (audio?.state) {
                            'running' => palette.logSuccess,
                            'failed' => palette.logError,
                            'recovering' || 'interrupted' => palette.logWarning,
                            _ => palette.hint,
                          },
                        ),
                        if (audio?.reason case final reason?)
                          _DiagnosticRow('状态说明', value: _audioReason(reason)),
                      ],
                    ),
                  ),
                ],
                const SectionTitle('订单轮询'),
                AppCard(
                  child: Column(
                    children: [
                      _DiagnosticRow(
                        '上次结果',
                        value: switch (lastResult) {
                          true => '成功',
                          false => '失败',
                          null => '暂无记录',
                        },
                        color: switch (lastResult) {
                          true => palette.logSuccess,
                          false => palette.logError,
                          null => palette.hint,
                        },
                      ),
                      _DiagnosticRow(
                        '当前请求开始',
                        value: inFlightAt == null
                            ? '无进行中的请求'
                            : _time(inFlightAt),
                      ),
                      _DiagnosticRow(
                        '上次开始',
                        value: _time(state.lastPollStartedAt),
                      ),
                      _DiagnosticRow('上次完成', value: _time(state.lastPollAt)),
                      if (duration != null)
                        _DiagnosticRow(
                          '请求耗时',
                          value: '${duration.inMilliseconds} ms',
                        ),
                      _DiagnosticRow(
                        '本次运行',
                        value:
                            '${state.completedPollCount} 次成功 · '
                            '${state.failedPollCount} 次失败',
                      ),
                    ],
                  ),
                ),
                const SectionTitle('前后台记录'),
                AppCard(
                  child: Column(
                    children: [
                      _DiagnosticRow(
                        '应用状态',
                        value: _lifecycleLabel(state.lastLifecycleState),
                      ),
                      _DiagnosticRow(
                        '状态变更',
                        value: _time(state.lastLifecycleChangeAt),
                      ),
                      _DiagnosticRow(
                        '进入后台',
                        value: _time(state.lastBackgroundedAt),
                      ),
                      _DiagnosticRow('恢复前台', value: _time(state.lastResumedAt)),
                      _DiagnosticRow(
                        '最近后台轮询',
                        value: switch (lastBackgroundResult) {
                          true => '成功 · ${_time(state.lastBackgroundPollAt)}',
                          false => '失败 · ${_time(state.lastBackgroundPollAt)}',
                          null => '暂无记录',
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                  child: Text(
                    '时间按设备本地时区显示。记录仅保留在本次应用运行期间。'
                    '${Platform.isIOS ? '音频运行时，iOS 仍可能暂停轮询。' : ''}',
                    style: TextStyle(color: palette.hint, fontSize: 12),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _DiagnosticRow(this.label, {required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).textTheme;
    final badgeColor = color;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(label, style: colors.bodySmall)),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: badgeColor == null
                ? Text(
                    value,
                    textAlign: TextAlign.end,
                    style: colors.bodyMedium?.copyWith(
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )
                : Align(
                    alignment: Alignment.centerRight,
                    child: StatusChip(label: value, color: badgeColor),
                  ),
          ),
        ],
      ),
    );
  }
}

String _time(DateTime? time) {
  if (time == null) return '暂无记录';
  final local = time.toLocal();
  final digits = local.millisecond.toString().padLeft(3, '0');
  return '${formatLocalIso(local).replaceFirst('T', ' ')}.$digits';
}

String _lifecycleLabel(AppLifecycleState? state) => switch (state) {
  AppLifecycleState.resumed => '前台',
  AppLifecycleState.inactive => '暂时失去焦点',
  AppLifecycleState.hidden || AppLifecycleState.paused => '后台',
  AppLifecycleState.detached => '尚未附着界面',
  null => '未知',
};

String _audioStatus(String? state) => switch (state) {
  'running' => '运行中',
  'recovering' => '恢复中',
  'interrupted' => '已中断',
  'failed' => '恢复失败',
  'stopped' => '未运行',
  _ => '状态未知',
};

String _audioReason(String reason) => switch (reason) {
  'userStart' => '正在启动',
  'userStop' => '监听已停止',
  'callActive' => '通话占用音频',
  'callEnded' => '通话结束',
  'interruption' => '系统音频中断',
  'interruptionEnded' || 'secondaryAudioHintEnded' => '音频中断已结束',
  'resumeNotRequested' => '等待返回前台',
  'mediaServicesLost' => '音频服务暂不可用',
  'mediaServicesReset' => '音频服务已重置',
  'routeChanged' => '音频输出已变化',
  'engineConfigurationChanged' => '音频配置已变化',
  'retryLimitExceeded' => '恢复次数已用尽',
  'audioSessionFailed' => '音频会话启动失败',
  'audioEngineFailed' || 'audioNotRunning' => '音频引擎未运行',
  'background' => '进入后台后检查',
  'foreground' => '返回前台后检查',
  _ => '—',
};
