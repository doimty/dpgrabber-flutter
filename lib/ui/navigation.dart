/// Navigation shell: one set of three destinations — 监听 (dashboard),
/// 历史, 设置 — rendered with the wenxi navigation system: an 88px
/// glass side rail on wide screens (desktop) and the liquid bottom bar
/// (spring lens + refraction) on phones. Login lives in the Settings
/// "账号" section (§10.2); there is no standalone login page — the
/// shell is always shown after init.
library;

import 'package:flutter/material.dart';

import '../wenxi_ui/app_navigation.dart';
import '../wenxi_ui/liquid_bottom_navigation.dart';
import 'app_state.dart';
import 'history_page.dart';
import 'listen_page.dart';
import 'settings_page.dart';
import 'widgets.dart';

class AppShell extends StatefulWidget {
  final AppState state;
  final int initialIndex;

  const AppShell({super.key, required this.state, this.initialIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: widget.state,
      child: AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kFloatingNavBreakpoint;
              final pages = [
                ListenPage(state: widget.state),
                HistoryPage(state: widget.state),
                SettingsPage(state: widget.state),
              ];
              final navigation = AppNavigation(
                selectedIndex: _index,
                onSelected: (i) => setState(() => _index = i),
                rail: wide,
              );
              if (wide) {
                return Scaffold(
                  body: Row(
                    children: [
                      navigation,
                      Expanded(
                        child: IndexedStack(index: _index, children: pages),
                      ),
                    ],
                  ),
                );
              }
              // Phones: the pill truly floats — the body extends under
              // it (Stack overlay, not the Scaffold's bottomNavigationBar
              // slot, which reserves a band and leaves a blank strip
              // around the pill). Pages reserve bottomNavClearance()
              // at the bottom of their scroll views so the last row
              // clears the pill; content scrolls visibly underneath it.
              return Scaffold(
                extendBody: true,
                body: Stack(
                  children: [
                    IndexedStack(index: _index, children: pages),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: navigation,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
