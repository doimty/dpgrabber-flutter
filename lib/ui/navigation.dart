/// Navigation shell (PORTING_CONTRACT §10.1/§10.7, wenxi navigation):
/// one set of three destinations — 监听 (dashboard), 历史, 设置 —
/// rendered as an 88px glass side rail on wide screens (desktop) and
/// a liquid bottom bar on phones. The login page stands alone outside
/// this shell (see main.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/palette.dart';
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

  static const _destinations = [
    (Icons.radar, '监听'),
    (Icons.history, '历史'),
    (Icons.settings, '设置'),
  ];

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
              if (wide) {
                return Scaffold(
                  body: Row(
                    children: [
                      _Rail(
                        state: widget.state,
                        index: _index,
                        onSelect: (i) => setState(() => _index = i),
                      ),
                      Expanded(
                        child: IndexedStack(index: _index, children: pages),
                      ),
                    ],
                  ),
                );
              }
              return Scaffold(
                body: IndexedStack(index: _index, children: pages),
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: _index,
                  onTap: (i) => setState(() => _index = i),
                  items: [
                    for (final (icon, label) in _destinations)
                      BottomNavigationBarItem(icon: Icon(icon), label: label),
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

/// 88px glass side rail (desktop navigation).
class _Rail extends StatelessWidget {
  final AppState state;
  final int index;
  final ValueChanged<int> onSelect;

  const _Rail({
    required this.state,
    required this.index,
    required this.onSelect,
  });

  static const _destinations = [
    (Icons.radar, '监听'),
    (Icons.history, '历史'),
    (Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = state.theme.palette;
    return Container(
      width: kDesktopRailWidth,
      color: palette.sidebarBg,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            _RailAvatar(palette: palette, label: _initials),
            const SizedBox(height: 24),
            for (var i = 0; i < _destinations.length; i++)
              _RailItem(
                icon: _destinations[i].$1,
                label: _destinations[i].$2,
                selected: i == index,
                palette: palette,
                onTap: () => onSelect(i),
              ),
            const Spacer(),
            IconButton(
              tooltip: '主题：${palette.name}',
              onPressed: () => _cycleTheme(),
              icon: Icon(Icons.palette, color: palette.accent),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  String get _initials {
    final name = state.clerk?.name ?? state.config.clerkName;
    if (name.isNotEmpty) return name.characters.first.toUpperCase();
    final phone = state.currentPhone;
    return phone.isEmpty ? '多' : phone.characters.first;
  }

  void _cycleTheme() {
    final ids = allPalettes.map((p) => p.id).toList();
    final next = ids[(ids.indexOf(state.theme.value) + 1) % ids.length];
    unawaited(state.setTheme(next));
  }
}

class _RailAvatar extends StatelessWidget {
  final AppPalette palette;
  final String label;

  const _RailAvatar({required this.palette, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.heroTop, palette.heroBottom],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? palette.accent : palette.sidebarHint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? palette.selectionBg : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(color: color, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
