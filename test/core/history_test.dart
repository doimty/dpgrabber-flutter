import 'dart:io';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('HistoryStore', () {
    late Directory tmp;
    late HistoryStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dpgrabber_hist_test_');
      store = HistoryStore(File('${tmp.path}/dpgrabber_history.json'));
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    HistoryEntry entry({
      String no = '26111401581302023638',
      String id = '15650502',
      HistoryOutcome outcome = HistoryOutcome.success,
      String grabbedAt = '2026-11-14T01:58:33',
      String account = '13800000000',
    }) =>
        HistoryEntry(
          grabbedAt: grabbedAt,
          no: no,
          id: id,
          amount: 30.0,
          userWechatId: 'A_sweet_moon',
          userMemo: '',
          createTime: '1700000000000',
          outcome: outcome,
          reason: '',
          account: account,
          clerk: 'TestClerk',
        );

    test('missing file loads as empty; append roundtrips', () {
      expect(store.load(), isEmpty);
      store.append(entry());
      final loaded = store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.no, '26111401581302023638');
      expect(loaded.single.outcome, HistoryOutcome.success);
      expect(loaded.single.account, '13800000000');
    });

    test('corrupt file and non-list content load as empty', () {
      final file = File('${tmp.path}/dpgrabber_history.json');
      file.writeAsStringSync('{ broken');
      expect(store.load(), isEmpty);
      file.writeAsStringSync('{"not": "a list"}');
      expect(store.load(), isEmpty);
      file.writeAsStringSync('[{"no":"1","id":"2","amount":1}, "junk"]');
      expect(store.load(), hasLength(1));
    });

    test('keeps only the newest 200 entries', () {
      for (var i = 0; i < 210; i++) {
        store.append(entry(no: 'no-$i', id: '$i'));
      }
      final loaded = store.load();
      expect(loaded, hasLength(200));
      expect(loaded.first.no, 'no-10');
      expect(loaded.last.no, 'no-209');
    });

    test('clear writes an empty list', () {
      store.append(entry());
      store.clear();
      expect(store.load(), isEmpty);
    });

    test('entryForOrder builds the §7.4 shape', () {
      final e = HistoryStore.entryForOrder(
        order: fakeOrder(),
        outcome: HistoryOutcome.success,
        reason: '',
        account: '13800000000',
        clerk: 'TestClerk',
        grabbedAt: DateTime(2026, 11, 14, 1, 58, 33),
      );
      expect(e.grabbedAt, '2026-11-14T01:58:33');
      expect(e.no, '26111401581302023638');
      expect(e.id, '15650502');
      expect(e.amount, 30.0);
      expect(e.userWechatId, 'A_sweet_moon');
    });

    test('todaySuccessCount counts persisted successes for today only',
        () {
      final today = DateTime.now();
      final prefix =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      store.append(entry(grabbedAt: '$prefix' 'T10:00:00'));
      store.append(entry(
          no: '2',
          id: '2',
          grabbedAt: '$prefix' 'T11:00:00',
          outcome: HistoryOutcome.failed));
      store.append(entry(no: '3', id: '3', grabbedAt: '2026-01-01T10:00:00'));
      expect(store.todaySuccessCount(now: today), 1);
      final counts = store.todayCounts(now: today);
      expect(counts[HistoryOutcome.success], 1);
      expect(counts[HistoryOutcome.failed], 1);
      expect(counts[HistoryOutcome.skipped], 0);
    });

    test('entriesForAccount hides other accounts but keeps legacy rows',
        () {
      store.append(entry(account: '13800000000'));
      store.append(entry(no: '2', id: '2', account: '13900000000'));
      store.append(entry(no: '3', id: '3', account: ''));
      final mine = store.entriesForAccount('13800000000');
      expect(mine.map((e) => e.no),
          containsAll(['26111401581302023638', '3']));
      expect(mine.map((e) => e.no), isNot(contains('2')));
      expect(store.entriesForAccount('13800000000', allAccounts: true),
          hasLength(3));
    });
  });
}
