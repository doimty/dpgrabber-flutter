/// Shared UI pieces: cards, section titles, outcome chips, number
/// fields. All colours come from the active palette — nothing is
/// hardcoded here.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/palette.dart';
import '../wenxi_ui/app_switch.dart';
import '../wenxi_ui/liquid_glass.dart';
import 'app_state.dart';

/// A themed card — a wenxi liquid-glass surface (16px radius). The
/// glass style follows the MaterialApp's [AppAppearance] (wired from
/// the glass settings); colours keep coming from the active palette.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: LiquidGlassSurface(
        // Grouped-card radius (design reference: 16).
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Section title inside a page.
class SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const SectionTitle(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    return Padding(
      // Section label sits slightly indented from the card edge
      // (design reference: left 4, bottom 10).
      padding: const EdgeInsets.only(top: 20, bottom: 10, left: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.textDark,
              ),
            ),
          ),
          trailing ?? const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// History outcome chip (§10.6): label + palette `outcome_*` colour.
class OutcomeChip extends StatelessWidget {
  final HistoryOutcome outcome;

  const OutcomeChip(this.outcome, {super.key});

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    final color = palette.outcomeColor(outcome.name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        outcomeLabel(outcome.name),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A labelled text field (label + hint + units in the label, per the
/// PC UI rule that every field states its purpose and units).
///
/// Auto-save commit: [onSubmitted] fires both when the user submits
/// (keyboard Done) and when the field loses focus (tap elsewhere) —
/// never per keystroke, so intermediate text (`""` → `"0"` → `"0."`)
/// is never written. [errorText] shows an inline validation error
/// under the field.
class LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType keyboardType;
  final bool obscureText;
  final int maxLines;
  final bool enabled;
  final List<TextInputFormatter>? inputFormatters;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;
  final String? errorText;
  final Widget? suffixIcon;

  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType = TextInputType.text,
    this.obscureText = false,
    this.maxLines = 1,
    this.enabled = true,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: palette.textDark, fontSize: 13)),
          const SizedBox(height: 4),
          Focus(
            // Blur commits: the Focus ancestor loses focus when the
            // inner TextField does (tap outside, switch toggle, ...).
            onFocusChange: (hasFocus) {
              if (!hasFocus) onSubmitted?.call(controller.text);
            },
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              obscureText: obscureText,
              maxLines: maxLines,
              minLines: maxLines > 1 ? 3 : null,
              enabled: enabled,
              inputFormatters: inputFormatters,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              decoration: InputDecoration(
                hintText: hint,
                suffixIcon: suffixIcon,
                errorText: errorText,
                errorStyle: TextStyle(
                  color: palette.logError,
                  fontSize: 12,
                ),
              ),
              style: TextStyle(color: palette.textDark),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled switch row.
class SwitchRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SwitchRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: palette.textDark, fontSize: 14),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(color: palette.hint, fontSize: 12),
                  ),
              ],
            ),
          ),
          // Wenxi's own switch (52x32, spring thumb) instead of the
          // Material Switch: the Material track/thumb reads Android-ish
          // on iOS.
          AppSwitch(
            value: value,
            onChanged: onChanged,
            semanticLabel: label,
          ),
        ],
      ),
    );
  }
}

/// A labelled checkbox row.
class CheckRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool?> onChanged;

  const CheckRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // Rounded iOS-style checkbox instead of the square Material
          // one; the checked fill follows the palette accent.
          CupertinoCheckbox(
            value: value,
            onChanged: onChanged,
            activeColor: palette.accent,
            semanticLabel: label,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: palette.textDark, fontSize: 14),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(color: palette.hint, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled number field with +/- steppers (PC DoubleSpin parity).
class NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String suffix;
  final double step;
  final ValueChanged<double>? onStep;

  const NumberField({
    super.key,
    required this.label,
    required this.controller,
    this.suffix = '',
    this.step = 1,
    this.onStep,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: palette.textDark, fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    hintText: suffix.isEmpty ? null : '单位：$suffix',
                  ),
                  style: TextStyle(color: palette.textDark),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '减少 $step$suffix',
                onPressed: () => _bump(-step),
                icon: const Icon(Icons.remove),
              ),
              IconButton(
                tooltip: '增加 $step$suffix',
                onPressed: () => _bump(step),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _bump(double delta) {
    final current = double.tryParse(controller.text.trim()) ?? 0;
    final next = current + delta;
    controller.text = next.toStringAsFixed(
      step < 1 ? 2 : 0,
    );
    onStep?.call(next);
  }
}

/// Error banner with explicit colours (never relies on global tinting).
class ErrorBanner extends StatelessWidget {
  final String message;

  const ErrorBanner(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final palette = _paletteOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: palette.logError.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kInputRadius),
        border: Border.all(color: palette.logError.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        style: TextStyle(color: palette.logError, fontSize: 13),
      ),
    );
  }
}

AppPalette _paletteOf(BuildContext context) =>
    _stateOf(context).theme.palette;

AppState _stateOf(BuildContext context) {
  // Pages receive AppState through the widget tree via an inherited
  // notifier installed by AppShell / DpgApp; see navigation.dart.
  final scope =
      context.dependOnInheritedWidgetOfExactType<AppStateScope>();
  assert(scope != null, 'AppStateScope missing above this widget');
  return scope!.state;
}

/// Inherited holder for the app state, so pages can read the palette
/// and glass settings without threading parameters everywhere.
class AppStateScope extends InheritedWidget {
  final AppState state;

  const AppStateScope({super.key, required this.state, required super.child});

  @override
  bool updateShouldNotify(AppStateScope oldWidget) =>
      state != oldWidget.state;
}
