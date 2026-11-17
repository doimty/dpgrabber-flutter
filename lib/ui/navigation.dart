/// Navigation shell: one set of three destinations — 监听 (dashboard),
/// 历史, 设置 — rendered with the wenxi navigation system: an 88px
/// glass side rail on wide screens (desktop) and the liquid bottom bar
/// (spring lens + refraction) on phones. The login page stands alone
/// outside this shell (see main.dart).
library;

import 'package:flutter/material.dart';

import '../wenxi_ui/app_navigation.dart';
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
              final wide = constraints.maxWidth >= 720;
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
              return Scaffold(
                body: IndexedStack(index: _index, children: pages),
                bottomNavigationBar: navigation,
              );
            },
          );
        },
      ),
    );
  }
}
