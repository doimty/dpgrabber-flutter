/// Liquid-glass styles (wenxi-inspired, own implementation).
///
/// Three glass levels, from the design reference:
/// - clear:   opacity .40, blur 8
/// - frosted: opacity .92–.94, blur 18
/// - solid:   opacity 1.0, blur 0
/// Plus a low-power switch that turns blur off everywhere.
///
/// The default level is clear (the reference default): at frosted
/// the surfaces are nearly opaque and the glass barely reads as
/// glass.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import 'palette.dart';

/// Corner radii (design reference): inputs 12, buttons 10, dialogs 18.
const double kInputRadius = 12;
const double kButtonRadius = 10;
const double kDialogRadius = 18;

/// Desktop glass rail width (wenxi: 88px).
const double kDesktopRailWidth = 88;

/// Glass levels.
enum GlassLevel {
  clear(0.40, 8),
  frosted(0.93, 18),
  solid(1.0, 0);

  const GlassLevel(this.opacity, this.blur);
  final double opacity;
  final double blur;
}

/// Glass settings held by the app: level + low-power flag.
class GlassSettings extends ChangeNotifier {
  GlassLevel level;
  bool lowPower;

  GlassSettings({this.level = GlassLevel.clear, this.lowPower = false});

  double get effectiveBlur =>
      (lowPower || level == GlassLevel.solid) ? 0 : level.blur;

  void setLevel(GlassLevel next) {
    if (level != next) {
      level = next;
      notifyListeners();
    }
  }

  void setLowPower(bool value) {
    if (lowPower != value) {
      lowPower = value;
      notifyListeners();
    }
  }
}

/// A card-surface container with a backdrop blur (glass). When blur is
/// off (solid level or low power) it degrades to a plain translucent
/// card — never to an invisible one.
class GlassBox extends StatelessWidget {
  final Widget child;
  final AppPalette palette;
  final GlassSettings glass;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? tint;

  const GlassBox({
    super.key,
    required this.child,
    required this.palette,
    required this.glass,
    this.radius = kInputRadius,
    this.padding,
    this.margin,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final base = tint ?? palette.cardBg;
    final fill = base.withValues(alpha: glass.level.opacity);
    final decoration = BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      // Hairline border (design reference: .6–.7), not a 1px rule.
      border: Border.all(color: palette.cardBorder, width: 0.7),
    );
    final blur = glass.effectiveBlur;
    final box = Container(
      padding: padding,
      margin: margin,
      decoration: decoration,
      child: child,
    );
    if (blur <= 0) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: box,
      ),
    );
  }
}

/// Vertical gradient used for the hero band (hero_top -> hero_bottom).
LinearGradient heroGradient(AppPalette palette) => LinearGradient(
      colors: [palette.heroTop, palette.heroBottom],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
