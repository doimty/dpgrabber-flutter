/// History page (PORTING_CONTRACT §7.5/§10.6).
///
/// 200-entry persisted history, newest first in the view (newest last
/// in the file, §7.1). Three-line rows, outcome chips coloured from
/// the theme (§9 `outcome_*`), "全部账号" filter, clear-history, today
/// counts, and the long-press menu: 拉黑微信号 / 把备注加入排除词或
/// 白名单 / 复制订单号 (§7.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../theme/app_theme.dart';
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final palette = _state.theme.palette;
        return AlertDialog(
          title: const Text('清空历史'),
          content: const Text('将清空全部接单历史记录，此操作不可恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('取消', style: TextStyle(color: palette.accent)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('清空', style: TextStyle(color: palette.logError)),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      _state.historyStore.clear();
      _state.logs.add(LogLevel.info, '接单历史已清空');
      setState(() {});
    }
  }

  Future<void> _showEntryMenu(HistoryEntry entry) async {
    final palette = _state.theme.palette;
    final hasWechat = entry.userWechatId.isNotEmpty;
    final hasMemo = entry.userMemo.isNotEmpty;
    final mode = _state.config.memoMode;
    final keywordTarget = mode == 3 ? '白名单' : '排除词';
    final memoPreview = hasMemo && entry.userMemo.length > 18
        ? '${entry.userMemo.substring(0, 18)}…'
        : entry.userMemo;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: palette.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              enabled: hasWechat,
              title: Text(
                hasWechat
                    ? '拉黑微信号 ${entry.userWechatId}'
                    : '该订单没有微信号',
              ),
              onTap: () => Navigator.of(context).pop('blacklist'),
            ),
            ListTile(
              enabled: hasMemo,
              title: Text(
                hasMemo
                    ? '把备注加入$keywordTarget「$memoPreview」'
                    : '该订单没有备注',
              ),
              onTap: () => Navigator.of(context).pop('keyword'),
            ),
            ListTile(
              title: const Text('复制订单号'),
              onTap: () => Navigator.of(context).pop('copy'),
            ),
          ],
        ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('订单号已复制到剪贴板')),
          );
        }
    }
  }

  Future<void> _addBlacklist(String wechatId) async {
    final old = _state.config.blacklist;
    final next = List<String>.of(old);
    if (!next.contains(wechatId)) next.add(wechatId);
    if (blacklistWouldOverwrite(old, next)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          final palette = _state.theme.palette;
          return AlertDialog(
            title: const Text('黑名单将被覆盖'),
            content: const Text('新黑名单与已有黑名单不同，确定要保存吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('取消', style: TextStyle(color: palette.accent)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('保存', style: TextStyle(color: palette.accent)),
              ),
            ],
          );
        },
      );
      if (confirmed != true) return;
    }
    await _state.updateConfig(_state.config.copyWith(blacklist: next));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已拉黑 $wechatId')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(note.isEmpty ? '已加入关键词' : note)),
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
                        Checkbox(
                          value: _allAccounts,
                          onChanged: (v) => setState(
                            () => _allAccounts = v ?? false,
                          ),
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
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                                        child: Text(
                                          '${entry.grabbedAt}   '
                                          '¥${entry.amount.toStringAsFixed(2)}   '
                                          '订单号 ${entry.no}',
                                          style: TextStyle(
                                            color: palette.textDark,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      OutcomeChip(entry.outcome),
                                    ],
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
