import 'dart:io';

import 'package:dpgrabber/core.dart';
import 'package:dpgrabber/ui/advanced_settings_page.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:dpgrabber/ui/history_page.dart';
import 'package:dpgrabber/ui/settings_page.dart';
import 'package:dpgrabber/wenxi_ui/app_theme.dart';
import 'package:dpgrabber/wenxi_ui/appearance.dart';
import 'package:dpgrabber/wenxi_ui/liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/test_helpers.dart';

Future<AppState> mountPage(
  WidgetTester tester,
  Widget Function(AppState) page, {
  bool lowPower = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  tester.view.padding = const FakeViewPadding(top: 28, bottom: 20);
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);
  final state = (await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp('dpg_overlays_');
    addTearDown(() => directory.delete(recursive: true));
    final state = AppState(appDir: directory);
    await state.init();
    return state;
  }))!;
  addTearDown(state.dispose);
  state.theme.set('night');
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(
        Brightness.dark,
        palette: wenxiPaletteFor(state.theme.palette),
        glassLowPower: lowPower,
      ),
      home: page(state),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Finder glassSheet() => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.byType(LiquidGlassSurface),
);

Finder glassDialog() => find.descendant(
  of: find.byType(Dialog),
  matching: find.byType(LiquidGlassSurface),
);

Future<void> openSelector(WidgetTester tester, String label) async {
  final trigger = find.text(label);
  await tester.scrollUntilVisible(
    trigger.hitTestable(),
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(trigger.hitTestable());
  await tester.pumpAndSettle();
  expect(glassSheet(), findsOneWidget);
  expect(find.byIcon(Icons.check_rounded), findsOneWidget);
}

void main() {
  testWidgets('memo selector cancels without writing and persists a choice', (
    tester,
  ) async {
    final state = await mountPage(
      tester,
      (state) => SettingsPage(state: state),
      lowPower: true,
    );
    final before = state.config.memoMode;

    await openSelector(tester, '备注检测');
    expect(
      find.descendant(of: glassSheet(), matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(state.config.memoMode, before);

    await openSelector(tester, '备注检测');
    await tester.tap(find.text('排除关键词'));
    await tester.pumpAndSettle();
    expect(state.config.memoMode, 2);
    expect(find.text('排除关键词'), findsOneWidget);
    expect((await state.store.loadConfig()).memoMode, 2);
  });

  testWidgets('push provider uses the same picker and saves the new provider', (
    tester,
  ) async {
    final state = await mountPage(
      tester,
      (state) => AdvancedSettingsPage(state: state),
    );
    await openSelector(tester, '推送渠道');
    await tester.tap(find.text('PushPlus'));
    await tester.pumpAndSettle();
    expect(glassSheet(), findsNothing);
    expect(state.config.notifyProvider, 'pushplus');
    expect((await state.store.loadConfig()).notifyProvider, 'pushplus');
  });

  testWidgets(
    'history remains until the destructive glass dialog is confirmed',
    (tester) async {
      final state = await mountPage(
        tester,
        (state) => HistoryPage(state: state),
      );
      final entry = HistoryStore.entryForOrder(
        order: fakeOrder(),
        outcome: HistoryOutcome.success,
        reason: '',
        account: state.currentPhone,
        clerk: '测试',
      );
      await tester.runAsync(() async => state.historyStore.append(entry));

      Future<void> open() async {
        await tester.tap(find.text('清空历史'));
        await tester.pumpAndSettle();
        expect(glassDialog(), findsOneWidget);
      }

      await open();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.history(), hasLength(1));

      await open();
      await tester.tapAt(const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(state.history(), hasLength(1));

      await open();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(glassDialog(), findsNothing);
      expect(state.history(), isEmpty);
    },
  );
}
