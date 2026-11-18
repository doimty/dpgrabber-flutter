/// UI tests: theme palettes, log store, settings account login
/// validation, navigation, settings presence. Core tests live in
/// test/core/ and are untouched.
library;

import 'dart:io';

import 'package:dpgrabber/core.dart';
import 'package:dpgrabber/main.dart';
import 'package:dpgrabber/theme/app_theme.dart';
import 'package:dpgrabber/theme/glass.dart';
import 'package:dpgrabber/theme/palette.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:dpgrabber/ui/history_page.dart';
import 'package:dpgrabber/ui/listen_page.dart';
import 'package:dpgrabber/ui/log_store.dart';
import 'package:dpgrabber/ui/navigation.dart';
import 'package:dpgrabber/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/test_helpers.dart';

Future<AppState> _testState() async {
  final dir = await Directory.systemTemp.createTemp('dpgrabber_ui_test_');
  final state = AppState(appDir: dir);
  await state.init();
  return state;
}

/// Real-async setup must run outside the testWidgets fake-async zone
/// (plain `await _testState()` deadlocks there); `runAsync` returns a
/// nullable future, so unwrap it here.
Future<AppState> _testStateWith(WidgetTester tester) async =>
    (await tester.runAsync(_testState))!;

Widget _wrap(AppState state, Widget child) => MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: child,
    );

void main() {
  group('palettes (§9)', () {
    test('all six themes define all 36 keys', () {
      for (final p in allPalettes) {
        for (final key in paletteKeys) {
          expect(p[key], isNotNull, reason: '${p.id} missing $key');
        }
      }
      expect(allPalettes.map((p) => p.id).toList(), [
        'day',
        'night',
        'blue',
        'sakura',
        'mint',
        'violet',
      ]);
    });

    test('verbatim spot values from the contract', () {
      expect(paletteFor('sakura').accent, const Color(0xFFE85D8A));
      expect(paletteFor('sakura').windowBg, const Color(0xFFFFF5F7));
      expect(paletteFor('sakura').heroTop, const Color(0xFFFF8FAB));
      expect(paletteFor('day').accent, const Color(0xFF585349));
      expect(paletteFor('day').logError, const Color(0xFFC0392B));
      expect(paletteFor('night').accent, const Color(0xFF5AA9E6));
      expect(paletteFor('blue').outcomeColor('failed'),
          const Color(0xFFCF222E));
      expect(paletteFor('mint').accent, const Color(0xFF1E9E6A));
      expect(paletteFor('violet').accent, const Color(0xFF7C4DBE));
    });

    test('unknown theme id falls back to day', () {
      expect(paletteFor('nope').id, 'day');
      expect(paletteFor('').id, 'day');
      expect(themeDisplayName('sakura'), '绯樱春信');
    });

    test('derived palette from 4 seeds has all 36 keys', () {
      final derived = derivePaletteFromSeeds(
        id: 'custom',
        name: '自定义',
        seeds: const ThemeSeeds(
          lightAccent: Color(0xFF42A5F5),
          darkAccent: Color(0xFF0D47A1),
          companion: Color(0xFFBBD6F2),
          textSeed: Color(0xFF0D2B45),
        ),
      );
      for (final key in paletteKeys) {
        expect(derived[key], isNotNull, reason: 'custom missing $key');
      }
    });

    test('ThemeController normalises unknown ids and builds ThemeData',
        () {
      final controller = ThemeController('nope');
      expect(controller.value, 'day');
      controller.set('sakura');
      expect(controller.value, 'sakura');
      final data = buildThemeData(controller.palette);
      expect(data.colorScheme.primary, const Color(0xFFE85D8A));
      expect(data.scaffoldBackgroundColor, const Color(0xFFFFF5F7));
    });

    test('glass levels match the design reference', () {
      expect(GlassLevel.clear.opacity, 0.40);
      expect(GlassLevel.clear.blur, 8);
      expect(GlassLevel.frosted.opacity, 0.93);
      expect(GlassLevel.frosted.blur, 18);
      expect(GlassLevel.solid.opacity, 1.0);
      expect(GlassLevel.solid.blur, 0);
      final glass = GlassSettings(lowPower: true);
      expect(glass.effectiveBlur, 0);
    });
  });

  group('LogStore (§12 Q-14)', () {
    test('caps at 500 entries, oldest dropped first', () {
      final logs = LogStore();
      for (var i = 0; i < 600; i++) {
        logs.add(LogLevel.info, 'line $i');
      }
      expect(logs.length, maxLogEntries);
      expect(logs.entries.first.message, 'line 100');
      expect(logs.entries.last.message, 'line 599');
    });

    test('clear empties the store', () {
      final logs = LogStore();
      logs.add(LogLevel.error, 'boom');
      logs.clear();
      expect(logs.length, 0);
    });
  });

  group('settings account section (§10.2)', () {
    testWidgets('empty phone/password shows validation', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('登录验证'), findsOneWidget);
      await tester.tap(find.text('登录验证'));
      await tester.pump();
      expect(find.text('请输入手机号'), findsOneWidget);
    });

    testWidgets('short phone shows 11-digit validation', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '11 位手机号').first,
        '1380000000',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '账号密码').first,
        'x',
      );
      await tester.tap(find.text('登录验证'));
      await tester.pump();
      expect(find.text('手机号应为 11 位数字'), findsOneWidget);
    });

    testWidgets('logged-in account display has no sign-out button',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      state.loggedIn = true;
      state.loginPhone = '13800000000';
      state.clerk = const Clerk(id: 230313, name: '加冰', status: 1);
      state.session = const Session(token: 'fake', sid: '92');
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('加冰'), findsOneWidget);
      expect(find.text('138****0000'), findsOneWidget);
      expect(find.text('店铺 92'), findsOneWidget);
      expect(find.text('ID：230313'), findsOneWidget);
      expect(find.text('登录验证'), findsNothing);
      // No way back to "logged out with a saved account": the
      // account stays signed in until its credentials are cleared.
      expect(find.text('退出登录'), findsNothing);
    });
  });

  group('cold-start auto-login (§10.2, login-bug2 video sequence)', () {
    /// A state with a saved account + a stubbed login flow, as the
    /// video showed it: phone 138****0000, clerk 加冰 / ID 230313,
    /// shop 92, week stats 3 orders at a 25.0% renewal rate.
    Future<AppState> savedAccountState() async {
      final dir =
          await Directory.systemTemp.createTemp('dpgrabber_login_bug2_');
      final transport = FakeTransport();
      transport.onJson('/s/duopei-account/login', {
        'code': 0,
        'data': {'token': 'base-tok', 'shopId': 92},
      });
      transport.onJson('/s/duopei-account/list-shop-account', {
        'code': 0,
        'data': [
          {'shopId': 92, 'accountId': 'a92'},
        ],
      });
      transport.onJson('/s/duopei-account/switch-account',
          {'code': 0, 'data': {'token': 'tok-92'}});
      transport.onJson('/s/balance/getBalance', {'code': 0});
      transport.onJson('/s/c/clerk/get', {
        'code': 0,
        'clerk': {'id': 230313, 'name': '加冰', 'status': 1},
      });
      transport.onJson('/s/c/clerk/getItemSwitchList',
          {'code': 0, 'itemSwitchList': [], 'clerkItemSwitchIds': []});
      transport.onJson('/s/c/statistics/statisticsClerkOrder', {
        'code': 0,
        'list': {
          'orderCount': 3,
          'continuedCount': 1,
          'continuedUserCount': 1,
          'totalOrderCount': 3,
          'continuedAmount': 10000,
          'orderAmount': 40000,
          'firstCount': 0,
          'refundedCount': 0,
        },
      });
      await FileCredentialStore(dir)
          .saveAccount(phone: '13800000000', password: 'fake-pw');
      final state = AppState(appDir: dir, transport: transport);
      await state.init();
      // init() kicks the restore off in the background: wait for it
      // to land instead of calling ensureSession() ourselves, so
      // this covers the real cold-start path. The clerk fetch runs
      // right after the session, so wait for both.
      for (var i = 0;
          i < 100 && (state.session == null || state.clerk == null);
          i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return state;
    }

    testWidgets('saved account -> live session after init, hero shows '
        'the shop, stats succeed', (tester) async {
      final state =
          (await tester.runAsync(savedAccountState))!;
      addTearDown(state.dispose);
      expect(state.loggedIn, isTrue);
      expect(state.session, isNotNull);
      expect(state.session!.sid, '92');
      expect(state.clerk?.name, '加冰');
      expect(state.online, isTrue);

      await tester.pumpWidget(_wrap(state, ListenPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.textContaining('店铺 92'), findsOneWidget);
      expect(find.text('未登录'), findsNothing);

      // Week stats after the cold start: the call carries the
      // restored session, so no 401.
      await tester.runAsync(state.refreshWeekStats);
      expect(state.weekStats, isNotNull);
      expect(state.weekStats!.orderCount, 3);
      expect(state.weekStats!.renewalRate, 25.0);
      expect(
        state.logs.entries
            .any((e) => e.message.contains('本周统计拉取失败')),
        isFalse,
      );
    });

    testWidgets('stats called right after cold start never 401',
        (tester) async {
      // Same cold start as above, but do NOT wait for the background
      // restore: call refreshWeekStats immediately, while the restore
      // may still be in flight. The stats call must end with data,
      // not a 401 — whichever side builds the session first.
      final state = (await tester.runAsync(() async {
        final dir =
            await Directory.systemTemp.createTemp('dpgrabber_login_bug2b_');
        final transport = FakeTransport();
        transport.onJson('/s/duopei-account/login', {
          'code': 0,
          'data': {'token': 'base-tok', 'shopId': 92},
        });
        transport.onJson('/s/duopei-account/list-shop-account', {
          'code': 0,
          'data': [
            {'shopId': 92, 'accountId': 'a92'},
          ],
        });
        transport.onJson('/s/duopei-account/switch-account',
            {'code': 0, 'data': {'token': 'tok-92'}});
        transport.onJson('/s/balance/getBalance', {'code': 0});
        transport.onJson('/s/c/clerk/get', {
          'code': 0,
          'clerk': {'id': 230313, 'name': '加冰', 'status': 1},
        });
        transport.onJson('/s/c/clerk/getItemSwitchList',
            {'code': 0, 'itemSwitchList': [], 'clerkItemSwitchIds': []});
        transport.onJson('/s/c/statistics/statisticsClerkOrder', {
          'code': 0,
          'list': {
            'orderCount': 3,
            'continuedCount': 1,
            'continuedUserCount': 1,
            'totalOrderCount': 3,
            'continuedAmount': 10000,
            'orderAmount': 40000,
            'firstCount': 0,
            'refundedCount': 0,
          },
        });
        await FileCredentialStore(dir)
            .saveAccount(phone: '13800000000', password: 'fake-pw');
        final s = AppState(appDir: dir, transport: transport);
        await s.init();
        return s;
      }))!;
      addTearDown(state.dispose);
      await tester.runAsync(state.refreshWeekStats);
      expect(state.weekStats, isNotNull);
      expect(state.weekStats!.orderCount, 3);
      expect(
        state.logs.entries
            .any((e) => e.message.contains('本周统计拉取失败')),
        isFalse,
      );
    });

    testWidgets('ensureSession fails cleanly with no saved credentials',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      expect(state.session, isNull);
      expect(await tester.runAsync(state.ensureSession), isFalse);
      expect(state.session, isNull);
      expect(state.loggedIn, isFalse);
    });
  });

  group('navigation shell', () {
    testWidgets('switches between listen, history and settings',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildThemeData(state.theme.palette),
          home: AppShell(state: state),
        ),
      );
      await tester.pumpAndSettle();
      // Dashboard (listen) is the entry page.
      expect(find.text('开始监听'), findsOneWidget);
      // The shell now has more than one Scrollable (the desktop rail
      // scrolls too), so name the listen page's ListView explicitly:
      // the Scrollable enclosing the 开始监听 button.
      await tester.scrollUntilVisible(
        find.text('运行日志'),
        200,
        scrollable: find.ancestor(
          of: find.text('开始监听'),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('运行日志'), findsOneWidget);
      // Bottom bar on narrow test viewport.
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(find.text('接单历史'), findsWidgets);
      expect(find.text('清空历史'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('接单条件'), findsWidgets);
      expect(find.text('保存设置'), findsWidgets);
    });
  });

  group('listen page', () {
    testWidgets('shows log view and today counts', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      state.logs.add(LogLevel.info, 'hello log');
      await tester.pumpWidget(_wrap(state, ListenPage(state: state)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('hello log'),
        200,
      );
      expect(find.textContaining('hello log'), findsOneWidget);
      expect(find.text('运行日志'), findsOneWidget);
      expect(find.text('清空日志'), findsOneWidget);
      expect(find.textContaining('今日成功'), findsOneWidget);
    });
  });

  group('settings page', () {
    testWidgets('theme/glass/background customization is gone',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      // The three removed sections must not appear anywhere. They sat
      // at the top of the page, so they would be built on first pump
      // if they still existed.
      expect(find.text('主题'), findsNothing);
      expect(find.text('玻璃效果'), findsNothing);
      expect(find.text('背景'), findsNothing);
      expect(find.text('选择图片'), findsNothing);
      expect(find.text('玻璃档位'), findsNothing);
      expect(find.text('低功耗模式'), findsNothing);
      // The remaining sections are intact, in order. The ListView
      // builds lazily, so scroll each title into view before asserting.
      // (scrollUntilVisible can't be used here: its default Scrollable
      // finder matches the page's multiline TextFields too, and a
      // ListView is not itself a Scrollable.)
      Future<void> scrollTo(Finder target) async {
        for (var i = 0; i < 30; i++) {
          if (target.evaluate().isNotEmpty) {
            await tester.ensureVisible(target.first);
            await tester.pumpAndSettle();
            return;
          }
          await tester.drag(find.byType(ListView), const Offset(0, -400));
          await tester.pumpAndSettle();
        }
        fail('never scrolled to $target');
      }

      for (final title in [
        '账号',
        '接单条件',
        '确认等待',
        '刷新与休息',
        '高级设置',
        '接单类型匹配词',
        '抢单推送',
        'AES 密钥（十六进制）',
      ]) {
        await scrollTo(find.text(title));
        expect(find.text(title), findsOneWidget);
      }
      await scrollTo(find.text('保存设置'));
      expect(find.text('保存设置'), findsWidgets);
      expect(find.text('保存设置'), findsWidgets);
      // Stored values are untouched: the fixed theme/glass/background
      // still come from the saved config, not from any UI.
      expect(state.config.theme, 'day');
      expect(state.glass.level, GlassLevel.clear);
      expect(state.background.settings.cardOpacity, 0.86);
      expect(state.background.settings.blur, 6.0);
      expect(state.background.settings.brightness, 0.90);
    });

    testWidgets('invalid number is rejected on save', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      // Enlarge the viewport so the lazily-built order-condition card
      // (below the top of the page) is built and visible.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, '不低于此价才抢');
      await tester.enterText(field, 'abc');
      await tester.tap(find.text('保存设置').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('设置有误'), findsOneWidget);
      // Config unchanged after a rejected save.
      expect(state.config.minAmount, 10.0);
    });
  });

  group('history page', () {
    testWidgets('empty state copy is shown', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, HistoryPage(state: state)));
      await tester.pumpAndSettle();
      expect(
        find.text('暂无接单记录，抢到单后会自动出现在这里'),
        findsOneWidget,
      );
    });
  });

  testWidgets('DpgApp boots to the shell when logged out',
      (tester) async {
    final state = await _testStateWith(tester);
    addTearDown(state.dispose);
    await tester.pumpWidget(DpgApp(state: state));
    await tester.pumpAndSettle();
    // The listen page is the entry tab — no blocking login screen.
    expect(find.text('开始监听'), findsOneWidget);
    expect(find.text('登录验证'), findsNothing);
  });
}
