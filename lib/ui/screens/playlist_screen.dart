import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/download_service.dart';
import '../../services/storage_service.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/collection_header.dart';
import '../widgets/play_button.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/song_tile.dart';

/// Page of a collection of songs: a playlist of the user, a chart, an
/// album, the favourites, the downloads. Its header and its play button
/// take the colors of its cover.
class PlaylistScreen extends StatefulWidget {
  final Playlist playlist;
  final AudioPlayerHandler audioHandler;

  const PlaylistScreen({
    super.key,
    required this.playlist,
    required this.audioHandler,
  });

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  // Collections that belong to the app itself and cannot be saved as a
  // playlist of the user.
  static const Set<String> _builtIn = {
    'system_favorites',
    'system_downloads',
    'history',
  };

  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  Playlist get playlist => widget.playlist;
  AudioPlayerHandler get audioHandler => widget.audioHandler;

  @override
  void initState() {
    super.initState();
    // A chart or an album saved in the library is opened here with its
    // tracks of today: the saved copy follows.
    if (playlist.isSystem &&
        playlist.songs.isNotEmpty &&
        StorageService.instance.getPlaylists().any((p) => p.id == playlist.id)) {
      unawaited(StorageService.instance
          .savePlaylist(playlist.copyWith(isSystem: false)));
    }
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    super.dispose();
  }

  String _formatTotalDuration(List<Song> songs) {
    final totalSec = songs.fold<int>(0, (sum, s) => sum + s.duration.inSeconds);
    if (totalSec == 0) return '';
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    if (hours > 0) return mins > 0 ? '$hours h $mins min' : '$hours h';
    return '$mins min';
  }

  void _play(Song song, List<Song> queue) {
    audioHandler.playSong(song, queue: queue);
    PlayerSheet.show(context, audioHandler);
  }

  Future<void> _downloadAll(List<Song> songs, bool allDownloaded) async {
    final messenger = ScaffoldMessenger.of(context);
    PlaybackLogService.instance.log(
      'UI',
      'playlist: scarica "${playlist.title}" '
      '(${songs.length} brani, già tutti scaricati: $allDownloaded)',
    );
    if (allDownloaded) {
      final again = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Già scaricata'),
          content: const Text(
              'Tutti i brani sono già salvati sul dispositivo. Vuoi riscaricarli?'),
          actions: [
            CupertinoDialogAction(
              child: const Text('Annulla'),
              onPressed: () => Navigator.pop(ctx, false),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text('Riscarica'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (again != true) return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Download avviato per ${songs.length} brani')),
    );
    final (ok, failed) = await DownloadService.instance
        .downloadPlaylist(songs, forceRefresh: allDownloaded);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Download completato: $ok brani'
              : 'Download completato: $ok riusciti, $failed falliti',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final storage = StorageService.instance;

    return Scaffold(
      backgroundColor: cs.surfaceDim,
      body: ListenableBuilder(
        listenable: Listenable.merge([
          storage.playlistsNotifier,
          storage.favoritesNotifier,
          storage.downloadsNotifier,
        ]),
        builder: (context, _) {
          final stored = storage.playlistsNotifier.value
              .where((p) => p.id == playlist.id)
              .firstOrNull;
          // Favourites and downloads follow the library while the page is
          // open; a playlist of the user follows its stored copy; anything
          // else (a chart, an album, the history) is shown as it was opened.
          final current = switch (playlist.id) {
            'system_favorites' =>
              playlist.copyWith(songs: storage.favoritesNotifier.value),
            'system_downloads' =>
              playlist.copyWith(songs: storage.downloadsNotifier.value),
            _ => playlist.isSystem ? playlist : (stored ?? playlist),
          };
          // Only a playlist of the user can lose songs or be deleted.
          final editable = stored != null && !playlist.isSystem;
          final savable = playlist.isSystem && !_builtIn.contains(playlist.id);
          final songs = current.songs;
          final coverUrl = playlistCoverUrl(current);
          final duration = _formatTotalDuration(songs);

          return AmbientTint(
            artworkUrl: coverUrl,
            fallback: cs.primary,
            builder: (context, palette) => Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth == 0) {
                      _scrollOffset.value = notification.metrics.pixels;
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics()),
                    slivers: [
                      SliverToBoxAdapter(
                        child: CollectionHeader(
                          palette: palette,
                          scrollOffset: _scrollOffset,
                          artwork: _buildCover(current, coverUrl),
                          child: _buildInfo(
                            context,
                            current: current,
                            songs: songs,
                            duration: duration,
                            palette: palette,
                            editable: editable,
                            savable: savable,
                            saved: stored != null,
                          ),
                        ),
                      ),
                      if (songs.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: AppEmptyState(
                            icon: AppIcons.note,
                            title: 'Nessun brano in questa raccolta',
                            subtitle:
                                'Aggiungi brani dal loro menu o dalla ricerca.',
                          ),
                        )
                      else
                        ValueListenableBuilder<(String?, bool)>(
                          valueListenable: audioHandler.playbackIndicator,
                          builder: (context, indicator, _) => SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final song = songs[index];
                                return SongTile(
                                  song: song,
                                  isPlaying:
                                      indicator.$2 && indicator.$1 == song.id,
                                  onTap: () => _play(song, songs),
                                  onRemove: editable
                                      ? () {
                                          PlaybackLogService.instance.log('UI',
                                              'playlist: rimuovo "${song.title}"');
                                          storage.removeSongFromPlaylist(
                                              playlist.id, song.id);
                                        }
                                      : null,
                                );
                              },
                              childCount: songs.length,
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(
                          child: SizedBox(height: AppSpacing.bottomContentInset)),
                    ],
                  ),
                ),
                CollectionTopBar(
                  title: current.title,
                  palette: palette,
                  scrollOffset: _scrollOffset,
                  actions: [
                    if (editable)
                      IconButton(
                        tooltip: 'Elimina playlist',
                        icon: const Icon(AppIcons.trash),
                        onPressed: () => _confirmDelete(context),
                      ),
                    if (playlist.id == 'system_downloads' && songs.isNotEmpty)
                      IconButton(
                        tooltip: 'Elimina tutti i download',
                        icon: const Icon(AppIcons.trash),
                        onPressed: () => _confirmClearAllDownloads(context),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCover(Playlist current, String? coverUrl) {
    final size = CollectionHeader.artworkSize(context);
    if (playlist.id == 'system_favorites') {
      final cs = Theme.of(context).colorScheme;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: AppRadius.cover,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, Color.lerp(cs.primary, Colors.white, 0.45)!],
          ),
        ),
        child: Icon(AppIcons.heartFilled, size: size * 0.4, color: cs.onPrimary),
      );
    }

    // A playlist without a cover of its own shows its first four songs.
    final own = current.thumbnailUrl;
    final thumbs = <String>{
      for (final song in current.songs)
        if (song.thumbnailUrl.isNotEmpty) song.thumbnailUrl,
    }.take(4).toList();
    if ((own == null || own.isEmpty) && thumbs.length == 4) {
      final half = size / 2;
      return ClipRRect(
        borderRadius: AppRadius.cover,
        child: SizedBox.square(
          dimension: size,
          child: Wrap(
            children: [
              for (final url in thumbs) AppCover(url: url, size: half, radius: 0),
            ],
          ),
        ),
      );
    }
    return AppCover(url: coverUrl, size: size, icon: AppIcons.playlist);
  }

  Widget _buildInfo(
    BuildContext context, {
    required Playlist current,
    required List<Song> songs,
    required String duration,
    required AmbientPalette palette,
    required bool editable,
    required bool savable,
    required bool saved,
  }) {
    final cs = Theme.of(context).colorScheme;
    final description = current.description ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          current.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.screenTitle(cs),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.tileSubtitle(cs),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          [
            '${songs.length} brani',
            if (duration.isNotEmpty) duration,
          ].join(' • '),
          style: AppText.caption(cs),
        ),
        const SizedBox(height: AppSpacing.sm),

        // ── Actions: download, save, shuffle, play ──────────────────────
        Row(
          children: [
            if (songs.isNotEmpty)
              ValueListenableBuilder<List<Song>>(
                valueListenable: StorageService.instance.downloadsNotifier,
                builder: (context, _, _) {
                  final allDownloaded = songs
                      .every((s) => StorageService.instance.isDownloaded(s.id));
                  return IconButton(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                    icon: Icon(
                      allDownloaded ? AppIcons.downloaded : AppIcons.download,
                      color: allDownloaded ? palette.accent : cs.onSurfaceVariant,
                      size: 28,
                    ),
                    tooltip: allDownloaded ? 'Scaricata' : 'Scarica',
                    onPressed: () => _downloadAll(songs, allDownloaded),
                  );
                },
              ),
            if (savable && songs.isNotEmpty)
              IconButton(
                tooltip: saved ? 'Rimuovi dalla libreria' : 'Salva nella libreria',
                icon: AnimatedSwitcher(
                  duration: AppMotion.base,
                  switchInCurve: Curves.easeOutBack,
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    saved ? AppIcons.saved : AppIcons.save,
                    key: ValueKey<bool>(saved),
                    color: saved ? palette.accent : cs.onSurfaceVariant,
                    size: 28,
                  ),
                ),
                onPressed: () => _toggleSaved(current, saved),
              ),
            const Spacer(),
            if (songs.isNotEmpty) ...[
              IconButton(
                icon: Icon(AppIcons.shuffle, color: cs.onSurfaceVariant, size: 28),
                tooltip: 'Riproduzione casuale',
                onPressed: () {
                  final shuffled = List<Song>.from(songs)..shuffle();
                  PlaybackLogService.instance
                      .log('UI', 'playlist: shuffle "${playlist.title}"');
                  _play(shuffled.first, shuffled);
                },
              ),
              const SizedBox(width: AppSpacing.sm),
              ValueListenableBuilder<(String?, bool)>(
                valueListenable: audioHandler.playbackIndicator,
                builder: (context, indicator, _) {
                  // The button follows the player while this collection is
                  // the one playing.
                  final isCurrent = audioHandler.currentSong != null &&
                      songs.any((s) => s.id == audioHandler.currentSong!.id);
                  final playing = isCurrent && indicator.$2;
                  return PlayButton(
                    color: palette.accent,
                    playing: playing,
                    onPressed: () {
                      if (playing) {
                        PlaybackLogService.instance
                            .log('UI', 'playlist: pausa "${playlist.title}"');
                        audioHandler.pause();
                      } else if (isCurrent) {
                        PlaybackLogService.instance
                            .log('UI', 'playlist: riprendi "${playlist.title}"');
                        audioHandler.play();
                      } else {
                        PlaybackLogService.instance
                            .log('UI', 'playlist: play all "${playlist.title}"');
                        _play(songs.first, songs);
                      }
                    },
                  );
                },
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _toggleSaved(Playlist current, bool saved) async {
    final messenger = ScaffoldMessenger.of(context);
    if (saved) {
      PlaybackLogService.instance
          .log('UI', 'playlist: tolgo dalla libreria "${current.title}"');
      await StorageService.instance.deletePlaylist(current.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Rimossa dalla tua libreria')),
      );
    } else {
      PlaybackLogService.instance
          .log('UI', 'playlist: salvo nella libreria "${current.title}"');
      await StorageService.instance.savePlaylist(current.copyWith(isSystem: false));
      messenger.showSnackBar(
        const SnackBar(content: Text('Salvata nella tua libreria')),
      );
    }
  }

  void _confirmDelete(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Elimina playlist'),
        content: Text('Vuoi davvero eliminare "${playlist.title}"?'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Elimina'),
            onPressed: () {
              Navigator.pop(ctx);
              StorageService.instance.deletePlaylist(playlist.id);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _confirmClearAllDownloads(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Elimina tutti i download'),
        content: const Text(
            'Tutti i brani scaricati verranno eliminati dal dispositivo.'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Elimina'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(ctx);
              await DownloadService.instance.clearAllDownloads();
              messenger.showSnackBar(
                const SnackBar(content: Text('Download eliminati')),
              );
            },
          ),
        ],
      ),
    );
  }
}
