/// DPGrabber Flutter entry point.
///
/// Startup: read the config + saved account -> not logged in shows the
/// login page, logged in shows the main shell (listen / history /
/// settings). The listen engine, history store, notifier and theme are
/// all wired in [AppState]; this file only bootstraps it.
///
/// Bridge wiring: keep-alive / secure storage / tray / local
/// notifications come from `lib/bridge/` ([AppBridges]). Credentials
/// use the bridge's secure store; the core's development-only file
/// store is only the fallback when no store is passed in.
library;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge/bridge.dart';
import 'theme/app_theme.dart';
import 'ui/app_state.dart';
import 'ui/login_page.dart';
import 'ui/navigation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final bridges = await AppBridges.initialize(configDirectory: docs);
  final state = AppState(appDir: docs, store: bridges.credentialStore);
  state.keepAlive = bridges.keepAlive;
  state.onLocalNotification = (title, body) =>
      bridges.notifications.showNotification(title: title, body: body);
  await bridges.notifications.requestPermission();
  await state.init();
  await bridges.tray.initialize(
    onShow: () => bridges.tray.showWindow(),
    onQuit: () async {
      state.stopListening();
      await bridges.tray.quit();
    },
  );
  runApp(DpgApp(state: state));
}

class DpgApp extends StatelessWidget {
  final AppState state;

  const DpgApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state.theme,
      builder: (context, _) {
        return MaterialApp(
          title: '多陪抢单',
          theme: buildThemeData(state.theme.palette),
          home: AnimatedBuilder(
            animation: state,
            builder: (context, _) {
              if (!state.initialized) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              if (!state.loggedIn) {
                return LoginPage(state: state);
              }
              return AppShell(state: state);
            },
          ),
        );
      },
    );
  }
}
