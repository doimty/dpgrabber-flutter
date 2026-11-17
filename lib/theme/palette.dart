/// Theme palettes (PORTING_CONTRACT §9, transcribed verbatim from
/// `pc/themes.py`).
///
/// Every theme defines all 36 palette keys. The palette is the single
/// source of truth for UI colours: the UI never hardcodes a colour.
///
/// Organisation follows the wenxi design idea (4 numbers per palette:
/// a light accent, a dark accent, a companion surface tint and a text
/// seed, with the rest derived by mixing) — but the six canonical
/// palettes below are the contract's verbatim values, not derived ones.
/// [derivePaletteFromSeeds] is the extension path: a future theme only
/// needs its 4 seed colours and the remaining keys are mixed from them.
library;

import 'package:flutter/material.dart';

/// All 36 palette keys (§9 `PALETTE_KEYS`).
const List<String> paletteKeys = [
  'window_bg',
  'card_bg',
  'card_border',
  'accent',
  'accent_dark',
  'text_dark',
  'hint',
  'sidebar_bg',
  'sidebar_card_bg',
  'sidebar_card_border',
  'sidebar_text',
  'sidebar_hint',
  'hero_top',
  'hero_bottom',
  'hero_border',
  'hero_stat_dim',
  'btn_top',
  'btn_bottom',
  'btn_hover_top',
  'btn_hover_bottom',
  'btn_disabled_bg',
  'btn_disabled_text',
  'entry_bg',
  'entry_border',
  'selection_bg',
  'history_reason',
  'log_info',
  'log_success',
  'log_warning',
  'log_error',
  'log_debug',
  'outcome_success',
  'outcome_failed',
  'outcome_risk',
  'outcome_unknown',
  'outcome_skipped',
];

Color _c(String hex) {
  final value = int.parse(hex.substring(1), radix: 16);
  return Color(0xFF000000 | value);
}

/// Mix [a] towards [b] by [t] (0 = [a], 1 = [b]).
Color mix(Color a, Color b, double t) =>
    Color.lerp(a, b, t.clamp(0.0, 1.0))!;

/// The four seed colours a palette is organised around (wenxi-style):
/// light accent, dark accent, companion surface tint, and the primary
/// text seed. The six canonical palettes keep their verbatim 36-key
/// maps; the seeds are recorded alongside for derivation of new themes.
class ThemeSeeds {
  final Color lightAccent;
  final Color darkAccent;
  final Color companion;
  final Color textSeed;

  const ThemeSeeds({
    required this.lightAccent,
    required this.darkAccent,
    required this.companion,
    required this.textSeed,
  });
}

class AppPalette {
  final String id;
  final String name;
  final ThemeSeeds seeds;
  final Map<String, Color> _colors;

  AppPalette({
    required this.id,
    required this.name,
    required this.seeds,
    required Map<String, String> hex,
  }) : _colors = {for (final e in hex.entries) e.key: _c(e.value)} {
    assert(
      paletteKeys.every(_colors.containsKey),
      'palette $id is missing keys: '
      '${paletteKeys.where((k) => !_colors.containsKey(k)).join(', ')}',
    );
  }

  Color operator [](String key) => _colors[key] ?? _colors['accent']!;

  Color get windowBg => this['window_bg'];
  Color get cardBg => this['card_bg'];
  Color get cardBorder => this['card_border'];
  Color get accent => this['accent'];
  Color get accentDark => this['accent_dark'];
  Color get textDark => this['text_dark'];
  Color get hint => this['hint'];
  Color get sidebarBg => this['sidebar_bg'];
  Color get sidebarCardBg => this['sidebar_card_bg'];
  Color get sidebarCardBorder => this['sidebar_card_border'];
  Color get sidebarText => this['sidebar_text'];
  Color get sidebarHint => this['sidebar_hint'];
  Color get heroTop => this['hero_top'];
  Color get heroBottom => this['hero_bottom'];
  Color get heroBorder => this['hero_border'];
  Color get heroStatDim => this['hero_stat_dim'];
  Color get btnTop => this['btn_top'];
  Color get btnBottom => this['btn_bottom'];
  Color get btnHoverTop => this['btn_hover_top'];
  Color get btnHoverBottom => this['btn_hover_bottom'];
  Color get btnDisabledBg => this['btn_disabled_bg'];
  Color get btnDisabledText => this['btn_disabled_text'];
  Color get entryBg => this['entry_bg'];
  Color get entryBorder => this['entry_border'];
  Color get selectionBg => this['selection_bg'];
  Color get historyReason => this['history_reason'];
  Color get logInfo => this['log_info'];
  Color get logSuccess => this['log_success'];
  Color get logWarning => this['log_warning'];
  Color get logError => this['log_error'];
  Color get logDebug => this['log_debug'];

  Color outcomeColor(String outcome) => this['outcome_$outcome'];

  bool get isDark => id == 'night';
}

/// Derive a full 36-key palette from four seed colours, for future
/// themes. The six canonical palettes are verbatim and do not go
/// through this function.
AppPalette derivePaletteFromSeeds({
  required String id,
  required String name,
  required ThemeSeeds seeds,
  bool dark = false,
}) {
  final light = seeds.lightAccent;
  final darkAccent = seeds.darkAccent;
  final companion = seeds.companion;
  final text = seeds.textSeed;
  const white = Colors.white;
  final black = Colors.black;
  final window = dark ? mix(black, companion, 0.25) : mix(white, companion, 0.55);
  final card = dark ? mix(black, companion, 0.45) : mix(white, companion, 0.12);
  final border = dark ? mix(companion, white, 0.12) : mix(companion, black, 0.12);
  final hintColor = mix(text, window, 0.45);
  final hex = <String, String>{
    'window_bg': _hex(window),
    'card_bg': _hex(card),
    'card_border': _hex(border),
    'accent': _hex(dark ? light : darkAccent),
    'accent_dark': _hex(darkAccent),
    'text_dark': _hex(text),
    'hint': _hex(hintColor),
    'sidebar_bg': _hex(mix(window, companion, 0.35)),
    'sidebar_card_bg': _hex(card),
    'sidebar_card_border': _hex(border),
    'sidebar_text': _hex(text),
    'sidebar_hint': _hex(hintColor),
    'hero_top': _hex(light),
    'hero_bottom': _hex(darkAccent),
    'hero_border': _hex(mix(companion, white, 0.4)),
    'hero_stat_dim': _hex(mix(light, white, 0.55)),
    'btn_top': _hex(light),
    'btn_bottom': _hex(darkAccent),
    'btn_hover_top': _hex(mix(light, white, 0.2)),
    'btn_hover_bottom': _hex(mix(darkAccent, white, 0.12)),
    'btn_disabled_bg': _hex(mix(window, border, 0.5)),
    'btn_disabled_text': _hex(hintColor),
    'entry_bg': _hex(dark ? mix(black, companion, 0.6) : white),
    'entry_border': _hex(border),
    'selection_bg': _hex(mix(companion, white, 0.5)),
    'history_reason': '#9A6700',
    'log_info': _hex(text),
    'log_success': '#1E8E4D',
    'log_warning': '#9A6700',
    'log_error': '#CF222E',
    'log_debug': _hex(hintColor),
    'outcome_success': '#1E8E4D',
    'outcome_failed': '#CF222E',
    'outcome_risk': '#9A6700',
    'outcome_unknown': _hex(hintColor),
    'outcome_skipped': _hex(hintColor),
  };
  return AppPalette(id: id, name: name, seeds: seeds, hex: hex);
}

String _hex(Color color) {
  final value = (color.r * 255).round() << 16 |
      (color.g * 255).round() << 8 |
      (color.b * 255).round();
  return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

final Map<String, AppPalette> _palettes = {
  'day': AppPalette(
    id: 'day',
    name: '素白晨光',
    seeds: const ThemeSeeds(
      lightAccent: Color(0xFF6E685F),
      darkAccent: Color(0xFF423E37),
      companion: Color(0xFFEDEAE5),
      textSeed: Color(0xFF2A2724),
    ),
    hex: const {
      'window_bg': '#F5F3F0',
      'card_bg': '#FFFFFF',
      'card_border': '#E3DED7',
      'accent': '#585349',
      'accent_dark': '#423E37',
      'text_dark': '#2A2724',
      'hint': '#7B736A',
      'sidebar_bg': '#EDEAE5',
      'sidebar_card_bg': '#FFFFFF',
      'sidebar_card_border': '#DCD6CD',
      'sidebar_text': '#2A2724',
      'sidebar_hint': '#7B736A',
      'hero_top': '#6E685F',
      'hero_bottom': '#4A453F',
      'hero_border': '#EAE6DF',
      'hero_stat_dim': '#EDE9E2',
      'btn_top': '#6E685F',
      'btn_bottom': '#4A453F',
      'btn_hover_top': '#7E776C',
      'btn_hover_bottom': '#585349',
      'btn_disabled_bg': '#DED9D1',
      'btn_disabled_text': '#9C958B',
      'entry_bg': '#FFFFFF',
      'entry_border': '#CFC8BE',
      'selection_bg': '#F1EDE7',
      'history_reason': '#8A5A00',
      'log_info': '#2A2724',
      'log_success': '#1A7F37',
      'log_warning': '#8A5A00',
      'log_error': '#C0392B',
      'log_debug': '#6E665C',
      'outcome_success': '#1A7F37',
      'outcome_failed': '#C0392B',
      'outcome_risk': '#8A5A00',
      'outcome_unknown': '#6E665C',
      'outcome_skipped': '#7B736A',
    },
  ),
  'night': AppPalette(
    id: 'night',
    name: '玄青夜阑',
    seeds: const ThemeSeeds(
      lightAccent: Color(0xFF5AA9E6),
      darkAccent: Color(0xFF3D7FB8),
      companion: Color(0xFF161B22),
      textSeed: Color(0xFFE6EDF3),
    ),
    hex: const {
      'window_bg': '#12161C',
      'card_bg': '#1C2129',
      'card_border': '#2E3742',
      'accent': '#5AA9E6',
      'accent_dark': '#3D7FB8',
      'text_dark': '#E6EDF3',
      'hint': '#8B9BB4',
      'sidebar_bg': '#161B22',
      'sidebar_card_bg': '#212830',
      'sidebar_card_border': '#2E3742',
      'sidebar_text': '#E6EDF3',
      'sidebar_hint': '#8B9BB4',
      'hero_top': '#2E6FA8',
      'hero_bottom': '#1B4A75',
      'hero_border': '#2E4A63',
      'hero_stat_dim': '#B8D4EA',
      'btn_top': '#4A90D9',
      'btn_bottom': '#2E6FA8',
      'btn_hover_top': '#5AA9E6',
      'btn_hover_bottom': '#3D7FB8',
      'btn_disabled_bg': '#2A313B',
      'btn_disabled_text': '#6B7A8C',
      'entry_bg': '#2E3947',
      'entry_border': '#4A5A6E',
      'selection_bg': '#33404F',
      'history_reason': '#D9A441',
      'log_info': '#E6EDF3',
      'log_success': '#4ADE80',
      'log_warning': '#D9A441',
      'log_error': '#FF7B72',
      'log_debug': '#8B9BB4',
      'outcome_success': '#4ADE80',
      'outcome_failed': '#FF7B72',
      'outcome_risk': '#D9A441',
      'outcome_unknown': '#8B9BB4',
      'outcome_skipped': '#8B9BB4',
    },
  ),
  'blue': AppPalette(
    id: 'blue',
    name: '沧澜潮生',
    seeds: const ThemeSeeds(
      lightAccent: Color(0xFF42A5F5),
      darkAccent: Color(0xFF0D47A1),
      companion: Color(0xFFBBD6F2),
      textSeed: Color(0xFF0D2B45),
    ),
    hex: const {
      'window_bg': '#DCEAF8',
      'card_bg': '#F2F8FE',
      'card_border': '#B8D4EE',
      'accent': '#1565C0',
      'accent_dark': '#0D47A1',
      'text_dark': '#0D2B45',
      'hint': '#4A6B8A',
      'sidebar_bg': '#BBD6F2',
      'sidebar_card_bg': '#FFFFFF',
      'sidebar_card_border': '#9CC3E8',
      'sidebar_text': '#0D2B45',
      'sidebar_hint': '#4A6B8A',
      'hero_top': '#42A5F5',
      'hero_bottom': '#1565C0',
      'hero_border': '#BBDEFB',
      'hero_stat_dim': '#E3F2FD',
      'btn_top': '#42A5F5',
      'btn_bottom': '#1565C0',
      'btn_hover_top': '#64B5F6',
      'btn_hover_bottom': '#1976D2',
      'btn_disabled_bg': '#C9D8E4',
      'btn_disabled_text': '#8A9BA8',
      'entry_bg': '#FFFFFF',
      'entry_border': '#9CC3E8',
      'selection_bg': '#E3F2FD',
      'history_reason': '#9A6700',
      'log_info': '#0D2B45',
      'log_success': '#1A7F37',
      'log_warning': '#9A6700',
      'log_error': '#CF222E',
      'log_debug': '#5A6B7A',
      'outcome_success': '#1A7F37',
      'outcome_failed': '#CF222E',
      'outcome_risk': '#9A6700',
      'outcome_unknown': '#666666',
      'outcome_skipped': '#5B7A99',
    },
  ),
  'sakura': AppPalette(
    id: 'sakura',
    name: '绯樱春信',
    seeds: const ThemeSeeds(
      lightAccent: Color(0xFFFF8FAB),
      darkAccent: Color(0xFFC2436B),
      companion: Color(0xFFFCE2E6),
      textSeed: Color(0xFF5C2E3E),
    ),
    hex: const {
      'window_bg': '#FFF5F7',
      'card_bg': '#FFFBFC',
      'card_border': '#F5C6D3',
      'accent': '#E85D8A',
      'accent_dark': '#C2436B',
      'text_dark': '#5C2E3E',
      'hint': '#A67C8A',
      'sidebar_bg': '#FCE2E6',
      'sidebar_card_bg': '#FFFFFF',
      'sidebar_card_border': '#F2B8C6',
      'sidebar_text': '#5C2E3E',
      'sidebar_hint': '#A67C8A',
      'hero_top': '#FF8FAB',
      'hero_bottom': '#E85D8A',
      'hero_border': '#FBD3DE',
      'hero_stat_dim': '#FFE4EC',
      'btn_top': '#FF8FAB',
      'btn_bottom': '#E85D8A',
      'btn_hover_top': '#FFA8BE',
      'btn_hover_bottom': '#F0739A',
      'btn_disabled_bg': '#F2D6DD',
      'btn_disabled_text': '#B89AA4',
      'entry_bg': '#FFFFFF',
      'entry_border': '#F2B8C6',
      'selection_bg': '#FFEDF1',
      'history_reason': '#9A6700',
      'log_info': '#5C2E3E',
      'log_success': '#1E8E4D',
      'log_warning': '#9A6700',
      'log_error': '#D92B4A',
      'log_debug': '#8A6A75',
      'outcome_success': '#1E8E4D',
      'outcome_failed': '#D92B4A',
      'outcome_risk': '#9A6700',
      'outcome_unknown': '#8A6A75',
      'outcome_skipped': '#A67C8A',
    },
  ),
  'mint': AppPalette(
    id: 'mint',
    name: '竹青雨霁',
    seeds: const ThemeSeeds(
      lightAccent: Color(0xFF4DBD8E),
      darkAccent: Color(0xFF157A52),
      companion: Color(0xFFD2EFE0),
      textSeed: Color(0xFF16382B),
    ),
    hex: const {
      'window_bg': '#EAF7F1',
      'card_bg': '#F8FDFB',
      'card_border': '#C2E8D5',
      'accent': '#1E9E6A',
      'accent_dark': '#157A52',
      'text_dark': '#16382B',
      'hint': '#5A8570',
      'sidebar_bg': '#D2EFE0',
      'sidebar_card_bg': '#FFFFFF',
      'sidebar_card_border': '#A8DCC2',
      'sidebar_text': '#16382B',
      'sidebar_hint': '#5A8570',
      'hero_top': '#4DBD8E',
      'hero_bottom': '#1E9E6A',
      'hero_border': '#C8EBDA',
      'hero_stat_dim': '#DFF5EA',
      'btn_top': '#4DBD8E',
      'btn_bottom': '#1E9E6A',
      'btn_hover_top': '#66CFA4',
      'btn_hover_bottom': '#28B57E',
      'btn_disabled_bg': '#D3E8DD',
      'btn_disabled_text': '#8AA795',
      'entry_bg': '#FFFFFF',
      'entry_border': '#A8DCC2',
      'selection_bg': '#E6F7EE',
      'history_reason': '#9A6700',
      'log_info': '#16382B',
      'log_success': '#157A52',
      'log_warning': '#9A6700',
      'log_error': '#CF222E',
      'log_debug': '#5A8570',
      'outcome_success': '#157A52',
      'outcome_failed': '#CF222E',
      'outcome_risk': '#9A6700',
      'outcome_unknown': '#666666',
      'outcome_skipped': '#5A8570',
    },
  ),
  'violet': AppPalette(
    id: 'violet',
    name: '紫陌烟岚',
    seeds: const ThemeSeeds(
      lightAccent: Color(0xFF9B72D0),
      darkAccent: Color(0xFF5E34A0),
      companion: Color(0xFFE2D8F5),
      textSeed: Color(0xFF2E1F4A),
    ),
    hex: const {
      'window_bg': '#F1EDFA',
      'card_bg': '#FBF9FE',
      'card_border': '#D9CFF0',
      'accent': '#7C4DBE',
      'accent_dark': '#5E34A0',
      'text_dark': '#2E1F4A',
      'hint': '#7A6A9A',
      'sidebar_bg': '#E2D8F5',
      'sidebar_card_bg': '#FFFFFF',
      'sidebar_card_border': '#C9B8E8',
      'sidebar_text': '#2E1F4A',
      'sidebar_hint': '#7A6A9A',
      'hero_top': '#9B72D0',
      'hero_bottom': '#7C4DBE',
      'hero_border': '#DDD2F2',
      'hero_stat_dim': '#EDE7FA',
      'btn_top': '#9B72D0',
      'btn_bottom': '#7C4DBE',
      'btn_hover_top': '#B08AE0',
      'btn_hover_bottom': '#8E5ED0',
      'btn_disabled_bg': '#DCD5EC',
      'btn_disabled_text': '#9A8FB5',
      'entry_bg': '#FFFFFF',
      'entry_border': '#C9B8E8',
      'selection_bg': '#F0EAF9',
      'history_reason': '#9A6700',
      'log_info': '#2E1F4A',
      'log_success': '#1E8E4D',
      'log_warning': '#9A6700',
      'log_error': '#CF222E',
      'log_debug': '#7A6A9A',
      'outcome_success': '#1E8E4D',
      'outcome_failed': '#CF222E',
      'outcome_risk': '#9A6700',
      'outcome_unknown': '#7A6A9A',
      'outcome_skipped': '#7A6A9A',
    },
  ),
};

/// All six themes in display order (§9).
List<AppPalette> get allPalettes =>
    ['day', 'night', 'blue', 'sakura', 'mint', 'violet']
        .map((id) => _palettes[id]!)
        .toList(growable: false);

/// Palette for [id]; unknown ids fall back to `day` (§9, §2 rule 10).
AppPalette paletteFor(String id) => _palettes[id] ?? _palettes['day']!;

/// Chinese display name for a theme id; unknown ids show as `day`.
String themeDisplayName(String id) => paletteFor(id).name;

/// The user-approved final theme (§9): sakura. The config default is
/// still `day` (§2); the UI offers sakura as the recommended pick.
const String recommendedThemeId = 'sakura';
