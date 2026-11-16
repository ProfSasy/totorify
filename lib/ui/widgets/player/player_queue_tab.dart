import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../../../models/song.dart';
import '../../../services/audio_handler.dart';
import '../../../services/playback_log_service.dart';
import '../../../services/recommendation_service.dart';
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
    // Rebuild when the playback state changes (play and pause on the current
    // row; turning shuffle on or off reorders what comes next without a new
    // queue) and whenever the real queue changes (reorder, dismiss, radio
    // adds). The player around it no longer rebuilds at every such change.
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      builder: (context, _) => StreamBuilder<List<MediaItem>>(
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

          // Rows are keyed by song and by which copy of it they are, not by
          // position: removing or adding a song leaves the others as they are.
          final occurrence = List<int>.filled(playlist.length, 0);
          final copies = <String, int>{};
          for (var i = base; i < playlist.length; i++) {
            final id = playlist[i].id;
            occurrence[i] = copies[id] ?? 0;
            copies[id] = occurrence[i] + 1;
          }

          Widget sectionTitle(String text) => Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xs),
                child: Text(
                  text,
                  style: TextStyle(color: playerInk, fontSize: 16, fontWeight: FontWeight.w800),
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
              // With the number of copies: when one copy of a song is taken
              // away, the copy that inherits its row starts from a fresh state.
              key: ValueKey('queue_${song.id}_${occurrence[index]}_of_${copies[song.id]}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: AppSpacing.xl),
                color: Theme.of(context).colorScheme.error,
                child: Icon(AppIcons.trash, color: Colors.white),
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
            // Recommended next tracks, reloaded when the song changes; those
            // already in the queue are left out.
            footer: QueueSuggestions(
              audioHandler: audioHandler,
              accent: palette.accent,
              songId: currentSong?.id,
              queued: playlist,
            ),
            proxyDecorator: (child, index, animation) => Material(
              color: Color.lerp(palette.surface, playerInk, 0.08),
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
              key: ValueKey('queue_row_${playlist[base + i].id}_${occurrence[base + i]}'),
              child: row(base + i, reorderable: true),
            ),
          );
        },
      ),
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
    await storage.addSongsToPlaylist(playlist.id, songs);
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

  /// The song the suggestions follow: they are reloaded when it changes.
  final String? songId;

  /// The songs in the queue, left out of the suggestions (as the handler
  /// leaves them out: by id, and by title and artist).
  final List<Song> queued;

  const QueueSuggestions({
    super.key,
    required this.audioHandler,
    required this.accent,
    required this.songId,
    this.queued = const [],
  });

  @override
  State<QueueSuggestions> createState() => _QueueSuggestionsState();
}

class _QueueSuggestionsState extends State<QueueSuggestions> {
  static const int _shown = 6;

  // More than are shown, so the list stays full while songs from it are
  // added to the queue.
  late Future<List<Song>> _suggestions = _load();

  Future<List<Song>> _load() => widget.audioHandler.suggestionsForCurrent(limit: _shown * 2);

  @override
  void didUpdateWidget(covariant QueueSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    // While the new ones load, FutureBuilder keeps showing the previous.
    if (oldWidget.songId != widget.songId) _suggestions = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Song>>(
      future: _suggestions,
      builder: (context, snapshot) {
        final loaded = snapshot.data ?? const <Song>[];
        final queuedIds = {for (final song in widget.queued) song.id};
        final queuedKeys = loaded.isEmpty
            ? const <String>{}
            : {for (final song in widget.queued) RecommendationService.songKey(song)};
        final songs = [
          for (final song in loaded)
            if (!queuedIds.contains(song.id) &&
                !queuedKeys.contains(RecommendationService.songKey(song)))
              song,
        ].take(_shown).toList();
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
                  Text(
                    'Consigliati',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: playerInk,
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
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: playerInk,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: playerInk.withValues(alpha: 0.72),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Aggiungi alla coda',
                      icon: Icon(AppIcons.save, color: playerInk, size: 25),
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
