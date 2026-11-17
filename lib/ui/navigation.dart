/// Navigation shell (PORTING_CONTRACT §10.1/§10.7, wenxi navigation):
/// one set of three destinations — 监听 (dashboard), 历史, 设置 —
/// rendered as an 88px glass side rail on wide screens (desktop) and
/// a liquid bottom bar on phones. The login page stands alone outside
/// this shell (see main.dart).
library;

import 'dart:async';
import 'dart:ui';

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
                bottomNavigationBar: _BottomPill(
                  state: widget.state,
                  index: _index,
                  onSelect: (i) => setState(() => _index = i),
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
    final glass = state.glass;
    // Compact rail on short windows (design reference: height < 560).
    final compact = MediaQuery.sizeOf(context).height < 560;
    final bar = Container(
      width: kDesktopRailWidth,
      decoration: BoxDecoration(
        color: palette.cardBg.withValues(alpha: glass.level.opacity),
        border: Border(
          right: BorderSide(color: palette.cardBorder, width: 0.5),
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 12 : 24),
              child: _AppMark(palette: palette),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _destinations.length; i++)
                      _RailItem(
                        icon: _destinations[i].$1,
                        label: _destinations[i].$2,
                        selected: i == index,
                        compact: compact,
                        palette: palette,
                        onTap: () => onSelect(i),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: compact ? 10 : 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '主题：${palette.name}',
                    onPressed: () => _cycleTheme(),
                    icon: Icon(Icons.palette, color: palette.accent),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '多陪抢单',
                    style: TextStyle(fontSize: 10, color: palette.hint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // No blur at the solid level or in low-power mode: the bar degrades
    // to a plain translucent strip, never to an invisible one.
    if (glass.effectiveBlur <= 0) return bar;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: glass.effectiveBlur,
          sigmaY: glass.effectiveBlur,
        ),
        child: bar,
      ),
    );
  }

  void _cycleTheme() {
    final ids = allPalettes.map((p) => p.id).toList();
    final next = ids[(ids.indexOf(state.theme.value) + 1) % ids.length];
    unawaited(state.setTheme(next));
  }
}

/// App mark at the top of the rail (design reference: 34px app icon).
class _AppMark extends StatelessWidget {
  final AppPalette palette;

  const _AppMark({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.radar, color: palette.accent, size: 22),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final AppPalette palette;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Inactive items read as plain text on clear glass (design
    // reference); the selected item is the accent, with no pill.
    final color = selected ? palette.accent : palette.textDark;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60, minWidth: 48),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        splashColor: palette.accent.withValues(alpha: 0.12),
        highlightColor: palette.accent.withValues(alpha: 0.05),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: compact ? 8 : 18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating glass pill navigation (phones, design reference): a 64px
/// bar with 16/12 margins, max 560 wide, blurred translucent fill,
/// and a sliding accent-tinted pill behind the selected destination.
/// Own implementation — no reference code is used.
class _BottomPill extends StatelessWidget {
  final AppState state;
  final int index;
  final ValueChanged<int> onSelect;

  const _BottomPill({
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
    final glass = state.glass;
    final pill = Container(
      height: 64,
      decoration: BoxDecoration(
        color: palette.cardBg.withValues(alpha: glass.level.opacity),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: palette.cardBorder, width: 0.7),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: switch (index) {
              0 => Alignment.centerLeft,
              1 => Alignment.center,
              _ => Alignment.centerRight,
            },
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: FractionallySizedBox(
              widthFactor: 1 / 3,
              child: Center(
                child: Container(
                  height: 48,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < _destinations.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onSelect(i),
                    customBorder: const StadiumBorder(),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _destinations[i].$1,
                          color:
                              i == index ? palette.accent : palette.textDark,
                          size: 26,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _destinations[i].$2,
                          style: TextStyle(
                            color:
                                i == index ? palette.accent : palette.textDark,
                            fontSize: 12,
                            height: 1.15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    final bar = glass.effectiveBlur <= 0
        ? pill
        : ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: glass.effectiveBlur,
                sigmaY: glass.effectiveBlur,
              ),
              child: pill,
            ),
          );
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: palette.textDark.withValues(alpha: 0.12),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: bar,
          ),
        ),
      ),
    );
  }
}
