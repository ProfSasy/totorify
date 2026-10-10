import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_icons.dart';

/// Heart of a song: follows the favourites, and pops when it is tapped.
class FavoriteButton extends StatelessWidget {
  const FavoriteButton({
    super.key,
    required this.song,
    required this.activeColor,
    this.size = 24,
    this.source = 'cuore',
  });

  /// Read when the button is built and when it is tapped, so it never acts
  /// on a stale song.
  final Song? Function() song;
  final Color activeColor;
  final double size;

  /// Where the button sits, for the log.
  final String source;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<Song>>(
      valueListenable: StorageService.instance.favoritesNotifier,
      builder: (context, _, _) {
        final current = song();
        final isFavorite =
            current != null && StorageService.instance.isFavorite(current.id);
        return IconButton(
          tooltip: isFavorite ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: size + 16, minHeight: size + 16),
          onPressed: () {
            final target = song();
            if (target == null) return;
            HapticFeedback.lightImpact();
            PlaybackLogService.instance.log('UI', '$source: preferito');
            StorageService.instance.toggleFavorite(target);
          },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              isFavorite ? AppIcons.heartFilled : AppIcons.heart,
              key: ValueKey<bool>(isFavorite),
              size: size,
              color: isFavorite ? activeColor : cs.onSurface,
            ),
          ),
        );
      },
    );
  }
}
