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
///
/// UI: the wenxi UI system (appTheme + ThemeExtension appearance +
/// liquid glass) drives the MaterialApp; dpgrabber's own palette ids
/// remain the persisted theme source and are adapted in
/// `wenxi_ui/appearance.dart`.
library;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'background/app_background.dart';
import 'bridge/bridge.dart';
import 'theme/glass.dart' show GlassLevel;
import 'ui/app_state.dart';
import 'ui/login_page.dart';
import 'ui/navigation.dart';
import 'wenxi_ui/app_text_scale.dart';
import 'wenxi_ui/app_theme.dart';
import 'wenxi_ui/appearance.dart';
import 'wenxi_ui/skeleton_loading.dart';
import 'wenxi_ui/theme_reveal.dart';

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
      animation: Listenable.merge([state.theme, state.glass]),
      builder: (context, _) {
        final palette = state.theme.palette;
        final brightness = palette.isDark ? Brightness.dark : Brightness.light;
        final glassStyle = switch (state.glass.level) {
          GlassLevel.clear => GlassStyle.clear,
          GlassLevel.frosted => GlassStyle.frosted,
          GlassLevel.solid => GlassStyle.solid,
        };
        return MaterialApp(
          title: '多陪抢单',
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            brightness,
            palette: wenxiPaletteFor(palette),
            glassStyle: glassStyle,
            glassLowPower: state.glass.lowPower,
          ),
          builder: (context, child) => AppBackground(
            controller: state.background,
            child: ThemeRevealHost(
              child: AppTextScale(
                percent: 100,
                child: child ?? const SizedBox(),
              ),
            ),
          ),
          home: AnimatedBuilder(
            animation: state,
            builder: (context, _) {
              if (!state.initialized) {
                return Scaffold(
                  body: SafeArea(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: AppSkeleton(
                          layout: SkeletonLayout.dashboard,
                          semanticLabel: '正在初始化多陪抢单',
                        ),
                      ),
                    ),
                  ),
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
