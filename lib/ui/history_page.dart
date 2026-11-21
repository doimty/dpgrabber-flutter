/// History page (PORTING_CONTRACT §7.5/§10.6).
///
/// 200-entry persisted history, newest first in the view (newest last
/// in the file, §7.1). Three-line rows, outcome chips coloured from
/// the theme (§9 `outcome_*`), "全部账号" filter, clear-history, today
/// counts, and the long-press menu: 拉黑微信号 / 把备注加入排除词或
/// 白名单 / 复制订单号 (§7.5).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../theme/app_theme.dart';
import '../wenxi_ui/liquid_bottom_navigation.dart';
import '../wenxi_ui/liquid_overlays.dart';
import 'app_state.dart';
import 'widgets.dart';

class HistoryPage extends StatefulWidget {
  final AppState state;

  const HistoryPage({super.key, required this.state});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _allAccounts = false;

  AppState get _state => widget.state;

  Future<void> _clearHistory() async {
    final confirmed = await showGlassConfirmation(
      context,
      title: '清空历史',
      message: '将清空全部接单历史记录，此操作不可恢复。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (confirmed && mounted) {
      _state.historyStore.clear();
      _state.logs.add(LogLevel.info, '接单历史已清空');
      setState(() {});
    }
  }

  Future<void> _showEntryMenu(HistoryEntry entry) async {
    final hasWechat = entry.userWechatId.isNotEmpty;
    final hasMemo = entry.userMemo.isNotEmpty;
    final mode = _state.config.memoMode;
    final keywordTarget = mode == 3 ? '白名单' : '排除词';
    final memoPreview = hasMemo && entry.userMemo.length > 18
        ? '${entry.userMemo.substring(0, 18)}…'
        : entry.userMemo;
    final choice = await showGlassSheet<String>(
      context,
      title: '订单操作',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassActionTile(
            icon: Icons.block_rounded,
            label: hasWechat
                ? '拉黑微信号 ${entry.userWechatId}'
                : '该订单没有微信号',
            onTap: hasWechat
                ? () => Navigator.of(context).pop('blacklist')
                : null,
          ),
          GlassActionTile(
            icon: Icons.playlist_add_rounded,
            label: hasMemo
                ? '把备注加入$keywordTarget「$memoPreview」'
                : '该订单没有备注',
            onTap: hasMemo
                ? () => Navigator.of(context).pop('keyword')
                : null,
          ),
          GlassActionTile(
            icon: Icons.copy_rounded,
            label: '复制订单号',
            onTap: () => Navigator.of(context).pop('copy'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'blacklist':
        await _addBlacklist(entry.userWechatId);
      case 'keyword':
        await _addKeyword(entry.userMemo);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: entry.no));
        _state.logs.add(LogLevel.info, '订单号已复制到剪贴板');
        if (mounted) {
          showGlassMessage(
            context,
            '订单号已复制到剪贴板',
            aboveBottomNavigation: true,
          );
        }
    }
  }

  Future<void> _addBlacklist(String wechatId) async {
    final old = _state.config.blacklist;
    final next = List<String>.of(old);
    if (!next.contains(wechatId)) next.add(wechatId);
    if (blacklistWouldOverwrite(old, next)) {
      final confirmed = await showGlassConfirmation(
        context,
        title: '黑名单将被覆盖',
        message: '新黑名单与已有黑名单不同，确定要保存吗？',
        confirmLabel: '保存',
      );
      if (!confirmed || !mounted) return;
    }
    await _state.updateConfig(_state.config.copyWith(blacklist: next));
    if (mounted) {
      showGlassMessage(context, '已拉黑 $wechatId', aboveBottomNavigation: true);
    }
  }

  Future<void> _addKeyword(String memo) async {
    final mode = _state.config.memoMode;
    var nextConfig = _state.config;
    var note = '';
    if (mode == 3) {
      final next = List<String>.of(nextConfig.memoIncludeKeywords);
      if (!next.contains(memo)) next.add(memo);
      nextConfig = nextConfig.copyWith(memoIncludeKeywords: next);
    } else {
      final next = List<String>.of(nextConfig.memoExcludeKeywords);
      if (!next.contains(memo)) next.add(memo);
      nextConfig = nextConfig.copyWith(memoExcludeKeywords: next);
      if (mode < 2) {
        nextConfig = nextConfig.copyWith(memoMode: 2);
        note = '备注检测已切换为「排除关键词」，新加的词才会生效';
      }
    }
    await _state.updateConfig(nextConfig);
    if (mounted) {
      showGlassMessage(
        context,
        note.isEmpty ? '已加入关键词' : note,
        aboveBottomNavigation: true,
      );
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
        final entries =
            _state.history(allAccounts: _allAccounts).reversed.toList();
        final counts = _state.todayCounts;
        return Scaffold(
          appBar: AppBar(
            title: const Text('接单历史'),
            actions: [
              TextButton(
                onPressed: _clearHistory,
                child: Text('清空历史', style: TextStyle(color: palette.accent)),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '今日成功 ${counts[HistoryOutcome.success] ?? 0} · '
                        '失败 ${counts[HistoryOutcome.failed] ?? 0} · '
                        '跳过 ${counts[HistoryOutcome.skipped] ?? 0} · '
                        '未知 ${counts[HistoryOutcome.unknown] ?? 0}',
                        style: TextStyle(color: palette.hint, fontSize: 12),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CupertinoCheckbox(
                          value: _allAccounts,
                          onChanged: (v) => setState(
                            () => _allAccounts = v ?? false,
                          ),
                          activeColor: palette.accent,
                          semanticLabel: '全部账号',
                        ),
                        Text(
                          '全部账号',
                          style: TextStyle(color: palette.textDark, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          '暂无接单记录，抢到单后会自动出现在这里',
                          style: TextStyle(color: palette.hint),
                        ),
                      )
                    : ListView.builder(
                        // The floating pill overlays the body: reserve
                        // its height at the bottom so the last entry
                        // clears it.
                        padding: EdgeInsets.only(
                          left: 16,
                          right: 16,
                          bottom: bottomNavClearance(context),
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return AppCard(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              onLongPress: () => _showEntryMenu(entry),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Wrap(
                                          crossAxisAlignment: WrapCrossAlignment.center,
                                          spacing: 8,
                                          runSpacing: 4,
                                          children: [
                                            Text(
                                              '¥${entry.amount.toStringAsFixed(2)}',
                                              style: TextStyle(
                                                color: palette.textDark,
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            OutcomeChip(entry.outcome),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '订单操作',
                                        icon: const Icon(Icons.more_horiz),
                                        color: palette.hint,
                                        onPressed: () => _showEntryMenu(entry),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '${entry.grabbedAt} · 订单号 ${entry.no}',
                                    style: TextStyle(color: palette.hint, fontSize: 12),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '微信 ${entry.userWechatId.isEmpty ? '未知' : entry.userWechatId}'
                                    '   ·   备注：${entry.userMemo.isEmpty ? '无备注' : entry.userMemo}',
                                    style: TextStyle(
                                      color: palette.hint,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (entry.reason.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        '原因：${entry.reason}',
                                        style: TextStyle(
                                          color: palette.historyReason,
                                          fontSize: 12,
                                        ),
                                      ),
                                    )
                                  else
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        '结果：${outcomeLabel(entry.outcome.name)}',
                                        style: TextStyle(
                                          color: palette.hint,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
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
