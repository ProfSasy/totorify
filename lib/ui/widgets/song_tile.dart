import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../main.dart';
import '../../models/song.dart';
import '../../services/playback_log_service.dart';
import '../../services/download_service.dart';
import '../../services/spotify_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'app_cover.dart';
import 'song_options_sheet.dart';

/// Row of a song in any list.
///
/// Tap plays it, the dots (or a long press) open its menu, and a swipe to
/// the right puts it in the queue. Where the list can lose songs
/// ([onRemove]), a swipe to the left removes it.
class SongTile extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final VoidCallback onTap;

  /// Position shown before the cover (the "popular" list of an artist).
  final int? index;

  /// Makes the row removable with a swipe to the left.
  final VoidCallback? onRemove;

  const SongTile({
    super.key,
    required this.song,
    this.isPlaying = false,
    required this.onTap,
    this.index,
    this.onRemove,
  });

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _openMenu(BuildContext context) {
    PlaybackLogService.instance.log('UI', 'tile: menu "${song.title}"');
    showSongOptions(context, song: song, audioHandler: audioHandler);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;

    String thumbUrl = song.thumbnailUrl;
    if (song.spotifyTrackId != null &&
        (thumbUrl.contains('charts-images.scdn.co') || thumbUrl.isEmpty)) {
      final cached = SpotifyService.instance.getCachedCover(song.spotifyTrackId!);
      if (cached != null) {
        thumbUrl = cached;
      }
    }

    final row = InkWell(
      onTap: () {
        PlaybackLogService.instance.log('UI', 'tile: play "${song.title}"');
        onTap();
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _openMenu(context);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 7, AppSpacing.xs, 7),
        child: Row(
          children: [
            if (index != null)
              SizedBox(
                width: 26,
                child: Text(
                  '$index',
                  style: AppText.tileSubtitle(cs).copyWith(
                    fontSize: 15,
                    color: isPlaying ? accent : cs.onSurfaceVariant,
                  ),
                ),
              ),

            // ── Thumbnail ──────────────────────────────────────────────
            Stack(
              children: [
                AppCover(url: thumbUrl, size: 50),
                if (isPlaying)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: AppRadius.cover,
                      ),
                      child: PlayingBars(color: accent),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: AppSpacing.md),

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
                    style: AppText.tileTitle(cs).copyWith(
                      color: isPlaying ? accent : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      _SongDownloadBadge(songId: song.id, color: accent),
                      Flexible(
                        child: Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.tileSubtitle(cs),
                        ),
                      ),
                      // Duration — hide if zero
                      if (song.duration > Duration.zero)
                        Text(
                          '  •  ${_formatDuration(song.duration)}',
                          style: AppText.tileSubtitle(cs),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            // ── More Options ───────────────────────────────────────────
            IconButton(
              tooltip: 'Altro',
              icon: Icon(AppIcons.more, size: 22, color: cs.onSurfaceVariant),
              onPressed: () => _openMenu(context),
            ),
          ],
        ),
      ),
    );

    return RepaintBoundary(
      child: Dismissible(
        key: ObjectKey(song),
        direction: onRemove != null
            ? DismissDirection.horizontal
            : DismissDirection.startToEnd,
        dismissThresholds: const {
          DismissDirection.startToEnd: 0.22,
          DismissDirection.endToStart: 0.4,
        },
        background: _SwipeBackground(
          color: accent,
          ink: cs.onPrimary,
          icon: AppIcons.addToQueue,
          label: 'In coda',
          alignment: Alignment.centerLeft,
        ),
        secondaryBackground: onRemove == null
            ? null
            : _SwipeBackground(
                color: cs.error,
                ink: cs.onError,
                icon: AppIcons.trash,
                label: 'Rimuovi',
                alignment: Alignment.centerRight,
              ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.endToStart) return onRemove != null;
          // The row comes back: the swipe only queues the song.
          HapticFeedback.mediumImpact();
          PlaybackLogService.instance
              .log('UI', 'tile swipe: in coda "${song.title}"');
          audioHandler.addToQueue(song);
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(
              content: Text('Aggiunto in coda'),
              duration: Duration(milliseconds: 1400),
            ));
          return false;
        },
        onDismissed: (_) => onRemove?.call(),
        child: row,
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.color,
    required this.ink,
    required this.icon,
    required this.label,
    required this.alignment,
  });

  final Color color;
  final Color ink;
  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: ink, size: 22),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: TextStyle(color: ink, fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _SongDownloadBadge extends StatelessWidget {
  final String songId;
  final Color color;

  const _SongDownloadBadge({required this.songId, required this.color});

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
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          );
        }
        return ValueListenableBuilder<List<Song>>(
          valueListenable: StorageService.instance.downloadsNotifier,
          builder: (context, _, _) {
            if (StorageService.instance.isDownloaded(songId)) {
              return Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(AppIcons.downloaded, size: 15, color: color),
              );
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}

/// Three animated equalizer bars shown where a song is playing.
class PlayingBars extends StatefulWidget {
  final Color color;
  final double height;

  const PlayingBars({super.key, required this.color, this.height = 18});

  @override
  State<PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<PlayingBars>
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
    final low = widget.height * 0.3;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (i) {
            final phase = (_controller.value + i * 0.28) % 1.0;
            final wave = (math.sin(phase * 2 * math.pi) + 1) / 2;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 3,
                height: low + (widget.height - low) * wave,
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
