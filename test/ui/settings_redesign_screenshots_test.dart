/// Screenshot record for the settings redesign (§10.4/§10.5):
/// the post-redesign Settings main page (logged-in account card with
/// the merged shop line + saved accounts folded in, auto-save, no
/// save buttons, no AES) and the new Advanced sub-page, at phone
/// size, under ~/workspace/dpgrabber-flutter-fixes/settings-redesign/after/.
///
/// SKIPPED on this VM on purpose — same reason as
/// login_bug2_screenshots_test.dart: `Image.toByteData` wedges this
/// VM's software rasterizer (the test body finishes but the isolate
/// never exits). `pumpAndSettle` and `toImage` alone are fine.
/// Re-enable on a machine with a real GPU/rasterizer to re-capture.
/// The assertions are covered by the non-skipped tests in
/// test/ui/ui_test.dart ('settings redesign: auto-save + split'), so
/// skipping loses no coverage — only the PNG record.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dpgrabber/core.dart';
import 'package:dpgrabber/theme/app_theme.dart';
import 'package:dpgrabber/ui/advanced_settings_page.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:dpgrabber/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _outDir =
    '/home/hatch/workspace/dpgrabber-flutter-fixes/settings-redesign/after';

Future<AppState> _testState() async {
  final dir = await Directory.systemTemp.createTemp('dpgrabber_shot3_');
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
  testWidgets('settings main page, logged in', (tester) async {
    await _phoneViewport(tester);
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
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: RepaintBoundary(key: key, child: SettingsPage(state: state)),
    ));
    await _capture(tester, key, 'settings-main-phone-logged-in.png');
    expect(find.text('加冰'), findsOneWidget);
    expect(find.text('店铺 92 · ID 230313'), findsOneWidget);
    expect(find.text('保存设置'), findsNothing);
    expect(find.text('AES 密钥（十六进制）'), findsNothing);
  }, skip: true);

  testWidgets('advanced settings sub-page', (tester) async {
    await _phoneViewport(tester);
    final state = (await tester.runAsync(_testState))!;
    addTearDown(state.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildThemeData(state.theme.palette),
      home: RepaintBoundary(
        key: key,
        child: AdvancedSettingsPage(state: state),
      ),
    ));
    await _capture(tester, key, 'advanced-settings-phone.png');
    expect(find.text('优先店铺（0=自动）'), findsOneWidget);
    expect(find.text('抢单推送'), findsNothing); // below the fold at 844px
  }, skip: true);
}
