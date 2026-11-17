/// Order history store (PORTING_CONTRACT §7, PC `history.py`).
///
/// File `dpgrabber_history.json`, a JSON array, newest last, capped at
/// the newest 200 entries. Atomic write (temp file + rename). A
/// missing/corrupt file loads as `[]`; non-list content loads as `[]`.
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';

const int maxHistoryEntries = 200;

/// Normalize one raw entry: missing outcome -> `success` (old entries
/// were all confirmed grabs); unknown outcome -> `unknown`; missing
/// reason -> ''.
HistoryEntry normalizeEntry(Map<String, dynamic> entry) =>
    HistoryEntry.fromJson(entry);

class HistoryStore {
  final File file;
  HistoryStore(this.file);

  List<HistoryEntry> load() {
    if (!file.existsSync()) return [];
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! List) return [];
      return [
        for (final e in decoded)
          if (e is Map<String, dynamic>) normalizeEntry(e),
      ];
    } catch (_) {
      return [];
    }
  }

  void save(List<HistoryEntry> entries) {
    final dir = file.parent;
    dir.createSync(recursive: true);
    final tmp = File(
        '${dir.path}/.hist-${DateTime.now().microsecondsSinceEpoch}.tmp');
    tmp.writeAsStringSync(
        '${jsonEncode([for (final e in entries) e.toJson()])}\n',
        encoding: utf8);
    tmp.renameSync(file.path);
  }

  /// Append one entry, keep only the newest [maxHistoryEntries].
  List<HistoryEntry> append(HistoryEntry entry) {
    final entries = load()..add(entry);
    final kept = entries.length > maxHistoryEntries
        ? entries.sublist(entries.length - maxHistoryEntries)
        : entries;
    save(kept);
    return kept;
  }

  void clear() => save([]);

  /// Build an entry for an order that left the confirm loop (§7.4).
  static HistoryEntry entryForOrder({
    required Map<String, dynamic> order,
    required HistoryOutcome outcome,
    required String reason,
    required String account,
    required String clerk,
    DateTime? grabbedAt,
  }) {
    final o = Order(order);
    return HistoryEntry(
      grabbedAt: formatLocalIso(grabbedAt ?? DateTime.now()),
      no: o.no,
      id: o.id,
      amount: double.parse(o.amountYuan.toStringAsFixed(2)),
      userWechatId: o.userWechatId,
      userMemo: o.userMemo,
      createTime: order['createTime']?.toString() ?? '',
      outcome: outcome,
      reason: reason,
      account: account,
      clerk: clerk,
    );
  }

  /// Entries for one account. Old entries with an empty `account` are
  /// shown in the current account's view (§7.4); with [allAccounts]
  /// everything is returned.
  List<HistoryEntry> entriesForAccount(String account,
      {bool allAccounts = false}) {
    final entries = load();
    if (allAccounts) return entries;
    return [
      for (final e in entries)
        if (e.account.isEmpty || e.account == account) e,
    ];
  }

  /// Today's successful grabs, counted from persisted history (§7.4) —
  /// never from an in-memory counter, so restarts do not reset it.
  int todaySuccessCount({DateTime? now}) {
    final today = now ?? DateTime.now();
    final prefix =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    return load()
        .where((e) =>
            e.outcome == HistoryOutcome.success &&
            e.grabbedAt.startsWith(prefix))
        .length;
  }

  /// Today's counts per outcome (PC "今日成功/失败/跳过/未知").
  Map<HistoryOutcome, int> todayCounts({DateTime? now}) {
    final today = now ?? DateTime.now();
    final prefix =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final counts = <HistoryOutcome, int>{
      for (final o in HistoryOutcome.values) o: 0,
    };
    for (final e in load()) {
      if (e.grabbedAt.startsWith(prefix)) {
        counts[e.outcome] = (counts[e.outcome] ?? 0) + 1;
      }
    }
    return counts;
  }
}
