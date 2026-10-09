import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';

/// Floating glass tab bar. The active item expands into a glowing capsule
/// (icon + label); inactive items stay icon-only, so the bar stays calm while
/// the current section is unmistakable.
class TotorifyNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const TotorifyNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  /// Total height of the bar, safe area included. MainShell uses this to
  /// float the mini player right above it.
  static double totalHeight(BuildContext context) =>
      66 + MediaQuery.paddingOf(context).bottom;

  static const List<_NavItemData> _items = [
    _NavItemData(
      icon: CupertinoIcons.house,
      activeIcon: CupertinoIcons.house_fill,
      label: 'Home',
    ),
    _NavItemData(
      icon: CupertinoIcons.search,
      activeIcon: CupertinoIcons.search,
      label: 'Cerca',
    ),
    _NavItemData(
      icon: CupertinoIcons.music_albums,
      activeIcon: CupertinoIcons.music_albums_fill,
      label: 'Libreria',
    ),
    _NavItemData(
      icon: CupertinoIcons.gear_alt,
      activeIcon: CupertinoIcons.gear_alt_fill,
      label: 'Impostazioni',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.floating,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 58,
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.72),
              borderRadius: AppRadius.floating,
              border: Border.all(
                color: cs.onSurface.withValues(alpha: 0.08),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.38),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                for (var i = 0; i < _items.length; i++)
                  _NavItem(
                    data: _items[i],
                    selected: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItemData {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItemData({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class _NavItem extends StatelessWidget {
  final _NavItemData data;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: data.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (!selected) HapticFeedback.selectionClick();
            onTap();
          },
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.base,
              curve: AppMotion.standard,
              padding: EdgeInsets.symmetric(
                horizontal: selected ? 14 : 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? cs.primary.withValues(alpha: 0.16)
                    : Colors.transparent,
                borderRadius: AppRadius.chip,
                border: Border.all(
                  color: selected
                      ? cs.primary.withValues(alpha: 0.45)
                      : Colors.transparent,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? data.activeIcon : data.icon,
                    size: 20,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  // The label grows under the active icon, capsule-style.
                  AnimatedSize(
                    duration: AppMotion.base,
                    curve: AppMotion.standard,
                    alignment: Alignment.topCenter,
                    child: selected
                        ? Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              data.label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: cs.primary,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
