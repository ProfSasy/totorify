import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';

/// Tab bar of the app: three glyphs with their labels. It has no surface of
/// its own; the shell fades the content to black underneath it.
class TotorifyNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const TotorifyNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const double _barHeight = 56;

  /// Total height of the bar, safe area included. MainShell uses this to
  /// float the mini player right above it.
  static double totalHeight(BuildContext context) =>
      _barHeight + MediaQuery.paddingOf(context).bottom;

  static const List<(NavGlyph, String)> _items = [
    (NavGlyph.home, 'Home'),
    (NavGlyph.search, 'Cerca'),
    (NavGlyph.library, 'La tua libreria'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: SizedBox(
        height: _barHeight,
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              _NavItem(
                glyph: _items[i].$1,
                label: _items[i].$2,
                selected: i == currentIndex,
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final NavGlyph glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.glyph,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = selected ? cs.onSurface : cs.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (!selected) HapticFeedback.selectionClick();
            onTap();
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: selected ? 1.0 : 0.94,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutBack,
                child: NavGlyphIcon(glyph: glyph, active: selected, color: color),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
