import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';
import '../theme/element_scale.dart';

/// Consistent section header used across Home, Search and Library.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  /// Replaces the padding below, margins included.
  final EdgeInsetsGeometry? padding;

  /// The space above the title; the one chosen between sections when null
  /// (`PageSpacing.sectionGap`).
  final double? top;

  /// The space under the title.
  final double bottom;

  const SectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.padding,
    this.top,
    this.bottom = AppSpacing.md,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The side margin and the space between sections the user chose.
    final margin = PageSpacing.margin;
    return Padding(
      padding: padding ??
          EdgeInsets.fromLTRB(margin, top ?? PageSpacing.sectionGap, margin, bottom),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.sectionTitle(cs),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
