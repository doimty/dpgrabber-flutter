/// Screenshot record for the add-account entry (§10.2): the logged-in
/// account card with the "+ 添加账号" row, and the same card with the
/// inline add form expanded, at phone size, under
/// ~/workspace/dpgrabber-flutter-fixes/add-account/after/.
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
    '/home/hatch/workspace/dpgrabber-flutter-fixes/add-account/after';

Future<AppState> _testState() async {
  final dir = await Directory.systemTemp.createTemp('dpgrabber_shot4_');
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

Future<AppState> _loggedInState(WidgetTester tester) async {
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
  ];
  return state;
}

void main() {
  testWidgets('account card with the add-account row', (tester) async {
    await _phoneViewport(tester);
    final state = await _loggedInState(tester);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: RepaintBoundary(key: key, child: SettingsPage(state: state)),
    ));
    await tester.pumpAndSettle();
    // The row sits just below the fold at 390x844: scroll it into
    // view first (the tap in the first version of this test missed
    // for exactly this reason — the row was off-screen).
    await tester.ensureVisible(find.text('添加账号'));
    await tester.pumpAndSettle();
    await _capture(tester, key, 'account-card-add-row.png');
    expect(find.text('添加账号'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('清除已保存账号'), findsOneWidget);
  }, skip: true);

  testWidgets('account card with the add form expanded', (tester) async {
    await _phoneViewport(tester);
    final state = await _loggedInState(tester);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: RepaintBoundary(key: key, child: SettingsPage(state: state)),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    // Scroll the expanded form into view before capturing.
    await tester.ensureVisible(find.text('登录验证'));
    await tester.pumpAndSettle();
    await _capture(tester, key, 'account-card-add-form.png');
    expect(find.text('添加账号'), findsOneWidget);
    expect(
      find.text('添加一个新账号，登录成功后会保存并切换过去'),
      findsOneWidget,
    );
    expect(find.text('登录验证'), findsOneWidget);
  }, skip: true);
}
