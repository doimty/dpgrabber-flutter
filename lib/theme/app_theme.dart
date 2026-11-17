/// [ThemeData] construction from a palette + theme switching.
///
/// Switching is instant: [ThemeController] is a [ValueNotifier] holding
/// the current theme id, and the app rebuilds its [ThemeData] from it.
/// Persistence (config `theme` key) is the caller's job — see
/// [ThemeController] docs and `AppState.setTheme`.
library;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'palette.dart';

/// Holds the current theme id. Unknown ids fall back to `day` on read
/// (contract §9 / §2 rule 10); [set] normalises before notifying so
/// listeners always see a valid id.
class ThemeController extends ValueNotifier<String> {
  ThemeController(String initialId) : super(paletteFor(initialId).id);

  AppPalette get palette => paletteFor(value);

  void set(String id) {
    final next = paletteFor(id).id;
    if (value != next) value = next;
  }
}

/// Build a [ThemeData] from [palette]. No colour is hardcoded here:
/// every colour comes from the palette.
ThemeData buildThemeData(AppPalette palette, {GlassSettings? glass}) {
  final brightness =
      palette.isDark ? Brightness.dark : Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.accent,
    brightness: brightness,
    primary: palette.accent,
    surface: palette.cardBg,
  );
  final textTheme = TextTheme(
    bodyMedium: TextStyle(color: palette.textDark),
    bodySmall: TextStyle(color: palette.hint),
    titleMedium: TextStyle(color: palette.textDark),
    titleLarge: TextStyle(color: palette.textDark),
    labelMedium: TextStyle(color: palette.textDark),
  );
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.windowBg,
    cardColor: palette.cardBg,
    dividerColor: palette.cardBorder,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.windowBg,
      foregroundColor: palette.textDark,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      toolbarHeight: 56,
      titleTextStyle: TextStyle(
        color: palette.textDark,
        fontSize: 17,
        fontWeight: FontWeight.w700,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // Borderless tinted well (design reference): the fill is the
      // card surface tinted a whisper toward the accent, so the field
      // reads inside white cards as well as on the window background.
      fillColor: mix(palette.cardBg, palette.accent, 0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(color: palette.accent, width: 1),
      ),
      hintStyle: TextStyle(color: palette.hint),
      labelStyle: TextStyle(color: palette.hint),
      contentPadding: const EdgeInsets.all(14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: palette.btnBottom,
        foregroundColor: Colors.white,
        disabledBackgroundColor: palette.btnDisabledBg,
        disabledForegroundColor: palette.btnDisabledText,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kButtonRadius),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kButtonRadius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.accent,
        side: BorderSide(color: palette.entryBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kButtonRadius),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent.withValues(alpha: 0.5)
            : null,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : null,
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : null,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
      ),
      // §10.1: dialog button colours must be explicit, never rely on
      // the global theme tinting (PC "white text on pale background").
      titleTextStyle: TextStyle(
        color: palette.textDark,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: TextStyle(color: palette.textDark, fontSize: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.accentDark,
      contentTextStyle: const TextStyle(color: Colors.white),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: palette.sidebarBg,
      selectedItemColor: palette.accent,
      unselectedItemColor: palette.sidebarHint,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.cardBg),
      ),
    ),
  );
}

/// Colour for a run-log level (§9 `log_*`).
Color logColor(AppPalette palette, String level) {
  switch (level) {
    case 'success':
      return palette.logSuccess;
    case 'warning':
      return palette.logWarning;
    case 'error':
      return palette.logError;
    case 'debug':
      return palette.logDebug;
    default:
      return palette.logInfo;
  }
}

/// Chinese label for a history outcome (§10.6).
String outcomeLabel(String outcome) {
  switch (outcome) {
    case 'success':
      return '成功';
    case 'failed':
      return '失败';
    case 'risk':
      return '风控';
    case 'unknown':
      return '未知';
    case 'skipped':
      return '跳过';
    default:
      return '未知';
  }
}
