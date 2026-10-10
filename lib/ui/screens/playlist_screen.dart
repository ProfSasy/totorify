import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/download_service.dart';
import '../../services/storage_service.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/mini_player.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_tile.dart';

class PlaylistScreen extends StatelessWidget {
  final Playlist playlist;
  final AudioPlayerHandler audioHandler;

  const PlaylistScreen({
    super.key,
    required this.playlist,
    required this.audioHandler,
  });

  String _formatTotalDuration(List<Song> songs) {
    if (songs.isEmpty) return '0 min';
    final totalSec = songs.fold<int>(0, (sum, s) => sum + s.duration.inSeconds);
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    if (hours > 0) {
      return '$hours h ${mins > 0 ? '$mins min' : ''}'.trim();
    }
    return '$mins min';
  }

  Widget _buildCoverArt(BuildContext context, Playlist current, Color primaryColor) {
    // 1. Cover URL ufficiale (da Spotify o YouTube)
    if (current.thumbnailUrl != null && current.thumbnailUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: current.thumbnailUrl!,
        width: 170,
        height: 170,
        fit: BoxFit.cover,
        memCacheWidth: 400,
        memCacheHeight: 400,
        placeholder: (_, _) => _buildPlaceholder(context, primaryColor),
        errorWidget: (_, _, _) => _buildPlaceholder(context, primaryColor),
      );
    }

    // 2. Collage 2x2 tipo Spotify con le prime 4 tracce
    final songsWithThumb = current.songs.where((s) => s.thumbnailUrl.isNotEmpty).toList();
    if (songsWithThumb.length >= 4) {
      return SizedBox(
        width: 170,
        height: 170,
        child: Column(
          children: [
            Row(
              children: [
                _buildMiniThumb(context, songsWithThumb[0].thumbnailUrl),
                _buildMiniThumb(context, songsWithThumb[1].thumbnailUrl),
              ],
            ),
            Row(
              children: [
                _buildMiniThumb(context, songsWithThumb[2].thumbnailUrl),
                _buildMiniThumb(context, songsWithThumb[3].thumbnailUrl),
              ],
            ),
          ],
        ),
      );
    }

    // 3. Prima cover disponibile o placeholder
    if (songsWithThumb.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: songsWithThumb.first.thumbnailUrl,
        width: 170,
        height: 170,
        fit: BoxFit.cover,
        memCacheWidth: 400,
        memCacheHeight: 400,
        placeholder: (_, _) => _buildPlaceholder(context, primaryColor),
        errorWidget: (_, _, _) => _buildPlaceholder(context, primaryColor),
      );
    }

    return _buildPlaceholder(context, primaryColor);
  }

  Widget _buildMiniThumb(BuildContext context, String url) {
    return CachedNetworkImage(
      imageUrl: url,
      width: 85,
      height: 85,
      fit: BoxFit.cover,
      memCacheWidth: 170,
      memCacheHeight: 170,
      placeholder: (_, _) => Container(width: 85, height: 85, color: Theme.of(context).colorScheme.surface),
      errorWidget: (_, _, _) => Container(width: 85, height: 85, color: Theme.of(context).colorScheme.surface),
    );
  }

  Widget _buildPlaceholder(BuildContext context, Color primaryColor) {
    return Container(
      width: 170,
      height: 170,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primaryColor.withValues(alpha: 0.35),
            Theme.of(context).colorScheme.surface,
          ],
        ),
      ),
      child: Icon(
        CupertinoIcons.music_albums,
        size: 64,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceDim,
      // The mini player stays visible on pushed pages too (Spotify-style):
      // it's only hidden in the Settings tab of the main shell.
      bottomNavigationBar: SafeArea(
        top: false,
        child: MiniPlayer(audioHandler: audioHandler),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          StorageService.instance.playlistsNotifier,
          StorageService.instance.favoritesNotifier,
          StorageService.instance.downloadsNotifier,
        ]),
        builder: (context, _) {
          final storage = StorageService.instance;
          final stored = storage.playlistsNotifier.value
              .where((p) => p.id == playlist.id)
              .firstOrNull;
          // Favourites and downloads follow the library while the page is
          // open; a saved playlist follows its stored copy; anything else (a
          // chart, the history) is shown as it was opened.
          final current = switch (playlist.id) {
            'system_favorites' =>
              playlist.copyWith(songs: storage.favoritesNotifier.value),
            'system_downloads' =>
              playlist.copyWith(songs: storage.downloadsNotifier.value),
            _ => stored ?? playlist,
          };
          // Only a playlist saved in the library can lose songs or be
          // deleted. Swiping a row of anything else would dismiss a widget
          // that is still in the list, which Flutter treats as an error.
          final editable = stored != null && !playlist.isSystem;
          final songs = current.songs;
          final totalDuration = _formatTotalDuration(songs);
          // Every collection wears its own colors: the ambiance is derived
          // from its cover (official art, or the first song thumbnail).
          String? coverUrl = current.thumbnailUrl;
          if (coverUrl == null || coverUrl.isEmpty) {
            final withThumb = songs.where((s) => s.thumbnailUrl.isNotEmpty);
            coverUrl =
                withThumb.isNotEmpty ? withThumb.first.thumbnailUrl : null;
          }

          return AmbientTint(
            artworkUrl: coverUrl,
            fallback: primaryColor,
            builder: (context, palette) => Stack(
              children: [
                Positioned.fill(
                  child: AmbientBackdrop(
                    artworkUrl: coverUrl,
                    intensity: 0.35,
                  ),
                ),
                CustomScrollView(
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  slivers: [
                    // ── Spotify-Style Sliver App Bar with Dynamic Gradient ────────
                    SliverAppBar(
                      expandedHeight: (current.description ?? '').isEmpty ? 330 : 352,
                      pinned: true,
                      elevation: 0,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      leading: IconButton(
                        icon: Icon(CupertinoIcons.back, color: Theme.of(context).colorScheme.onSurface),
                        onPressed: () => Navigator.pop(context),
                      ),
                      actions: [
                        if (editable)
                          IconButton(
                            tooltip: 'Elimina playlist',
                            icon: Icon(CupertinoIcons.trash, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
                            onPressed: () => _confirmDelete(context),
                          ),
                        if (playlist.id == 'system_downloads')
                          IconButton(
                            icon: Icon(CupertinoIcons.trash, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
                            tooltip: 'Elimina tutti i download',
                            onPressed: () => _confirmClearAllDownloads(context),
                          ),
                      ],
                      flexibleSpace: FlexibleSpaceBar(
                        collapseMode: CollapseMode.parallax,
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Ambient Gradient — colored by the playlist's
                            // own cover.
                            AnimatedContainer(
                              duration: AppMotion.ambience,
                              curve: Curves.easeOut,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    palette.primary.withValues(alpha: 0.45),
                                    Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                                    Theme.of(context).colorScheme.surface,
                                  ],
                                  stops: [0.0, 0.75, 1.0],
                                ),
                              ),
                            ),

                            // Header Content (Artwork + Title + Metadata)
                            SafeArea(
                              bottom: false,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const SizedBox(height: 10),
                                    // Artwork con ombra colorata dall'ambient
                                    AnimatedContainer(
                                      duration: AppMotion.ambience,
                                      curve: Curves.easeOut,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(AppRadius.sm),
                                        boxShadow: [
                                          BoxShadow(
                                            color: palette.primary.withValues(alpha: 0.35),
                                            blurRadius: 42,
                                            offset: const Offset(0, 18),
                                          ),
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: 0.35),
                                            blurRadius: 24,
                                            offset: const Offset(0, 12),
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(AppRadius.sm),
                                        child: _buildCoverArt(context, current, palette.primary),
                                      ),
                                    ),
                                    const SizedBox(height: 16),

                                    // Titolo Playlist — mai troncato: si
                                    // ridimensiona quando il nome è lungo.
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        current.title,
                                        maxLines: 1,
                                        textAlign: TextAlign.center,
                                        style: AppText.screenTitle(
                                                Theme.of(context).colorScheme)
                                            .copyWith(fontSize: 22),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    if ((current.description ?? '').isNotEmpty) ...[
                                      Text(
                                        current.description!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: AppText.tileSubtitle(
                                            Theme.of(context).colorScheme),
                                      ),
                                      const SizedBox(height: 2),
                                    ],

                                    // Metadati Spotify-like
                                    Text(
                                      '${songs.length} brani • $totalDuration',
                                      style: AppText.tileSubtitle(
                                          Theme.of(context).colorScheme),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── Spotify Action Row (Play, Shuffle, Download) ──────────────
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Row(
                          children: [
                            // Download button
                            if (songs.isNotEmpty)
                              ValueListenableBuilder<List<Song>>(
                                valueListenable: StorageService.instance.downloadsNotifier,
                                builder: (context, _, _) {
                                  final allDownloaded = songs.isNotEmpty &&
                                      songs.every((s) => StorageService.instance.isDownloaded(s.id));

                                  return IconButton(
                                    icon: Icon(
                                      allDownloaded
                                          ? CupertinoIcons.arrow_down_circle_fill
                                          : CupertinoIcons.arrow_down_circle,
                                      color: allDownloaded ? primaryColor : Theme.of(context).colorScheme.onSurfaceVariant,
                                      size: 26,
                                    ),
                                    tooltip: allDownloaded ? 'Scaricata' : 'Scarica offline',
                                    onPressed: () async {
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
                                            title: Text('Playlist già Scaricata'),
                                            content: Text(
                                                'Tutti i brani sono già salvati sul dispositivo. Vuoi riscaricarli per verificarne l\'integrità?'),
                                            actions: [
                                              CupertinoDialogAction(
                                                child: Text('Annulla'),
                                                onPressed: () => Navigator.pop(ctx, false),
                                              ),
                                              CupertinoDialogAction(
                                                isDefaultAction: true,
                                                child: Text('Riscarica'),
                                                onPressed: () => Navigator.pop(ctx, true),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (again != true) return;
                                      }
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('Download avviato per ${songs.length} brani...'),
                                          behavior: SnackBarBehavior.floating,
                                        ),
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
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),

                            // Shuffle button
                            if (songs.isNotEmpty)
                              IconButton(
                                icon: Icon(CupertinoIcons.shuffle, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 24),
                                tooltip: 'Riproduzione casuale',
                                onPressed: () {
                                  final shuffled = List<Song>.from(songs)..shuffle();
                                  PlaybackLogService.instance.log(
                                      'UI', 'playlist: shuffle "${playlist.title}"');
                                  audioHandler.playSong(shuffled.first, queue: shuffled);
                                  PlayerSheet.show(context, audioHandler);
                                },
                              ),

                            const Spacer(),

                            // Large Circular Spotify-Style Play Button
                            if (songs.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  PlaybackLogService.instance.log(
                                      'UI', 'playlist: play all "${playlist.title}"');
                                  audioHandler.playSong(songs.first, queue: songs);
                                  PlayerSheet.show(context, audioHandler);
                                },
                                child: AnimatedContainer(
                                  duration: AppMotion.ambience,
                                  curve: Curves.easeOut,
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: AppTheme.primaryGradient(
                                        Theme.of(context).colorScheme),
                                    boxShadow: [
                                      BoxShadow(
                                        color: palette.primary
                                            .withValues(alpha: 0.45),
                                        blurRadius: 18,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    CupertinoIcons.play_fill,
                                    color: Theme.of(context).colorScheme.onPrimary,
                                    size: 24,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // ── Songs List ────────────────────────────────────────────────
                    if (songs.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: AppEmptyState(
                          icon: CupertinoIcons.music_note,
                          title: 'Nessun brano in questa raccolta',
                          subtitle: 'Aggiungi brani dalla ricerca o dalla libreria.',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = songs[index];
                              return ValueListenableBuilder<(String?, bool)>(
                                valueListenable: audioHandler.playbackIndicator,
                                builder: (context, indicator, _) {
                              final isPlaying =
                                  indicator.$2 && indicator.$1 == song.id;

                              final tile = SongTile(
                                song: song,
                                isPlaying: isPlaying,
                                onTap: () {
                                  audioHandler.playSong(song, queue: songs);
                                  PlayerSheet.show(context, audioHandler);
                                },
                              );

                              if (!editable) return tile;

                              return Dismissible(
                                key: ValueKey('pl_${song.id}_$index'),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  color: Theme.of(context).colorScheme.error,
                                  child: Icon(CupertinoIcons.trash,
                                      color: Theme.of(context).colorScheme.onError),
                                ),
                                onDismissed: (_) {
                                  PlaybackLogService.instance.log(
                                      'UI', 'playlist: rimuovo "${song.title}"');
                                  StorageService.instance
                                      .removeSongFromPlaylist(playlist.id, song.id);
                                },
                                child: tile,
                              );
                                },
                              );
                            },
                            childCount: songs.length,
                          ),
                        ),
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

  void _confirmDelete(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Elimina Playlist'),
        content: Text('Vuoi davvero eliminare "${playlist.title}"?'),
        actions: [
          CupertinoDialogAction(
            child: Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: Text('Elimina'),
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
        title: Text('Elimina Tutti i Download'),
        content: Text(
            'Sei sicuro di voler eliminare tutti i brani scaricati per liberare memoria?'),
        actions: [
          CupertinoDialogAction(
            child: Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: Text('Svuota'),
            onPressed: () async {
              Navigator.pop(ctx);
              await DownloadService.instance.clearAllDownloads();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Tutti i download sono stati eliminati.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
