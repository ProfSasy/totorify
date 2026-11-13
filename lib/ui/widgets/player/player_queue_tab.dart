import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../../../models/song.dart';
import '../../../services/audio_handler.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/storage_service.dart';
import '../../theme/app_ambience.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import '../app_cover.dart';
import '../song_options_sheet.dart';
import '../song_tile.dart';
import 'player_style.dart';

/// The queue: the song playing on top, what comes next (to reorder or
/// remove) and the recommended tracks.
class PlayerQueueTab extends StatelessWidget {
  const PlayerQueueTab({
    super.key,
    required this.audioHandler,
    required this.palette,
    required this.bottomInset,
    required this.notify,
  });

  final AudioPlayerHandler audioHandler;
  final AmbientPalette palette;
  final double bottomInset;

  /// Shows a short message over the player.
  final void Function(String message) notify;

  @override
  Widget build(BuildContext context) {
    final quiet = playerInk.withValues(alpha: 0.72);
    // Rebuild whenever the real queue changes (reorder, dismiss, radio adds).
    return StreamBuilder<List<MediaItem>>(
      stream: audioHandler.queue,
      builder: (context, _) {
        final playlist = audioHandler.currentPlaylist;
        final currentSong = audioHandler.currentSong;
        final suggestedIds = audioHandler.suggestedIdsNotifier.value;
        final isPlaying = audioHandler.playbackState.value.playing;

        if (playlist.isEmpty) {
          return Center(
            child: Text('La coda è vuota', style: TextStyle(color: quiet)),
          );
        }

        // As Spotify's: the song playing on top, then what comes next. The
        // songs already played stay behind the "previous" button.
        final playingAt = audioHandler.queueSnapshot.index
            .clamp(0, playlist.length - 1);
        final base = playingAt + 1;
        final upcoming = playlist.length - base;

        Widget sectionTitle(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xs),
              child: Text(
                text,
                style: const TextStyle(color: playerInk, fontSize: 16, fontWeight: FontWeight.w800),
              ),
            );

        Widget row(int index, {required bool reorderable}) {
          final song = playlist[index];
          final isCurrent = index == playingAt;
          final content = Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () {
                PlaybackLogService.instance.log('UI', 'coda: tap "${song.title}"');
                // By position: the queue stays as it is, and a song queued
                // twice plays the copy that was tapped.
                audioHandler.skipToQueueItem(index);
              },
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl, 7, reorderable ? AppSpacing.sm : AppSpacing.xl, 7),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        AppCover(url: song.thumbnailUrl, size: 46),
                        if (isCurrent)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: AppRadius.cover,
                              ),
                              child: isPlaying
                                  ? PlayingBars(color: palette.accent, height: 16)
                                  : Icon(AppIcons.pause, color: palette.accent, size: 22),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isCurrent ? palette.accent : playerInk,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: quiet, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    // Added by Smart Shuffle, not by the user.
                    if (suggestedIds.contains(song.id))
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: Icon(AppIcons.smart, color: palette.accent, size: 16),
                      ),
                    if (reorderable)
                      ReorderableDragStartListener(
                        index: index - base,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Icon(AppIcons.dragHandle, color: quiet, size: 24),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
          if (!reorderable) return content;
          return Dismissible(
            key: ValueKey('queue_${song.id}_$index'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: AppSpacing.xl),
              color: Theme.of(context).colorScheme.error,
              child: const Icon(AppIcons.trash, color: Colors.white),
            ),
            onDismissed: (_) {
              PlaybackLogService.instance.log('UI', 'coda: rimuovo indice $index');
              audioHandler.removeFromQueue(index);
            },
            child: content,
          );
        }

        return ReorderableListView.builder(
          // Extra bottom padding keeps the last queue item clear of the home
          // indicator now that the root no longer applies the bottom safe area.
          padding: EdgeInsets.only(top: AppSpacing.sm, bottom: bottomInset + AppSpacing.xl),
          itemCount: upcoming,
          // Rows are moved by their handle; a long press is not needed.
          buildDefaultDragHandles: false,
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              QueueActions(
                audioHandler: audioHandler,
                ink: playerInk,
                notify: notify,
              ),
              sectionTitle('In riproduzione'),
              row(playingAt, reorderable: false),
              if (upcoming > 0) sectionTitle('Prossimi in coda'),
            ],
          ),
          // Recommended next tracks, reloaded when the song or queue changes.
          footer: QueueSuggestions(
            key: ValueKey('suggest_${currentSong?.id}_${playlist.length}'),
            audioHandler: audioHandler,
            accent: palette.accent,
          ),
          proxyDecorator: (child, index, animation) => Material(
            color: Color.lerp(palette.surface, Colors.white, 0.08),
            elevation: 8,
            shadowColor: Colors.black,
            child: child,
          ),
          onReorder: (oldIndex, newIndex) {
            PlaybackLogService.instance
                .log('UI', 'coda: riordino ${base + oldIndex} -> ${base + newIndex}');
            audioHandler.reorderQueue(base + oldIndex, base + newIndex);
          },
          itemBuilder: (context, i) => KeyedSubtree(
            key: ValueKey('queue_row_${playlist[base + i].id}_${base + i}'),
            child: row(base + i, reorderable: true),
          ),
        );
      },
    );
  }
}

/// Above the queue: mix what is left, keep it as a playlist, empty it.
class QueueActions extends StatelessWidget {
  const QueueActions({super.key, required this.audioHandler, required this.ink, required this.notify});

  final AudioPlayerHandler audioHandler;
  final Color ink;
  final void Function(String message) notify;

  Future<void> _save(BuildContext context) async {
    final songs = audioHandler.currentPlaylist;
    if (songs.isEmpty) return;
    final name = await askPlaylistName(context);
    if (name == null) return;
    PlaybackLogService.instance.log('UI', 'coda: salvo come playlist "$name"');
    final storage = StorageService.instance;
    final playlist = await storage.createPlaylist(name);
    for (final song in songs) {
      await storage.addSongToPlaylist(playlist.id, song);
    }
    notify('Coda salvata in "$name"');
  }

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: ActionChip(
            avatar: Icon(icon, size: 16, color: ink),
            label: Text(label, style: TextStyle(color: ink, fontSize: 13)),
            backgroundColor: ink.withValues(alpha: 0.10),
            side: BorderSide.none,
            shape: const StadiumBorder(),
            onPressed: onTap,
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            action(AppIcons.shuffle, 'Mescola', () {
              audioHandler.shuffleUpcoming();
              notify('Coda mescolata');
            }),
            action(AppIcons.save, 'Salva', () => _save(context)),
            action(AppIcons.trash, 'Svuota', () {
              audioHandler.clearQueue();
              notify('Coda svuotata');
            }),
          ],
        ),
      ),
    );
  }
}

/// "Consigliati" list under the queue: tracks that fit after the current
/// song, each one tap away from the queue.
class QueueSuggestions extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final Color accent;

  const QueueSuggestions({
    super.key,
    required this.audioHandler,
    required this.accent,
  });

  @override
  State<QueueSuggestions> createState() => _QueueSuggestionsState();
}

class _QueueSuggestionsState extends State<QueueSuggestions> {
  late final Future<List<Song>> _suggestions =
      widget.audioHandler.suggestionsForCurrent();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Song>>(
      future: _suggestions,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Song>[];
        if (songs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.sm),
              child: Row(
                children: [
                  Icon(AppIcons.smart, size: 17, color: widget.accent),
                  const SizedBox(width: AppSpacing.sm),
                  const Text(
                    'Consigliati',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            for (final song in songs)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 7, AppSpacing.sm, 7),
                child: Row(
                  children: [
                    AppCover(url: song.thumbnailUrl, size: 46),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Aggiungi alla coda',
                      icon: const Icon(AppIcons.save, color: Colors.white, size: 25),
                      onPressed: () {
                        PlaybackLogService.instance
                            .log('UI', 'coda: aggiungo consigliato "${song.title}"');
                        widget.audioHandler.addToQueue(song);
                      },
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
