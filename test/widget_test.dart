// Smoke test: the app boots to the login page when logged out.
// (The old counter demo this file tested was removed with the real
// entry point in lib/main.dart; see test/ui/ui_test.dart.)
library;

import 'dart:io';

import 'package:dpgrabber/main.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App boots to login when logged out', (tester) async {
    final state = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('dpgrabber_smoke_');
      final state = AppState(appDir: dir);
      await state.init();
      return state;
    }))!;
    addTearDown(state.dispose);
    await tester.pumpWidget(DpgApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('登录验证'), findsOneWidget);
  });
}
