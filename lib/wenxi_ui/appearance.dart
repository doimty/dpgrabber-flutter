/// Wenxi appearance model, ported from wenxi/lib/domain/appearance.dart.
///
/// The original enum [WenxiPalette] is kept as a class with the five
/// wenxi presets as constants, so dpgrabber's own palettes can drive
/// the same appearance pipeline through [wenxiPaletteFor].
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/material.dart' show Color;

import '../theme/palette.dart' as dpg;

@immutable
class WenxiPalette {
  const WenxiPalette._(
    this.name,
    this.label,
    this.lightAccent,
    this.darkAccent,
    this.lightCompanion,
    this.darkCompanion,
  );

  final String name, label;
  final int lightAccent, darkAccent, lightCompanion, darkCompanion;

  static const blue = WenxiPalette._(
    'blue',
    '经典蓝',
    0xff0066d0,
    0xff78b8ff,
    0xff6652bb,
    0xffbbb0ff,
  );
  static const mint = WenxiPalette._(
    'mint',
    '薄荷绿',
    0xff087859,
    0xff68dcb5,
    0xff067c8c,
    0xff75d7e5,
  );
  static const violet = WenxiPalette._(
    'violet',
    '柔紫',
    0xff7055bf,
    0xffc0acff,
    0xff5066b9,
    0xffafbeff,
  );
  static const rose = WenxiPalette._(
    'rose',
    '樱花粉',
    0xffaf3c6b,
    0xffffadc9,
    0xff8653ac,
    0xffd9b1f3,
  );
  static const amber = WenxiPalette._(
    'amber',
    '暖橙',
    0xffa6510b,
    0xffffc17d,
    0xffb24735,
    0xffffaf9b,
  );

  static const List<WenxiPalette> values = [blue, mint, violet, rose, amber];

  static WenxiPalette parse(Object? value) => values.firstWhere(
    (palette) => palette.name == value,
    orElse: () => blue,
  );

  AppearanceColors colors(bool dark) => AppearanceColors(this, dark);

  @override
  bool operator ==(Object other) =>
      other is WenxiPalette &&
      name == other.name &&
      label == other.label &&
      lightAccent == other.lightAccent &&
      darkAccent == other.darkAccent &&
      lightCompanion == other.lightCompanion &&
      darkCompanion == other.darkCompanion;

  @override
  int get hashCode => Object.hash(
    name,
    label,
    lightAccent,
    darkAccent,
    lightCompanion,
    darkCompanion,
  );
}

enum GlassStyle {
  clear('液态玻璃', '折射页面内容，按压与滑动时呈现透镜和高光'),
  frosted('磨砂', '背景更柔和，文字和图标更突出'),
  solid('实色', '使用不透明背景，减少图形效果');

  const GlassStyle(this.label, this.description);
  final String label, description;

  static GlassStyle parse(Object? value) =>
      values.firstWhere((style) => style.name == value, orElse: () => clear);
}

/// Shared by Flutter surfaces and the native Android transfer overlay.
class AppearanceColors {
  AppearanceColors(WenxiPalette palette, this.dark)
    : accent = dark ? palette.darkAccent : palette.lightAccent,
      companion = dark ? palette.darkCompanion : palette.lightCompanion;

  final bool dark;
  final int accent, companion;
  int get onAccent => dark ? 0xff101418 : 0xffffffff;
  int get foreground => dark ? 0xfff5f5f7 : 0xff17191d;
  int get muted => dark ? 0xffb5b7bf : 0xff656975;
  int get surface => _tint(dark ? 0xff141416 : 0xffffffff, dark ? .025 : .008);
  int get fill => _tint(dark ? 0xff262628 : 0xfff2f2f7, .035);
  int get border => _tint(dark ? 0xff414146 : 0xffe2e3e8, .05);
  int get softAccent => _tint(surface, dark ? .14 : .09);
  int get glass => _tint(dark ? 0xff1c1d21 : 0xffffffff, dark ? .04 : .008);

  int _tint(int background, double amount) {
    int channel(int shift) =>
        (((background >> shift) & 255) * (1 - amount) +
                ((accent >> shift) & 255) * amount)
            .round();
    return 0xff000000 | channel(16) << 16 | channel(8) << 8 | channel(0);
  }

  Map<String, Object> overlay(GlassStyle style) => {
    'accent': accent,
    'onAccent': onAccent,
    'companion': companion,
    'foreground': foreground,
    'muted': muted,
    'surface': surface,
    'background': fill,
    'border': border,
    'softAccent': softAccent,
    'glassStyle': style.name,
  };
}

/// Adapter: derive a wenxi palette from dpgrabber's own [dpg.AppPalette].
///
/// dpgrabber palettes carry four seeds (light accent / dark accent /
/// companion / text seed). The companion is a light tone for light
/// themes and a dark tone for the night theme, so the dark companion
/// falls back to a darkened companion for light palettes — the wenxi
/// AppearanceColors only tint toward the accent anyway.
WenxiPalette wenxiPaletteFor(dpg.AppPalette palette) {
  int argb(Color c) => c.toARGB32();
  final companion = argb(palette.seeds.companion);
  final darkCompanion = palette.isDark
      ? companion
      : _darken(companion, 0.78);
  return WenxiPalette._(
    palette.id,
    palette.name,
    argb(palette.seeds.lightAccent),
    argb(palette.seeds.darkAccent),
    companion,
    darkCompanion,
  );
}

int _darken(int color, double amount) {
  int channel(int shift) =>
      (((color >> shift) & 255) * (1 - amount)).round();
  return 0xff000000 | channel(16) << 16 | channel(8) << 8 | channel(0);
}
