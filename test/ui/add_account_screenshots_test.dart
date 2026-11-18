/// Screenshot record for the account sheet (§10.2): the logged-in
/// account card's modal bottom sheet in its list state (two saved
/// accounts, checkmark on the current one, add row, clear action)
/// and in its add-form state, at phone size, under
/// ~/workspace/dpgrabber-flutter-fixes/account-card-elegant/after/.
///
/// SKIPPED on this VM on purpose — same reason as
/// login_bug2_screenshots_test.dart and
/// settings_redesign_screenshots_test.dart: `Image.toByteData`
/// wedges this VM's software rasterizer (the test body finishes but
/// the isolate never exits). `pumpAndSettle` and `toImage` alone are
/// fine. Re-enable on a machine with a real GPU/rasterizer to
/// re-capture. The assertions are covered by the non-skipped tests
/// in test/ui/ui_test.dart ('add account (§10.2)'), so skipping
/// loses no coverage — only the PNG record.
///
/// The RepaintBoundary wraps the whole MaterialApp (not just the
/// page): the sheet renders in the overlay above the page, so a
/// boundary around the page alone would miss it.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dpgrabber/core.dart';
import 'package:dpgrabber/theme/app_theme.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:dpgrabber/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _outDir =
    '/home/hatch/workspace/dpgrabber-flutter-fixes/account-card-elegant/after';

Future<AppState> _testState() async {
  final dir = await Directory.systemTemp.createTemp('dpgrabber_shot5_');
  final state = AppState(appDir: dir);
  await state.init();
  return state;
}

Future<void> _capture(
    WidgetTester tester, GlobalKey key, String name) async {
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await tester.runAsync(() async {
    final file = File('$_outDir/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _phoneViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Logged-in state with two saved accounts (hand-built metadata,
/// like the ui_test fake state): current 138****0000 / 加冰, plus
/// 139****0001 / 小红.
Future<AppState> _loggedInTwoAccounts(WidgetTester tester) async {
  final state = (await tester.runAsync(_testState))!;
  addTearDown(state.dispose);
  state.loggedIn = true;
  state.loginPhone = '13800000000';
  state.clerk = const Clerk(id: 230313, name: '加冰', status: 1);
  state.session = const Session(token: 'fake', sid: '92');
  await tester.runAsync(
    () => state.updateConfig(
      state.config.copyWith(clerkId: 230313, clerkName: '加冰', shopId: 92),
    ),
  );
  state.savedAccounts = [
    {'phone': '13800000000', 'clerk_name': '加冰', 'shop': '92'},
    {'phone': '13900000001', 'clerk_name': '小红', 'shop': '92'},
  ];
  return state;
}

void main() {
  testWidgets('account sheet with the saved-accounts list',
      (tester) async {
    await _phoneViewport(tester);
    final state = await _loggedInTwoAccounts(tester);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildThemeData(state.theme.palette),
        home: SettingsPage(state: state),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加冰'));
    await tester.pumpAndSettle();
    await _capture(tester, key, 'account-sheet-list.png');
    expect(find.text('切换账号'), findsOneWidget);
    expect(find.text('加冰 · 138****0000 · 店 92'), findsOneWidget);
    expect(find.text('小红 · 139****0001 · 店 92'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('添加账号'), findsOneWidget);
    expect(find.text('清除已保存账号'), findsOneWidget);
  }, skip: true);

  testWidgets('account sheet with the add form', (tester) async {
    await _phoneViewport(tester);
    final state = await _loggedInTwoAccounts(tester);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildThemeData(state.theme.palette),
        home: SettingsPage(state: state),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加冰'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    await _capture(tester, key, 'account-sheet-add-form.png');
    expect(
      find.text('添加一个新账号，登录成功后会保存并切换过去'),
      findsOneWidget,
    );
    expect(find.text('登录验证'), findsOneWidget);
  }, skip: true);
}
