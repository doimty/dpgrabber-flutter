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
import 'package:dpgrabber/ui/advanced_settings_page.dart';
import 'package:dpgrabber/ui/app_state.dart';
import 'package:dpgrabber/ui/history_page.dart';
import 'package:dpgrabber/ui/listen_page.dart';
import 'package:dpgrabber/ui/log_store.dart';
import 'package:dpgrabber/ui/navigation.dart';
import 'package:dpgrabber/ui/settings_page.dart';
import 'package:dpgrabber/ui/widgets.dart';
import 'package:dpgrabber/wenxi_ui/app_switch.dart';
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
      // Merged shop line: one row, cached values, never blank.
      expect(find.text('店铺 92 · ID 230313'), findsOneWidget);
      expect(find.text('店铺 92'), findsNothing);
      expect(find.text('ID：230313'), findsNothing);
      expect(find.text('登录验证'), findsNothing);
      // No way back to "logged out with a saved account": the
      // account stays signed in until its credentials are cleared.
      expect(find.text('退出登录'), findsNothing);
    });
  });

  group('add account (§10.2)', () {
    /// A logged-in state with a stubbed login flow (same stubs as
    /// the cold-start group): current account 138****0000, clerk
    /// 加冰 / ID 230313, shop 92. All test data is fake.
    Future<AppState> loggedInStubbedState(WidgetTester tester) async {
      final state = (await tester.runAsync(() async {
        final dir =
            await Directory.systemTemp.createTemp('dpgrabber_add_acct_');
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
        await FileCredentialStore(dir)
            .saveAccount(phone: '13800000000', password: 'fake-pw');
        final s = AppState(appDir: dir, transport: transport);
        await s.init();
        for (var i = 0;
            i < 100 && (s.session == null || s.clerk == null);
            i++) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        return (state: s, transport: transport);
      }))!;
      return state.state;
    }

    /// Tall viewport so the whole account card (identity + saved
    /// rows + add row + expanded form) is on screen without
    /// scrolling, like the redesign group does.
    void tallViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// A logged-in state built from plain field assignment (no
    /// transport needed — no login is attempted).
    Future<AppState> loggedInFakeState(WidgetTester tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      state.loggedIn = true;
      state.loginPhone = '13800000000';
      state.clerk = const Clerk(id: 230313, name: '加冰', status: 1);
      state.session = const Session(token: 'fake', sid: '92');
      await tester.runAsync(
        () => state.updateConfig(
          state.config.copyWith(
            clerkId: 230313,
            clerkName: '加冰',
            shopId: 92,
          ),
        ),
      );
      state.savedAccounts = [
        {'phone': '13800000000', 'clerk_name': '加冰', 'shop': '92'},
      ];
      return state;
    }

    /// Opens the account sheet from the card header.
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('加冰'));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsOneWidget);
    }

    /// Opens the sheet, then the add form inside it.
    Future<void> openAddForm(WidgetTester tester) async {
      await openSheet(tester);
      await tester.tap(find.text('添加账号'));
      await tester.pumpAndSettle();
      expect(
        find.text('添加一个新账号，登录成功后会保存并切换过去'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextField, '11 位手机号'),
        findsOneWidget,
      );
    }

    testWidgets('card opens the sheet; single account is one checked row',
        (tester) async {
      final state = await loggedInFakeState(tester);
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      // Card shows only the current identity — no saved row, no
      // add row, no clear action on the page itself.
      expect(find.text('加冰 · 138****0000 · 店 92'), findsNothing);
      expect(find.text('添加账号'), findsNothing);
      expect(find.text('清除已保存账号'), findsNothing);
      // The card is the sheet entry: a chevron on the header row.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('加冰'),
            matching: find.byType(InkWell),
          ),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
      );
      // Open the sheet: one checked row, add row, clear action.
      await tester.tap(find.text('加冰'));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsOneWidget);
      expect(find.text('加冰 · 138****0000 · 店 92'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('添加账号'), findsOneWidget);
      expect(find.text('清除已保存账号'), findsOneWidget);
      // No chevron on the saved row (selection, not navigation).
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('加冰 · 138****0000 · 店 92'),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
      );
      // Close the sheet again via the X.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsNothing);
    });

    testWidgets('no sheet entry when logged out', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      state.savedAccounts = [
        {'phone': '13800000000', 'clerk_name': '加冰', 'shop': '92'},
      ];
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('添加账号'), findsNothing);
      expect(find.text('切换账号'), findsNothing);
      expect(find.text('登录验证'), findsOneWidget);
      // The logged-out card is the login form, not a sheet entry:
      // no chevron on it.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('登录验证'),
            matching: find.byType(AppCard),
          ),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
      );
    });

    testWidgets('invalid add input shows inline error, changes nothing',
        (tester) async {
      final state = await loggedInFakeState(tester);
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      await openAddForm(tester);
      // Empty submit first.
      await tester.tap(find.text('登录验证'));
      await tester.pump();
      expect(find.text('请输入手机号'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '11 位手机号'),
        '1380000000',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '账号密码'),
        'x',
      );
      await tester.tap(find.text('登录验证'));
      await tester.pump();
      expect(find.text('手机号应为 11 位数字'), findsOneWidget);
      // Nothing changed: still the old session, old saved list,
      // form still open.
      expect(state.session?.sid, '92');
      expect(state.loginPhone, '13800000000');
      expect(state.savedAccounts.length, 1);
      expect(
        find.widgetWithText(TextField, '11 位手机号'),
        findsOneWidget,
      );
    });

    testWidgets('valid add appends to saved accounts and switches',
        (tester) async {
      final state = await loggedInStubbedState(tester);
      addTearDown(state.dispose);
      expect(state.session?.sid, '92');
      expect(state.savedAccounts.length, 1);
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      await openAddForm(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '11 位手机号'),
        '13900000001',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '账号密码'),
        'new-pw',
      );
      await tester.tap(find.text('登录验证'));
      await tester.pumpAndSettle();
      // Switched to the new account, old one kept.
      expect(state.loginPhone, '13900000001');
      expect(state.session, isNotNull);
      expect(state.session!.sid, '92');
      expect(state.savedAccounts.length, 2);
      expect(
        state.savedAccounts
            .map((a) => (a['phone'] ?? '').toString())
            .toSet(),
        containsAll(['13800000000', '13900000001']),
      );
      // Sheet dismissed; card header shows the new account.
      expect(find.text('切换账号'), findsNothing);
      expect(find.text('添加账号'), findsNothing);
      expect(
        find.widgetWithText(TextField, '11 位手机号'),
        findsNothing,
      );
      expect(find.text('139****0001'), findsOneWidget);
    });

    testWidgets('two saved accounts: sheet list has a checkmark; '
        'tapping the other switches and dismisses', (tester) async {
      final state = await loggedInStubbedState(tester);
      addTearDown(state.dispose);
      expect(state.session?.sid, '92');
      // A second saved account (credentials + per-account config
      // with its own clerk name), so the sheet lists two rows.
      await tester.runAsync(() async {
        await (state.store as FileCredentialStore).saveAccount(
          phone: '13900000001',
          password: 'new-pw',
        );
        state.accounts.saveAccount(
          state.config.copyWith(
            phone: '13900000001',
            clerkName: '小红',
            clerkId: 230314,
            shopId: 92,
          ),
          phone: '13900000001',
        );
        // The stubbed login never persists the shop id (the real
        // API does — on Yahel's device the row reads 店 92):
        // stamp it on the 138 file so the labels match production.
        state.accounts.saveAccount(
          state.config.copyWith(shopId: 92),
          phone: '13800000000',
        );
      });
      state.savedAccounts = state.accounts.listAccounts();
      expect(state.savedAccounts.length, 2);
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      await openSheet(tester);
      // Both rows render; current (138) carries the checkmark,
      // the other row has none; no row has a chevron.
      expect(find.text('加冰 · 138****0000 · 店 92'), findsOneWidget);
      expect(find.text('小红 · 139****0001 · 店 92'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('加冰 · 138****0000 · 店 92'),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      for (final label in [
        '加冰 · 138****0000 · 店 92',
        '小红 · 139****0001 · 店 92',
      ]) {
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text(label),
              matching: find.byType(ListTile),
            ),
            matching: find.byIcon(Icons.chevron_right),
          ),
          findsNothing,
        );
      }
      // Tap the other row: switches to it, sheet dismisses.
      await tester.tap(find.text('小红 · 139****0001 · 店 92'));
      await tester.pumpAndSettle();
      expect(state.loginPhone, '13900000001');
      expect(state.session?.sid, '92');
      expect(find.text('切换账号'), findsNothing);
      expect(find.text('139****0001'), findsOneWidget);
    });

    testWidgets('clear saved accounts lives at the sheet bottom',
        (tester) async {
      final state = await loggedInFakeState(tester);
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      // Not on the page: only in the sheet.
      expect(find.text('清除已保存账号'), findsNothing);
      await openSheet(tester);
      expect(find.text('清除已保存账号'), findsOneWidget);
      // Cancel keeps the sheet open.
      await tester.tap(find.text('清除已保存账号'));
      await tester.pumpAndSettle();
      expect(find.text('将删除已保存的手机号和密码。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsOneWidget);
      expect(state.loggedIn, isTrue);
      // Confirm: sheet dismisses, back to the login form.
      await tester.tap(find.text('清除已保存账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsNothing);
      expect(state.loggedIn, isFalse);
      expect(find.text('登录验证'), findsOneWidget);
    });

    testWidgets('failed add leaves the current session untouched',
        (tester) async {
      final result = (await tester.runAsync(() async {
        final dir =
            await Directory.systemTemp.createTemp('dpgrabber_add_fail_');
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
        await FileCredentialStore(dir)
            .saveAccount(phone: '13800000000', password: 'fake-pw');
        final s = AppState(appDir: dir, transport: transport);
        await s.init();
        for (var i = 0;
            i < 100 && (s.session == null || s.clerk == null);
            i++) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        return (state: s, transport: transport);
      }))!;
      final state = result.state;
      addTearDown(state.dispose);
      expect(state.session?.sid, '92');
      // From here the login endpoint rejects: the add must fail.
      result.transport.onJson('/s/duopei-account/login',
          {'code': 401, 'msg': '密码错误'});
      tallViewport(tester);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      await openAddForm(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '11 位手机号'),
        '13900000001',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '账号密码'),
        'wrong-pw',
      );
      await tester.tap(find.text('登录验证'));
      await tester.pumpAndSettle();
      expect(find.textContaining('登录失败'), findsOneWidget);
      // Current session, identity and saved list all untouched;
      // the form stays open for a retry.
      expect(state.session?.sid, '92');
      expect(state.loggedIn, isTrue);
      expect(state.loginPhone, '13800000000');
      expect(state.savedAccounts.length, 1);
      expect(
        find.widgetWithText(TextField, '11 位手机号'),
        findsOneWidget,
      );
    });
  });

  group('cold-start auto-login (§10.2, login-bug2 video sequence)', () {
    /// The transport of the last cold start built by
    /// [savedAccountState], so tests can count its requests.
    FakeTransport? lastTransport;

    /// A state with a saved account + a stubbed login flow, as the
    /// video showed it: phone 138****0000, clerk 加冰 / ID 230313,
    /// shop 92, week stats 3 orders at a 25.0% renewal rate.
    Future<AppState> savedAccountState() async {
      final dir =
          await Directory.systemTemp.createTemp('dpgrabber_login_bug2_');
      final transport = FakeTransport();
      lastTransport = transport;
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
      expect(state.config.clerkId, 230313);
      expect(state.online, isTrue);

      await tester.pumpWidget(_wrap(state, ListenPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.textContaining('店铺 92 · 加冰'), findsOneWidget);
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

    testWidgets('week stats refresh automatically after the cold-start restore',
        (tester) async {
      final state = (await tester.runAsync(savedAccountState))!;
      addTearDown(state.dispose);
      // The background restore ends with a stats refresh: wait for
      // it instead of calling refreshWeekStats ourselves.
      for (var i = 0; i < 100 && state.weekStats == null; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(state.weekStats, isNotNull);
      expect(state.weekStats!.orderCount, 3);
      expect(state.weekStats!.renewalRate, 25.0);
    });

    testWidgets('concurrent ensureSession calls run the login chain once',
        (tester) async {
      final state = (await tester.runAsync(savedAccountState))!;
      addTearDown(state.dispose);
      final transport = lastTransport!;
      int loginCalls() => transport.requests
          .where((r) => r.url.path.contains('/s/duopei-account/login'))
          .length;
      expect(state.session, isNotNull);
      final before = loginCalls();
      // Drop the session, then ask for it from three places at once.
      state.session = null;
      final results = await tester.runAsync(
        () => Future.wait([
          state.ensureSession(),
          state.ensureSession(),
          state.ensureSession(),
        ]),
      );
      expect(results, [true, true, true]);
      expect(state.session, isNotNull);
      expect(loginCalls() - before, 1);
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
      expect(find.text('保存设置'), findsNothing);
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
        '监听行为',
        '高级设置',
      ]) {
        await scrollTo(find.text(title));
        expect(find.text(title), findsOneWidget);
      }
      // No save button anywhere, no AES section, and the advanced
      // fields are not on the main page.
      expect(find.text('保存设置'), findsNothing);
      expect(find.text('AES 密钥（十六进制）'), findsNothing);
      expect(find.text('优先店铺（0=自动）'), findsNothing);
      expect(find.text('推送密钥'), findsNothing);
      // Stored values are untouched: the fixed theme/glass/background
      // still come from the saved config, not from any UI.
      expect(state.config.theme, 'day');
      expect(state.glass.level, GlassLevel.clear);
      expect(state.background.settings.cardOpacity, 0.86);
      expect(state.background.settings.blur, 6.0);
      expect(state.background.settings.brightness, 0.90);
    });

    testWidgets('invalid number is rejected per-field with an inline error',
        (tester) async {
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
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('最小金额 必须是数字'), findsOneWidget);
      // Config unchanged after a rejected commit; the typed text
      // stays visible (never swallowed).
      expect(state.config.minAmount, 10.0);
      expect(
        tester.widget<TextField>(field).controller?.text,
        'abc',
      );
    });

    testWidgets('cross-field rule is rejected on the offending field',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      // Minimum is 10 (default): a maximum of 5 breaks max >= min.
      await tester.enterText(
        find.widgetWithText(TextField, '填 0 不限制'),
        '5',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.text('最大金额不能小于最小金额（填 0 不限制）'),
        findsOneWidget,
      );
      expect(state.config.maxAmount, 0.0);
    });

    testWidgets('valid number commits on submit', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '不低于此价才抢'),
        '20',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(state.config.minAmount, 20.0);
      expect(find.text('最小金额 必须是数字'), findsNothing);
    });
  });

  group('settings redesign: auto-save + split (§10.4/§10.5)', () {
    /// The AppSwitch belonging to the SwitchRow labelled [label].
    Finder switchFor(String label) => find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(SwitchRow),
          ),
          matching: find.byType(AppSwitch),
        );

    test('main and advanced field sets are disjoint, AES nowhere', () {
      final overlap = SettingsPage.fieldKeys
          .toSet()
          .intersection(AdvancedSettingsPage.fieldKeys.toSet());
      expect(overlap, isEmpty);
      for (final key in [
        ...SettingsPage.fieldKeys,
        ...AdvancedSettingsPage.fieldKeys,
      ]) {
        expect(key, isNot(startsWith('aes')));
      }
    });

    testWidgets('switch toggle does not discard uncommitted textbox input',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      // Type a new minimum amount, then tap a switch without
      // submitting first: the blur commit must land before the
      // switch's own updateConfig, so the value survives (this is
      // the old display-vs-engine desync bug).
      final field = find.widgetWithText(TextField, '不低于此价才抢');
      await tester.enterText(field, '20');
      // Blur-commit, driven through the field's real Focus node:
      // taps never acquire focus in this test environment (verified
      // with a bare-TextField probe), so the node is focused and
      // unfocused programmatically. The unfocus fires the same
      // onSubmitted callback a tap-away fires on a real device.
      final node = Focus.of(tester.element(field));
      node.requestFocus();
      await tester.pump();
      node.unfocus();
      await tester.pumpAndSettle();
      expect(state.config.minAmount, 20.0);
      await tester.ensureVisible(switchFor('语音播报'));
      await tester.tap(switchFor('语音播报'));
      await tester.pumpAndSettle();
      expect(state.config.minAmount, 20.0);
      expect(state.config.voiceEnabled, isFalse);
    });

    testWidgets('advanced page holds the advanced fields', (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('优先店铺（0=自动）'), findsNothing);
      expect(find.text('推送密钥'), findsNothing);
      // The advanced entry is at the bottom of the main page.
      for (var i = 0; i < 30; i++) {
        if (find.text('高级设置').evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(find.text('优先店铺（0=自动）'), findsOneWidget);
      expect(find.text('抢单推送'), findsOneWidget);
      expect(find.text('接单类型匹配词'), findsOneWidget);
      expect(find.text('保存设置'), findsNothing);
      expect(find.text('AES 密钥（十六进制）'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('接单条件'), findsWidgets);
    });

    testWidgets(
        'logged-in account card shows only the current identity; '
        'accounts live in the sheet',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      state.loggedIn = true;
      state.loginPhone = '13800000000';
      state.clerk = const Clerk(id: 230313, name: '加冰', status: 1);
      state.session = const Session(token: 'fake', sid: '92');
      await state.updateConfig(
        state.config.copyWith(clerkId: 230313, clerkName: '加冰', shopId: 92),
      );
      state.savedAccounts = [
        {'phone': '13800000000', 'clerk_name': '加冰', 'shop': '92'},
      ];
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      // Title 17/w600, merged shop line, phone line.
      expect(find.text('加冰'), findsOneWidget);
      expect(tester.widget<Text>(find.text('加冰')).style?.fontSize, 17);
      expect(find.text('店铺 92 · ID 230313'), findsOneWidget);
      expect(find.text('138****0000'), findsOneWidget);
      // Nothing else in the card: no duplicate saved row, no
      // clear action on the page — they live in the sheet.
      expect(find.text('已保存账号'), findsNothing);
      expect(find.text('加冰 · 138****0000 · 店 92'), findsNothing);
      expect(find.text('清除已保存账号'), findsNothing);
      // Tapping the card opens the sheet with the list.
      await tester.tap(find.text('加冰'));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsOneWidget);
      expect(find.text('加冰 · 138****0000 · 店 92'), findsOneWidget);
      expect(find.text('清除已保存账号'), findsOneWidget);
    });

    testWidgets(
        'account card keeps the shop line from cache while the session is rebuilding',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await state.updateConfig(state.config.copyWith(
        shopId: 92,
        clerkId: 230313,
        clerkName: '加冰',
      ));
      state.loggedIn = true;
      state.loginPhone = '13800000000';
      // No session, no clerk object: everything comes from cache.
      await tester.pumpWidget(_wrap(state, SettingsPage(state: state)));
      await tester.pumpAndSettle();
      expect(find.text('加冰'), findsOneWidget);
      expect(find.text('店铺 92 · ID 230313'), findsOneWidget);
      expect(find.text('138****0000'), findsOneWidget);
    });

    testWidgets('listen hero shows cached identity while restoring',
        (tester) async {
      final state = await _testStateWith(tester);
      addTearDown(state.dispose);
      await state.updateConfig(
        state.config.copyWith(shopId: 92, clerkName: '加冰'),
      );
      state.loggedIn = true;
      state.loginPhone = '13800000000';
      state.sessionRestoring = true;
      await tester.pumpWidget(_wrap(state, ListenPage(state: state)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('店铺 92 · 加冰 · 同步中…'),
        findsOneWidget,
      );
      expect(find.text('未登录'), findsNothing);
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
