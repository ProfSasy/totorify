import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'top_bar.dart';

/// Top of a collection page: the artwork over a wash of its own color,
/// which fades into the page, and under it whatever describes the
/// collection. The artwork shrinks and fades as the page scrolls.
class CollectionHeader extends StatelessWidget {
  const CollectionHeader({
    super.key,
    required this.palette,
    required this.scrollOffset,
    required this.artwork,
    required this.child,
  });

  /// Side of the artwork: large, but never so large that the title and the
  /// play button leave the first screen.
  static double artworkSize(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return math.min(math.min(size.width * 0.6, size.height * 0.3), 260);
  }

  final AmbientPalette palette;
  final ValueListenable<double> scrollOffset;
  final Widget artwork;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = artworkSize(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Above the page: seen when the list is pulled down past its top.
        Positioned(
          left: 0,
          right: 0,
          top: -700,
          height: 700,
          child: AnimatedContainer(
            duration: AppMotion.ambience,
            color: palette.surface,
          ),
        ),
        Positioned.fill(
          child: AnimatedContainer(
            duration: AppMotion.ambience,
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [palette.surface, palette.surface.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            TopBar.extent(context) + AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ValueListenableBuilder<double>(
                  valueListenable: scrollOffset,
                  builder: (context, offset, artwork) {
                    final t = (offset / size).clamp(0.0, 1.0);
                    return Opacity(
                      opacity: 1 - t,
                      child: Transform.scale(
                        scale: 1 - 0.22 * t,
                        alignment: Alignment.bottomCenter,
                        child: artwork,
                      ),
                    );
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 32,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: artwork,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              child,
            ],
          ),
        ),
      ],
    );
  }
}

/// Bar pinned over a collection page: the back button, and the title and a
/// surface in the collection's color once its header has scrolled away.
class CollectionTopBar extends StatelessWidget {
  const CollectionTopBar({
    super.key,
    required this.title,
    required this.palette,
    required this.scrollOffset,
    this.actions = const [],
    this.revealAt,
    this.scrim = false,
  });

  final String title;
  final AmbientPalette palette;
  final ValueListenable<double> scrollOffset;
  final List<Widget> actions;

  /// Scroll offset at which the bar becomes solid. Defaults to where the
  /// artwork of a [CollectionHeader] has gone.
  final double? revealAt;

  /// Puts a dark disc behind the back button, for headers that are a
  /// picture.
  final bool scrim;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final start = revealAt ?? CollectionHeader.artworkSize(context) - AppSpacing.md;
    final surface = Color.lerp(palette.surface, cs.surfaceDim, 0.4)!;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<double>(
        valueListenable: scrollOffset,
        builder: (context, offset, _) {
          final t = ((offset - start) / 40).clamp(0.0, 1.0);
          return Container(
            color: surface.withValues(alpha: t),
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: SizedBox(
              height: TopBar.height,
              child: Row(
                children: [
                  const SizedBox(width: AppSpacing.xs),
                  IconButton(
                    tooltip: 'Indietro',
                    style: scrim
                        ? IconButton.styleFrom(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.45 * (1 - t)),
                          )
                        : null,
                    icon: Icon(AppIcons.back, size: 20, color: cs.onSurface),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  Expanded(
                    child: Opacity(
                      opacity: t,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileTitle(cs).copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  ...actions,
                  const SizedBox(width: AppSpacing.xs),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
