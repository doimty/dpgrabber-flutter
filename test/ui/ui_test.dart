/// UI tests: theme palettes, log store, login validation, navigation,
/// settings presence. Core tests live in test/core/ and are untouched.
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
import 'package:dpgrabber/ui/login_page.dart';
import 'package:dpgrabber/ui/navigation.dart';
import 'package:dpgrabber/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('login page', () {
    testWidgets('empty phone/password shows validation', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, LoginPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('手机号'), findsWidgets);
      expect(find.text('登录验证'), findsOneWidget);
      await tester.tap(find.text('登录验证'));
      await tester.pump();
      expect(find.text('请输入手机号'), findsOneWidget);
    });

    testWidgets('short phone shows 11-digit validation', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, LoginPage(state: state)));
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

    testWidgets('unencrypted-storage warning is shown', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, LoginPage(state: state)));
      await tester.pumpAndSettle();
      expect(
        find.text(FileCredentialStore.unencryptedWarning),
        findsOneWidget,
      );
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
      expect(find.text('主题'), findsWidgets);
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
    testWidgets('theme switch applies immediately', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('绯樱春信（定稿）'), findsOneWidget);
      await tester.tap(find.text('绯樱春信（定稿）'));
      await tester.pumpAndSettle();
      expect(state.theme.value, 'sakura');
      expect(state.config.theme, 'sakura');
    });

    testWidgets('invalid number is rejected on save', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      // Enlarge the viewport so the lazily-built order-condition card
      // (below the theme and background sections) is built and visible.
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

  testWidgets('DpgApp boots to the login page when logged out',
      (tester) async {
    final state = await _testStateWith(tester);
    addTearDown(state.dispose);
    await tester.pumpWidget(DpgApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('登录验证'), findsOneWidget);
  });
}
