/// Wenxi app navigation, ported from wenxi/lib/ui/app_navigation.dart.
///
/// Adapted for dpgrabber: three destinations (监听 / 历史 / 设置),
/// Material icons instead of wenxi's SVG set, and the dpgrabber app
/// mark + name in the rail footer.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'appearance.dart';
import 'liquid_bottom_navigation.dart';

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.rail = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool rail;

  static const destinations = [
    ('监听', Icons.radar),
    ('历史', Icons.history),
    ('设置', Icons.settings),
  ];

  @override
  Widget build(BuildContext context) {
    final compact = rail && MediaQuery.sizeOf(context).height < 560;
    final appearance = AppAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final colors = Theme.of(context).colorScheme;
    final active = themeAccent(context);
    final inactive = highContrast || appearance.glassStyle == GlassStyle.clear
        ? colors.onSurface
        : colors.onSurfaceVariant;

    Widget item(int index) {
      final (label, icon) = destinations[index];
      final selected = index == selectedIndex;
      final color = selected ? active : inactive;
      void activate() => onSelected(index);
      return Semantics(
        key: ValueKey('navigation-$index'),
        label: label,
        selected: selected,
        button: true,
        onTap: activate,
        child: InkWell(
          excludeFromSemantics: true,
          onTap: activate,
          customBorder: const StadiumBorder(),
          splashColor: active.withValues(alpha: .12),
          highlightColor: active.withValues(alpha: .05),
          focusColor: active.withValues(alpha: .10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60, minWidth: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: rail ? 18 : 6,
                vertical: rail ? (compact ? 8 : 18) : 9,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 26, color: color),
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (rail) {
      final solid = highContrast || appearance.glassStyle == GlassStyle.solid;
      return ClipRect(
        child: BackdropFilter(
          enabled:
              !solid &&
              !appearance.glassLowPower &&
              TickerMode.valuesOf(context).enabled,
          filter: ui.ImageFilter.blur(
            sigmaX: appearance.blurSigma,
            sigmaY: appearance.blurSigma,
          ),
          child: Material(
            key: const Key('navigation-rail-surface'),
            color: appearance.glassColor.withValues(
              alpha: solid
                  ? 1
                  : appearance.glassLowPower
                  ? .86
                  : appearance.glassOpacity,
            ),
            child: Container(
              width: 88,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: colors.outlineVariant,
                    width: .5,
                  ),
                ),
              ),
              child: SafeArea(
                right: false,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: compact ? 12 : 24,
                      ),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: active.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.radar, color: active, size: 20),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (var i = 0; i < destinations.length; i++)
                              item(i),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(bottom: compact ? 10 : 18),
                      child: Text(
                        '多陪抢单',
                        style: TextStyle(fontSize: 10, color: inactive),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return LiquidBottomNavigation(
      selectedIndex: selectedIndex,
      onSelected: onSelected,
      destinations: destinations,
      destinationIds: [for (var i = 0; i < destinations.length; i++) i],
    );
  }
}
