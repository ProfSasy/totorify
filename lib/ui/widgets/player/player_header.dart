import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../../../models/song.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import 'player_style.dart';

/// The bar on top of the player: close (or back to the player from the
/// lyrics and the queue), what is on screen, and the menu of the song.
class PlayerHeader extends StatelessWidget {
  const PlayerHeader({
    super.key,
    required this.tabIndex,
    required this.currentSong,
    required this.mediaItem,
    required this.onBackToPlayer,
    required this.onMenu,
  });

  /// 0 for the player, 1 for the lyrics, 2 for the queue.
  final int tabIndex;
  final Song? currentSong;
  final MediaItem mediaItem;
  final VoidCallback onBackToPlayer;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final onMainTab = tabIndex == 0;
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            tooltip: onMainTab ? 'Chiudi player' : 'Torna al player',
            icon: Icon(
              onMainTab ? AppIcons.collapse : AppIcons.back,
              color: playerInk,
              size: onMainTab ? 32 : 20,
            ),
            onPressed: () {
              if (onMainTab) {
                Navigator.maybePop(context);
              } else {
                onBackToPlayer();
              }
            },
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  tabIndex == 1
                      ? 'TESTO'
                      : tabIndex == 2
                          ? 'CODA'
                          : 'IN RIPRODUZIONE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                    color: playerInk.withValues(alpha: 0.72),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  onMainTab
                      ? ((currentSong?.album?.isNotEmpty ?? false)
                          ? currentSong!.album!
                          : (mediaItem.artist ?? 'Totorify'))
                      : mediaItem.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: playerInk,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Altre opzioni',
            icon: const Icon(AppIcons.more, color: playerInk, size: 26),
            onPressed: onMenu,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
    );
  }
}
