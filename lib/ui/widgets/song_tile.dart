import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../main.dart';
import '../../models/song.dart';
import '../../services/playback_log_service.dart';
import '../../services/download_service.dart';
import '../../services/spotify_service.dart';
import '../../services/storage_service.dart';
import '../screens/artist_screen.dart';
import '../theme/app_tokens.dart';
import 'alternative_sources_sheet.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onMoreTap;

  const SongTile({
    super.key,
    required this.song,
    this.isPlaying = false,
    required this.onTap,
    this.onMoreTap,
  });

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    String thumbUrl = song.thumbnailUrl;
    if (song.spotifyTrackId != null &&
        (thumbUrl.contains('charts-images.scdn.co') || thumbUrl.isEmpty)) {
      final cached = SpotifyService.instance.getCachedCover(song.spotifyTrackId!);
      if (cached != null) {
        thumbUrl = cached;
      }
    }

    return RepaintBoundary(
      child: InkWell(
        onTap: () {
          PlaybackLogService.instance.log('UI', 'tile: play "${song.title}"');
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        splashColor: primaryColor.withValues(alpha: 0.08),
        highlightColor: primaryColor.withValues(alpha: 0.04),
            child: AnimatedContainer(
              duration: AppMotion.base,
              curve: AppMotion.standard,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isPlaying
                    ? primaryColor.withValues(alpha: 0.07)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                children: [
                  // ── Thumbnail ──────────────────────────────────────────────
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        CachedNetworkImage(
                          imageUrl: thumbUrl,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          memCacheWidth: 160,
                          memCacheHeight: 160,
                          maxWidthDiskCache: 320,
                          maxHeightDiskCache: 320,
                          fadeInDuration: const Duration(milliseconds: 150),
                          placeholder: (ctx, url) => Container(
                            width: 52,
                            height: 52,
                            color: Theme.of(context).colorScheme.surface,
                            child: Icon(CupertinoIcons.music_note,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                          errorWidget: (ctx, url, err) => Container(
                            width: 52,
                            height: 52,
                            color: Theme.of(context).colorScheme.surface,
                            child: Icon(CupertinoIcons.music_note,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                        // Animated playing indicator overlay
                        if (isPlaying)
                          Container(
                            width: 52,
                            height: 52,
                            color: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.55),
                            child: _PlayingBars(color: primaryColor),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),

                  // ── Title & Artist ─────────────────────────────────────────
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.tileTitle(
                            Theme.of(context).colorScheme,
                          ).copyWith(
                            fontWeight:
                                isPlaying ? FontWeight.bold : FontWeight.w600,
                            color: isPlaying
                                ? primaryColor
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            _SongDownloadBadge(
                              songId: song.id,
                              primaryColor: primaryColor,
                            ),
                            Expanded(
                              child: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.tileSubtitle(
                                  Theme.of(context).colorScheme,
                                ),
                              ),
                            ),
                            // Duration — hide if zero
                            if (song.duration > Duration.zero)
                              Text(
                                _formatDuration(song.duration),
                                style: AppText.caption(
                                  Theme.of(context).colorScheme,
                                ).copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),

                  // ── More Options ───────────────────────────────────────────
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: Icon(CupertinoIcons.ellipsis,
                        size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    onPressed: () {
                      PlaybackLogService.instance
                          .log('UI', 'tile: menu "${song.title}"');
                      if (onMoreTap != null) {
                        onMoreTap!();
                      } else {
                        _showSongOptionsModal(context);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        );
  }

  void _showSongOptionsModal(BuildContext context) {
    final isDown = StorageService.instance.isDownloaded(song.id);
    final isFav = StorageService.instance.isFavorite(song.id);
    final primaryColor = Theme.of(context).colorScheme.primary;
    // Taken now: the row can leave the screen before an action is chosen.
    final messenger = ScaffoldMessenger.of(context);
    final snackColor = Theme.of(context).colorScheme.surface;

    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        message: Text(song.artist, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        actions: [
          // 1. Preferiti
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance
                  .log('UI', 'tile menu: preferito "${song.title}"');
              StorageService.instance.toggleFavorite(song);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isFav ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                  color: isFav ? primaryColor : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(isFav ? 'Rimuovi dai Preferiti' : 'Aggiungi ai Preferiti'),
              ],
            ),
          ),

          // 2. Aggiungi alla coda
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance
                  .log('UI', 'tile menu: aggiungi alla coda "${song.title}"');
              audioHandler.addToQueue(song);
              messenger.showSnackBar(
                SnackBar(
                  content: Text('Aggiunto alla coda: ${song.title}'),
                  backgroundColor: snackColor,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.text_badge_plus, color: Theme.of(context).colorScheme.onSurfaceVariant),
                SizedBox(width: 8),
                Text('Aggiungi alla Coda'),
              ],
            ),
          ),

          // 3. Riproduci come prossimo
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance
                  .log('UI', 'tile menu: play next "${song.title}"');
              audioHandler.playNext(song);
              messenger.showSnackBar(
                SnackBar(
                  content: Text('Verrà riprodotto dopo: ${song.title}'),
                  backgroundColor: snackColor,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.play_arrow, color: Theme.of(context).colorScheme.onSurfaceVariant),
                SizedBox(width: 8),
                Text('Riproduci come Prossimo'),
              ],
            ),
          ),

          // Vai all'artista
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance
                  .log('UI', 'tile menu: vai all\'artista "${song.artist}"');
              ArtistScreen.open(context, audioHandler, song: song);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.person_crop_circle, color: Theme.of(context).colorScheme.onSurfaceVariant),
                SizedBox(width: 8),
                Text('Vai all\'Artista'),
              ],
            ),
          ),

          // 4. Aggiungi a una Playlist
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance
                  .log('UI', 'tile menu: aggiungi a playlist "${song.title}"');
              _showAddToPlaylistDialog(context);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.music_albums, color: Theme.of(context).colorScheme.onSurfaceVariant),
                SizedBox(width: 8),
                Text('Aggiungi a una Playlist'),
              ],
            ),
          ),

          // 5. Download Offline
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance.log(
                'UI',
                isDown
                    ? 'tile menu: elimina download "${song.title}"'
                    : 'tile menu: scarica "${song.title}"',
              );
              if (isDown) {
                DownloadService.instance.deleteDownloadedSong(song.id);
              } else {
                DownloadService.instance.downloadSong(song);
              }
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isDown ? CupertinoIcons.trash : CupertinoIcons.arrow_down_circle,
                  color: isDown ? Theme.of(context).colorScheme.error : primaryColor,
                ),
                const SizedBox(width: 8),
                Text(
                  isDown
                      ? 'Elimina Download Offline'
                      : 'Scarica per Ascolto Offline',
                  style: TextStyle(color: isDown ? Theme.of(context).colorScheme.error : null),
                ),
              ],
            ),
          ),

          // 6. Fonti audio alternative
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              AlternativeSourcesSheet.show(
                context,
                song: song,
                audioHandler: audioHandler,
              );
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.tuningfork, color: Theme.of(context).colorScheme.onSurfaceVariant),
                SizedBox(width: 8),
                Text('Fonti audio alternative'),
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Annulla'),
        ),
      ),
    );
  }

  void _showAddToPlaylistDialog(BuildContext context) {
    final playlists = StorageService.instance.getPlaylists();
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nessuna playlist creata. Creane una in Libreria!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Scegli Playlist'),
        actions: playlists.map((pl) {
          return CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              PlaybackLogService.instance.log(
                  'UI', 'tile menu: aggiungo a "${pl.title}"');
              StorageService.instance.addSongToPlaylist(pl.id, song);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Aggiunto a "${pl.title}"'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: Text(pl.title),
          );
        }).toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Annulla'),
        ),
      ),
    );
  }
}

class _SongDownloadBadge extends StatelessWidget {
  final String songId;
  final Color primaryColor;

  const _SongDownloadBadge({
    required this.songId,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: DownloadService.instance.downloadProgressNotifier,
      builder: (context, progressMap, _) {
        final progress = progressMap[songId];
        if (progress != null) {
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                value: progress > 0.05 ? progress : null,
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
              ),
            ),
          );
        }
        return ValueListenableBuilder<List<Song>>(
          valueListenable: StorageService.instance.downloadsNotifier,
          builder: (context, _, _) {
            if (StorageService.instance.isDownloaded(songId)) {
              return Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  CupertinoIcons.arrow_down_circle_fill,
                  size: 13,
                  color: primaryColor,
                ),
              );
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}

/// Three animated equalizer bars shown while the row's song is playing.
class _PlayingBars extends StatefulWidget {
  final Color color;

  const _PlayingBars({required this.color});

  @override
  State<_PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<_PlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List<Widget>.generate(3, (i) {
            final phase = (_controller.value + i * 0.28) % 1.0;
            final wave = (math.sin(phase * 2 * math.pi) + 1) / 2;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 3,
                height: 6 + 13 * wave,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
