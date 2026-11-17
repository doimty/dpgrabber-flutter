/// Listen page / dashboard (PORTING_CONTRACT §10.3).
///
/// Hero (今日抢单 from persisted history, listen status, login status,
/// renewal chip), clerk card, start/stop, auto-stop-after-grab, online
/// switch, item-type switches, week statistics (three rates), last
/// order, today counts, and the run log.
///
/// The log view is a retained-mode [ListView] over [LogStore.entries]:
/// entries live in the store, not in the widget tree, so a window
/// resize / maximise can never make them disappear (PC lesson).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';
import '../wenxi_ui/liquid_bottom_navigation.dart';
import '../wenxi_ui/liquid_glass.dart';
import 'app_state.dart';
import 'log_store.dart';
import 'widgets.dart';

class ListenPage extends StatefulWidget {
  final AppState state;

  const ListenPage({super.key, required this.state});

  @override
  State<ListenPage> createState() => _ListenPageState();
}

class _ListenPageState extends State<ListenPage> {
  final _logScroll = ScrollController();
  bool _stickToBottom = true;

  AppState get _state => widget.state;

  String get _clerkDisplayName {
    final name = _state.clerk?.name ?? _state.config.clerkName;
    return name.isEmpty ? '未获取店员信息' : name;
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _afterLogChange() {
    if (!_stickToBottom || !_logScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _toggleListening() async {
    if (_state.listening) {
      _state.stopListening();
    } else {
      final ok = await _state.startListening();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_state.lastError ?? '启动失败')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = _state.theme.palette;
    return AppStateScope(
      state: _state,
      child: AnimatedBuilder(
      animation: _state,
      builder: (context, _) {
        final clerk = _state.clerk;
        final stats = _state.weekStats;
        final renewal = stats?.renewalRate;
        final entries = _state.history();
        final last = entries.isEmpty ? null : entries.last;
        final counts = _state.todayCounts;
        final listenLabel = _state.listening
            ? '监听中'
            : (last == null ? '未开始监听' : '已停止');
        final loginLabel = _state.session == null
            ? '未登录'
            : '店铺 ${_state.session!.sid}';
        return Scaffold(
          appBar: AppBar(title: const Text('监听')),
          body: ListView(
            // The floating pill overlays the body: reserve its height
            // (plus air) at the bottom so the log section clears it.
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + bottomNavClearance(context),
            ),
            children: [
              // Hero: title + today count + listen/login status.
              // A plain card, not a saturated gradient band (design
              // reference: restrained hierarchy, tint-derived surfaces).
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '今日抢单 ${_state.todaySuccessCount}',
                            style: TextStyle(
                              color: palette.textDark,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (renewal != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: renewal >= renewalTarget
                                  ? const Color(0xFF7BD88F)
                                  : const Color(0xFFFFB4A8),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${renewal >= renewalTarget ? '●' : '○'} '
                              '续费率 ${renewal.toStringAsFixed(0)}% / 30%',
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$listenLabel · $loginLabel',
                      style: TextStyle(
                        color: palette.hint,
                        fontSize: 13,
                      ),
                    ),
                    if (stats != null)
                      Text(
                        '本周接单 ${stats.orderCount} · '
                        '续单率 ${stats.orderRate?.toStringAsFixed(0) ?? '—'}%',
                        style: TextStyle(
                          color: palette.hint,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Clerk / account card.
              AppCard(
                child: Row(
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
                        ],
                      ),
                    ),
                    if (clerk != null && clerk.id > 0)
                      Text(
                        'ID：${clerk.id}',
                        style: TextStyle(color: palette.hint, fontSize: 12),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Start / stop — wenxi liquid glass button.
              Row(
                children: [
                  Expanded(
                    child: LiquidGlassButton(
                      onPressed: _toggleListening,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _state.listening
                                ? Icons.stop
                                : Icons.play_arrow,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _state.listening ? '停止监听' : '开始监听',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              CheckRow(
                label: '接到单后自动停止监听',
                value: _state.config.autoStopAfterGrab,
                onChanged: (v) async {
                  if (v == null) return;
                  await _state.updateConfig(
                    _state.config.copyWith(autoStopAfterGrab: v),
                  );
                },
              ),
              SwitchRow(
                label: '在线接单',
                subtitle: _state.online ? '当前在线' : '当前离线',
                value: _state.online,
                onChanged: (v) async {
                  final ok = await _state.setOnline(v);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('在线状态切换失败，已回滚')),
                    );
                  }
                },
              ),
              // Item-type switches (§6.5).
              if (_state.itemSwitchKnown && _state.itemSwitchNames.isNotEmpty)
                AppCard(
                  margin: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '接单类型',
                        style: TextStyle(
                          color: palette.textDark,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final entry in _state.itemSwitchNames.entries)
                        CheckRow(
                          label:
                              '${entry.value}（${entry.key}）',
                          value: _state.itemSwitchIds.contains(entry.key),
                          onChanged: (v) async {
                            if (v == null) return;
                            final ok = await _state.toggleItemSwitch(
                              entry.key,
                              v,
                            );
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('接单类型切换失败，已回滚'),
                                ),
                              );
                            }
                          },
                        ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '接单类型：登录后显示',
                    style: TextStyle(color: palette.hint, fontSize: 12),
                  ),
                ),
              // Week statistics (§10.8).
              const SectionTitle('本周统计'),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_state.weekStatsLoading)
                      const LinearProgressIndicator()
                    else if (stats != null) ...[
                      Text(
                        '本周接单 ${stats.orderCount} · '
                        '续费率 ${stats.renewalRate?.toStringAsFixed(1) ?? '—'}% · '
                        '续单率 ${stats.orderRate?.toStringAsFixed(1) ?? '—'}% · '
                        '续客率 ${stats.userRate?.toStringAsFixed(1) ?? '—'}%',
                        style: TextStyle(color: palette.textDark),
                      ),
                      const SizedBox(height: 6),
                      for (final line in stats.detailLines())
                        Text(
                          line,
                          style: TextStyle(color: palette.hint, fontSize: 12),
                        ),
                    ] else if (_state.weekFallbackTotal != null)
                      Text(
                        '本周统计为空，改用订单总数：${_state.weekFallbackTotal}',
                        style: TextStyle(color: palette.hint),
                      )
                    else
                      Text(
                        '暂无本周统计',
                        style: TextStyle(color: palette.hint),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _state.weekStatsLoading
                          ? null
                          : () => unawaited(_state.refreshWeekStats()),
                      child: const Text('刷新本周统计'),
                    ),
                  ],
                ),
              ),
              // Last order + today counts.
              const SectionTitle('最近一单'),
              AppCard(
                child: last == null
                    ? Text(
                        '暂无记录\n抢到单后会显示在这里',
                        style: TextStyle(color: palette.hint),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${last.grabbedAt}   ¥${last.amount.toStringAsFixed(2)}',
                                  style: TextStyle(color: palette.textDark),
                                ),
                              ),
                              OutcomeChip(last.outcome),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            last.reason.isNotEmpty
                                ? '原因：${last.reason}'
                                : '订单号 ${last.no}',
                            style: TextStyle(color: palette.hint, fontSize: 12),
                          ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '今日成功 ${counts[HistoryOutcome.success] ?? 0} · '
                  '失败 ${counts[HistoryOutcome.failed] ?? 0} · '
                  '跳过 ${counts[HistoryOutcome.skipped] ?? 0} · '
                  '未知 ${counts[HistoryOutcome.unknown] ?? 0}',
                  style: TextStyle(color: palette.hint, fontSize: 12),
                ),
              ),
              // Run log.
              SectionTitle(
                '运行日志',
                trailing: TextButton(
                  onPressed: () => _state.logs.clear(),
                  child: const Text('清空日志'),
                ),
              ),
              _LogView(
                logs: _state.logs,
                scrollController: _logScroll,
                onUserScroll: (atBottom) => _stickToBottom = atBottom,
                onChanged: _afterLogChange,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '日志只保存在内存中，退出 App 即清空。',
                  style: TextStyle(color: palette.hint, fontSize: 12),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    ),
    );
  }
}

class _LogView extends StatelessWidget {
  final LogStore logs;
  final ScrollController scrollController;
  final ValueChanged<bool> onUserScroll;
  final VoidCallback onChanged;

  const _LogView({
    required this.logs,
    required this.scrollController,
    required this.onUserScroll,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: logs,
      builder: (context, _) {
        onChanged();
        final entries = logs.entries;
        final palette = _palette(context);
        return Container(
          height: 260,
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.cardBorder, width: 0.7),
          ),
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    '暂无日志',
                    style: TextStyle(color: palette.hint),
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollUpdateNotification) {
                      final atBottom =
                          n.metrics.pixels >=
                              n.metrics.maxScrollExtent - 20;
                      onUserScroll(atBottom);
                    }
                    return false;
                  },
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final time =
                          '${entry.time.hour.toString().padLeft(2, '0')}:'
                          '${entry.time.minute.toString().padLeft(2, '0')}:'
                          '${entry.time.second.toString().padLeft(2, '0')}';
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        child: SelectableText.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '[$time] ',
                                style: TextStyle(
                                  color: palette.hint,
                                  fontSize: 12,
                                ),
                              ),
                              TextSpan(
                                text: entry.message,
                                style: TextStyle(
                                  color: logColor(palette, entry.levelName),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        );
      },
    );
  }
}

AppPalette _palette(BuildContext context) {
  final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
  return scope!.state.theme.palette;
}
