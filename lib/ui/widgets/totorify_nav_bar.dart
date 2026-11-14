import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_settings.dart';
import '../ordered_choice.dart';
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

  // By name (`NavLayout`), with the position the shell knows each by.
  static const Map<String, (NavGlyph, String, int)> _items = {
    NavLayout.home: (NavGlyph.home, 'Home', 0),
    NavLayout.search: (NavGlyph.search, 'Cerca', 1),
    NavLayout.library: (NavGlyph.library, 'La tua libreria', 2),
    // Not a tab: it opens the menu to create or import, as Spotify's.
    NavLayout.create: (NavGlyph.create, 'Crea', createIndex),
  };

  /// Position of "Crea" among the items.
  static const int createIndex = 3;

  @override
  Widget build(BuildContext context) {
    // Read with the theme, which is made again when the user changes the
    // tabs: the bar is then drawn again.
    Theme.of(context);
    final look = AppSettings.instance;
    final tabs = NavLayout.tabs.visible(look.navTabs.value, look.navHiddenTabs.value);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: SizedBox(
        height: _barHeight,
        child: Row(
          children: [
            for (final (glyph, label, index) in [for (final id in tabs) _items[id]!])
              _NavItem(
                glyph: glyph,
                label: label,
                selected: index == currentIndex,
                showLabel: look.navShowLabels.value,
                activeStyle: look.navActiveStyle.value,
                onTap: () => onTap(index),
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
  final bool showLabel;

  /// The tab one is on: 0 brighter, 1 in the color of the app, 2 in a pill.
  final int activeStyle;
  final VoidCallback onTap;

  const _NavItem({
    required this.glyph,
    required this.label,
    required this.selected,
    required this.showLabel,
    required this.activeStyle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = !selected
        ? cs.onSurfaceVariant
        : (activeStyle == 1 ? cs.primary : cs.onSurface);
    final pill = selected && activeStyle == 2;
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
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: EdgeInsets.symmetric(horizontal: pill ? 16 : 0, vertical: pill ? 3 : 0),
                  decoration: BoxDecoration(
                    color: pill ? cs.primary.withValues(alpha: 0.26) : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: NavGlyphIcon(glyph: glyph, active: selected, color: color),
                ),
              ),
              if (showLabel) ...[
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
            ],
          ),
        ),
      ),
    );
  }
}
