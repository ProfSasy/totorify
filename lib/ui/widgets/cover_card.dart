import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'app_cover.dart';
import 'bounce_button.dart';

/// Artwork with a title and a line or two under it: the card of the
/// horizontal rows and of the grids (playlists, albums, artists, mixes).
class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.size = 140,
    this.subtitleLines = 1,
    this.circle = false,
    this.icon = AppIcons.note,
    this.badge,
    this.busy = false,
    this.cover,
  });

  /// Height of a card of [size], at the largest text size the app allows.
  static double heightFor(double size, {int subtitleLines = 1}) =>
      size + 32 + 19.0 * subtitleLines;

  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double size;
  final int subtitleLines;

  /// Round artwork and centered text: an artist.
  final bool circle;
  final IconData icon;

  /// Small label over the top-left corner of the artwork.
  final String? badge;

  /// Shows a spinner over the artwork while what the card opens is loading.
  final bool busy;

  /// Replaces the artwork read from [imageUrl].
  final Widget? cover;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final align = circle ? TextAlign.center : TextAlign.start;
    return BounceButton(
      onPressed: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment:
              circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                cover ??
                    AppCover(
                      url: imageUrl,
                      size: size,
                      circle: circle,
                      radius: AppRadius.sm,
                      icon: icon,
                    ),
                if (badge != null)
                  Positioned(
                    left: 0,
                    top: AppSpacing.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: cs.primary,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(AppRadius.xs),
                        ),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          color: cs.onPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                if (busy)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: circle ? BoxShape.circle : BoxShape.rectangle,
                        borderRadius:
                            circle ? null : BorderRadius.circular(AppRadius.sm),
                      ),
                      child: const CupertinoActivityIndicator(color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: align,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.25,
                color: cs.onSurface,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                subtitle!,
                maxLines: subtitleLines,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: AppText.caption(cs).copyWith(height: 1.3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
