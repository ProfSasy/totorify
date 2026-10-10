import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';

/// Opens a bottom sheet in the app's style, above the tabs and the player.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => SheetFrame(child: builder(sheetContext)),
  );
}

/// The surface of a sheet: rounded top, grab handle, content that scrolls
/// when it is taller than the screen allows, clear of the home indicator
/// and of the keyboard.
class SheetFrame extends StatelessWidget {
  const SheetFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
        // A Material of its own, so the rows can show their pressed state.
        child: Material(
          color: cs.surfaceContainerHigh,
          borderRadius: AppRadius.sheet,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    bottom: media.viewPadding.bottom + AppSpacing.md,
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title at the top of a sheet that has no artwork header.
class SheetTitle extends StatelessWidget {
  const SheetTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.sectionTitle(cs).copyWith(fontSize: 18)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: AppText.caption(cs)),
          ],
        ],
      ),
    );
  }
}

/// One action of a sheet: glyph, label, and optionally a second line or a
/// trailing widget.
class SheetAction extends StatelessWidget {
  const SheetAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.color,
    this.iconColor,
    this.leading,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  /// Color of the label (and of the glyph, unless [iconColor] is given).
  final Color? color;
  final Color? iconColor;

  /// Replaces the glyph (a cover, for instance).
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: 13),
        child: Row(
          children: [
            leading ??
                Icon(icon, size: 24, color: iconColor ?? color ?? cs.onSurfaceVariant),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                      color: color ?? cs.onSurface,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption(cs),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Lets the user pick one of [options]; resolves to the value picked, or
/// null when the sheet is dismissed.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<(T value, String label)> options,
  T? selected,
}) {
  return showAppSheet<T>(
    context,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle(title, subtitle: subtitle),
          for (final (value, label) in options)
            SheetAction(
              icon: value == selected ? AppIcons.radioOn : AppIcons.radioOff,
              iconColor: value == selected ? cs.primary : null,
              label: label,
              onTap: () => Navigator.pop(sheetContext, value),
            ),
        ],
      );
    },
  );
}
