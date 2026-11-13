import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../../models/song.dart';
import '../../../services/app_settings.dart';
import '../../../services/audio_handler.dart';
import '../../../services/storage_service.dart';
import '../../theme/app_ambience.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import '../favorite_button.dart';
import 'player_style.dart';

/// Title and artist of the track, where it plays from ("YouTube (HLS)",
/// "file locale") and the favourite button.
class PlayerTitleRow extends StatelessWidget {
  const PlayerTitleRow({
    super.key,
    required this.audioHandler,
    required this.mediaItem,
    required this.palette,
    required this.onArtist,
  });

  final AudioPlayerHandler audioHandler;
  final MediaItem mediaItem;
  final AmbientPalette palette;
  final VoidCallback onArtist;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    // Redrawn when the user changes how the title is shown.
    return ListenableBuilder(
      listenable: Listenable.merge([settings.playerTitleCentered, settings.playerShowSource]),
      builder: (context, _) => _row(
        context,
        centered: settings.playerTitleCentered.value,
        showSource: settings.playerShowSource.value,
      ),
    );
  }

  Widget _row(BuildContext context, {required bool centered, required bool showSource}) {
    final quiet = playerInk.withValues(alpha: 0.72);
    return Row(
      children: [
        // As wide as the heart on the other side: the title stays in the
        // middle of the screen.
        if (centered) const SizedBox(width: AppSpacing.sm + 44),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) =>
                Stack(
              alignment: centered ? Alignment.center : Alignment.centerLeft,
              children: [
                ...previousChildren,
                ?currentChild,
              ],
            ),
            child: Column(
              key: ValueKey('player_title_${mediaItem.id}'),
              crossAxisAlignment:
                  centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mediaItem.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: playerInk,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment:
                      centered ? MainAxisAlignment.center : MainAxisAlignment.start,
                  children: [
                    ValueListenableBuilder<List<Song>>(
                      valueListenable:
                          StorageService.instance.downloadsNotifier,
                      builder: (context, _, _) => StorageService
                              .instance
                              .isDownloaded(mediaItem.id)
                          ? Padding(
                              padding:
                                  const EdgeInsets.only(right: 6),
                              child: Icon(AppIcons.downloaded,
                                  size: 17, color: palette.accent),
                            )
                          : const SizedBox.shrink(),
                    ),
                    Flexible(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onArtist,
                        child: Text(
                          mediaItem.artist ?? 'Artista',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, color: quiet),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                // Sorgente della riproduzione: "YouTube (HLS)", "file locale"
                ValueListenableBuilder<String?>(
                  valueListenable: audioHandler.sourceNotifier,
                  builder: (context, source, _) {
                    final label = showSource ? (source?.trim() ?? '') : '';
                    if (label.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: quiet,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FavoriteButton(
          song: () => audioHandler.currentSong,
          activeColor: palette.accent,
          size: 28,
          source: 'player',
        ),
      ],
    );
  }
}
