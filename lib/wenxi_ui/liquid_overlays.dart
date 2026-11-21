import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'liquid_bottom_navigation.dart';
import 'liquid_glass.dart';

const _overlayRadius = BorderRadius.all(Radius.circular(28));

Color _scrimColor(BuildContext context) => Colors.black.withValues(
  alpha: Theme.of(context).brightness == Brightness.dark ? .46 : .28,
);

/// A sheet with a shared glass surface, while Flutter owns the modal route,
/// drag dismissal and focus. The builder receives a context inside the route.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  String? title,
  WidgetBuilder? headerBuilder,
  required WidgetBuilder builder,
  bool scrollControlled = false,
}) {
  assert((title == null) != (headerBuilder == null));
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: scrollControlled,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    barrierColor: _scrimColor(context),
    constraints: const BoxConstraints(maxWidth: 500),
    builder: (context) => AnimatedPadding(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: _GlassOverlaySurface(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final header = headerBuilder == null
                  ? GlassSheetHeader(title: title!)
                  : Builder(builder: headerBuilder);
              final body = Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                child: Material(
                  type: MaterialType.transparency,
                  child: Builder(builder: builder),
                ),
              );
              // In landscape with the keyboard open there may be almost no
              // height left. Let the header scroll with the form in that case.
              final compact = constraints.maxHeight < 144;
              return compact
                  ? SingleChildScrollView(
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [header, body],
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        Flexible(
                          child: SingleChildScrollView(
                            primary: false,
                            child: body,
                          ),
                        ),
                      ],
                    );
            },
          ),
        ),
      ),
    ),
  );
}

class GlassActionTile extends StatelessWidget {
  const GlassActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: Icon(icon, size: 20),
      title: Text(label),
      enabled: onTap != null,
      onTap: onTap,
    );
  }
}

class GlassSheetHeader extends StatelessWidget {
  const GlassSheetHeader({super.key, required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 9, 6, 4),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.onSurfaceVariant.withValues(alpha: .48),
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox(width: 30, height: 4),
          ),
          Row(
            children: [
              if (onBack != null)
                IconButton(
                  tooltip: '返回',
                  onPressed: onBack,
                  icon: const BackButtonIcon(),
                )
              else
                const SizedBox(width: 48),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GlassSelectionField<T extends Object> extends StatelessWidget {
  const GlassSelectionField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(12);
    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: radius,
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: () async {
            final next = await showGlassSelection<T>(
              context,
              title: label,
              selected: value,
              options: options,
            );
            if (context.mounted && next != null && next != value) {
              onSelected(next);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        options[value] ?? value.toString(),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.unfold_more_rounded,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showGlassSelection<T extends Object>(
  BuildContext context, {
  required String title,
  required T selected,
  required Map<T, String> options,
}) => showGlassSheet<T>(
  context,
  title: title,
  builder: (context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options.entries)
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            selected: option.key == selected,
            selectedTileColor: colors.primary.withValues(alpha: .10),
            selectedColor: colors.onSurface,
            title: Text(option.value),
            trailing: option.key == selected
                ? Icon(Icons.check_rounded, size: 20, color: colors.primary)
                : null,
            onTap: () => Navigator.of(context).pop(option.key),
          ),
      ],
    );
  },
);

Future<bool> showGlassConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: _scrimColor(context),
    builder: (context) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      return Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        constraints: const BoxConstraints(maxWidth: 400),
        child: _GlassOverlaySurface(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 4,
                    children: [
                      TextButton(
                        autofocus: true,
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurfaceVariant,
                        ),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: destructive
                              ? colors.error
                              : colors.primaryContainer,
                          foregroundColor: destructive
                              ? colors.onError
                              : colors.onPrimaryContainer,
                          shape: const StadiumBorder(),
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(confirmLabel),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  return result ?? false;
}

/// Keeps ScaffoldMessenger's queue, live-region announcement and swipe
/// dismissal, with the same material as the modal surfaces.
void showGlassMessage(
  BuildContext context,
  String message, {
  bool aboveBottomNavigation = false,
}) {
  final bottomOffset =
      aboveBottomNavigation &&
          MediaQuery.sizeOf(context).width < kFloatingNavBreakpoint
      ? bottomNavContentHeight(context) + 24
      : 0.0;
  final theme = Theme.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      margin: EdgeInsets.fromLTRB(12, 0, 12, 12 + bottomOffset),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: _GlassOverlaySurface(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _GlassOverlaySurface extends StatelessWidget {
  const _GlassOverlaySurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final appearance = AppAppearance.of(context);
    // A denser tint keeps text readable over any custom wallpaper. Keep
    // enough of the backdrop to show the lens and its edge in clear mode.
    return LiquidGlassSurface(
      borderRadius: _overlayRadius,
      opacity: appearance.glassLowPower
          ? .96
          : appearance.glassOpacity.clamp(.78, 1.0),
      refractionHeight: 18,
      refractionAmount: 20,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
