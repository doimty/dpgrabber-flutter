/// Screenshot record for the login-bug2 fix: render the post-fix
/// Settings account section (logged-in card without a sign-out
/// button; logged-out form without the unencrypted banner) to PNGs
/// under ~/workspace/dpgrabber-flutter-fixes/login-bug2/after/.
///
/// SKIPPED on this VM on purpose — read before un-skipping: the
/// capture itself works (the PNGs in after/ were produced by this
/// very test), but `Image.toByteData` — any format, even rawRgba,
/// with or without `image.dispose()` — wedges this VM's software
/// rasterizer: the test body finishes in ~1s and the isolate then
/// never exits, so the test times out (10 min in the full suite).
/// `pumpAndSettle` and `toImage` alone are fine (probed 2026-11-18);
/// only the pixel readback wedges it. Re-enable on a machine with a
/// real GPU/rasterizer to re-capture; the PNGs already in after/ are
/// current for the code as of this fix and were eyeballed.
///
/// The assertions are covered by the non-skipped tests in
/// test/ui/ui_test.dart ('logged-in account display has no sign-out
/// button' + the cold-start auto-login group), so skipping this file
/// loses no coverage — only the PNG record, which already exists.
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
    '/home/hatch/workspace/dpgrabber-flutter-fixes/login-bug2/after';

Future<AppState> _testState() async {
  final dir = await Directory.systemTemp.createTemp('dpgrabber_shot2_');
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

void main() {
  testWidgets('settings account section, logged out', (tester) async {
    await _phoneViewport(tester);
    final state = (await tester.runAsync(_testState))!;
    addTearDown(state.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: RepaintBoundary(key: key, child: SettingsPage(state: state)),
    ));
    await _capture(tester, key, 'settings-phone-logged-out.png');
    expect(find.text('登录验证'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  }, skip: true);

  testWidgets('settings account section, logged in', (tester) async {
    await _phoneViewport(tester);
    final state = (await tester.runAsync(_testState))!;
    addTearDown(state.dispose);
    state.loggedIn = true;
    state.loginPhone = '13800000000';
    state.clerk = const Clerk(id: 230313, name: '加冰', status: 1);
    state.session = const Session(token: 'fake', sid: '92');
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: RepaintBoundary(key: key, child: SettingsPage(state: state)),
    ));
    await _capture(tester, key, 'settings-phone-logged-in.png');
    expect(find.text('加冰'), findsOneWidget);
    expect(find.text('店铺 92'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  }, skip: true);
}
