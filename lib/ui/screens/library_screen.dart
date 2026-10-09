import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/playlist_importer_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_tile.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const LibraryScreen({super.key, required this.audioHandler});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _selectedFilter = 'Tutti';
  final List<String> _filters = ['Tutti', 'Preferiti', 'Scaricati', 'Playlist'];

  String _sortMode = 'Recenti';
  final List<String> _sortModes = ['Recenti', 'Titolo', 'Artista'];

  /// Applies the selected ordering to a song list without mutating it.
  List<Song> _sortSongs(List<Song> songs) {
    final list = List<Song>.from(songs);
    switch (_sortMode) {
      case 'Titolo':
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case 'Artista':
        list.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
        break;
      case 'Recenti':
      default:
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final primaryColor = colorScheme.primary;

    return Scaffold(
      body: Stack(
        children: [
          // Ambient aurora, quieter than Home: the Library stays focused on
          // content while still echoing the track that is playing.
          Positioned.fill(
            child: StreamBuilder<MediaItem?>(
              stream: widget.audioHandler.mediaItem,
              builder: (context, snapshot) => AmbientBackdrop(
                artworkUrl: snapshot.data?.artUri?.toString(),
                intensity: 0.5,
              ),
            ),
          ),
          CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              // Collapsible iOS-style large title — the FittedBox keeps the
              // whole title visible at any accessibility size (scales, never
              // truncates).
              CupertinoSliverNavigationBar(
                largeTitle: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'La tua Libreria',
                    maxLines: 1,
                    style: AppText.display(colorScheme).copyWith(fontSize: 30),
                  ),
                ),
                backgroundColor: colorScheme.surface.withValues(alpha: 0.85),
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.onSurface.withValues(alpha: 0.06),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Ordina',
                      padding: EdgeInsets.zero,
                      icon: Icon(CupertinoIcons.arrow_up_arrow_down,
                          color: primaryColor, size: 22),
                      initialValue: _sortMode,
                      onSelected: (value) {
                        PlaybackLogService.instance
                            .log('UI', 'library: ordina "$value"');
                        setState(() => _sortMode = value);
                      },
                      itemBuilder: (context) => _sortModes
                          .map(
                            (mode) => PopupMenuItem<String>(
                              value: mode,
                              child: Row(
                                children: [
                                  Icon(
                                    mode == _sortMode
                                        ? CupertinoIcons.checkmark_circle_fill
                                        : CupertinoIcons.circle,
                                    size: 18,
                                    color: mode == _sortMode
                                        ? primaryColor
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Text(mode),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    IconButton(
                      icon: Icon(CupertinoIcons.plus_circle,
                          color: primaryColor, size: 26),
                      tooltip: 'Nuova Playlist',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () => _showNewPlaylistDialog(context),
                    ),
                  ],
                ),
              ),

              // The segmented filter stays pinned while the content scrolls.
              SliverPersistentHeader(
                pinned: true,
                delegate: _FilterHeaderDelegate(
                  height: 54,
                  background: colorScheme.surface,
                  child: CupertinoSlidingSegmentedControl<String>(
                    groupValue: _selectedFilter,
                    backgroundColor: colorScheme.surfaceContainerHigh,
                    thumbColor: primaryColor,
                    children: {
                      for (final filter in _filters)
                        filter: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md, vertical: 6),
                          child: Text(
                            filter,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: filter == _selectedFilter
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    },
                    onValueChanged: (value) {
                      if (value == null || value == _selectedFilter) return;
                      PlaybackLogService.instance
                          .log('UI', 'library: filtro "$value"');
                      setState(() => _selectedFilter = value);
                    },
                  ),
                ),
              ),

              _buildFilteredBody(context, primaryColor),
            ],
          ),
        ],
      ),
    );
  }

  /// Id of the row that should look "in riproduzione" (only while playing).
  String? get _playingSongId {
    final value = widget.audioHandler.playbackIndicator.value;
    return value.$2 ? value.$1 : null;
  }

  Widget _buildFilteredBody(BuildContext context, Color primaryColor) {
    return ValueListenableBuilder<(String?, bool)>(
      valueListenable: widget.audioHandler.playbackIndicator,
      builder: (context, _, _) {
        switch (_selectedFilter) {
          case 'Scaricati':
            return _buildDownloadsView(primaryColor);
          case 'Preferiti':
            return _buildFavoritesView(primaryColor);
          case 'Playlist':
            return _buildPlaylistsOnlyView(primaryColor);
          case 'Tutti':
          default:
            return _buildAllView(context, primaryColor);
        }
      },
    );
  }

  /// Full Library Overview (Tutti)
  Widget _buildAllView(BuildContext context, Color primaryColor) {
    final colorScheme = Theme.of(context).colorScheme;
    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // System cards: Preferiti & Scaricati
              Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: StorageService.instance.favoritesNotifier,
                      builder: (context, favorites, _) {
                        return _buildCard(
                          context,
                          title: 'Preferiti',
                          subtitle: '${favorites.length} brani',
                          icon: CupertinoIcons.heart_fill,
                          color: primaryColor,
                          onTap: () {
                            Navigator.push(
                              context,
                              CupertinoPageRoute(
                                builder: (_) => PlaylistScreen(
                                  playlist: Playlist(
                                    id: 'system_favorites',
                                    title: 'Brani Preferiti',
                                    songs: favorites,
                                    isSystem: true,
                                  ),
                                  audioHandler: widget.audioHandler,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: StorageService.instance.downloadsNotifier,
                      builder: (context, downloads, _) {
                        return _buildCard(
                          context,
                          title: 'Scaricati',
                          subtitle: '${downloads.length} brani',
                          icon: CupertinoIcons.arrow_down_circle_fill,
                          color: primaryColor,
                          onTap: () {
                            Navigator.push(
                              context,
                              CupertinoPageRoute(
                                builder: (_) => PlaylistScreen(
                                  playlist: Playlist(
                                    id: 'system_downloads',
                                    title: 'Brani Scaricati',
                                    songs: downloads,
                                    isSystem: true,
                                  ),
                                  audioHandler: widget.audioHandler,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Import action banner
              InkWell(
                onTap: () => _showImportPlaylistDialog(context),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                        color: colorScheme.onSurface.withValues(alpha: 0.06)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: primaryColor.withValues(alpha: 0.28)),
                        ),
                        child: Icon(CupertinoIcons.link,
                            color: primaryColor, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Importa da Spotify o YouTube',
                                style: AppText.tileTitle(colorScheme)),
                            Text(
                                'Incolla il link di una playlist pubblica Spotify o YouTube',
                                style: AppText.caption(colorScheme)),
                          ],
                        ),
                      ),
                      Icon(CupertinoIcons.chevron_right,
                          color: colorScheme.onSurfaceVariant, size: 16),
                    ],
                  ),
                ),
              ),
              ValueListenableBuilder<List<Artist>>(
                valueListenable:
                    StorageService.instance.followedArtistsNotifier,
                builder: (context, artists, _) {
                  if (artists.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 24),
                      Text('Artisti seguiti',
                          style: AppText.sectionTitle(colorScheme)),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 148,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: artists.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: AppSpacing.md),
                          itemBuilder: (context, index) => ArtistChip(
                            artist: artists[index],
                            onTap: () => ArtistScreen.open(
                              context,
                              widget.audioHandler,
                              artist: artists[index],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              Text('Playlist Create',
                  style: AppText.sectionTitle(colorScheme)),
              const SizedBox(height: 12),
            ]),
          ),
        ),
        _buildPlaylistsList(primaryColor),
        const SliverToBoxAdapter(
            child: SizedBox(height: AppSpacing.bottomContentInset)),
      ],
    );
  }

  /// Downloads View (Filtered)
  Widget _buildDownloadsView(Color primaryColor) {
    return ValueListenableBuilder<List<Song>>(
      valueListenable: StorageService.instance.downloadsNotifier,
      builder: (context, downloadsRaw, _) {
        final downloads = _sortSongs(downloadsRaw);
        if (downloads.isEmpty) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: AppEmptyState(
              icon: CupertinoIcons.arrow_down_circle,
              title: 'Nessun brano scaricato offline',
              subtitle: 'Tocca i 3 puntini su qualsiasi brano per scaricarlo.',
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.only(bottom: AppSpacing.bottomContentInset),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = downloads[index];
                final isPlaying = _playingSongId == song.id;
                return SongTile(
                  song: song,
                  isPlaying: isPlaying,
                  onTap: () {
                    widget.audioHandler.playSong(song, queue: downloads);
                    PlayerSheet.show(context, widget.audioHandler);
                  },
                );
              },
              childCount: downloads.length,
            ),
          ),
        );
      },
    );
  }

  /// Favorites View (Filtered)
  Widget _buildFavoritesView(Color primaryColor) {
    return ValueListenableBuilder<List<Song>>(
      valueListenable: StorageService.instance.favoritesNotifier,
      builder: (context, favoritesRaw, _) {
        final favorites = _sortSongs(favoritesRaw);
        if (favorites.isEmpty) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: AppEmptyState(
              icon: CupertinoIcons.heart,
              title: 'Nessun brano nei preferiti',
              subtitle: 'Tocca il cuore su un brano per ritrovarlo qui.',
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.only(bottom: AppSpacing.bottomContentInset),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = favorites[index];
                final isPlaying = _playingSongId == song.id;
                return SongTile(
                  song: song,
                  isPlaying: isPlaying,
                  onTap: () {
                    widget.audioHandler.playSong(song, queue: favorites);
                    PlayerSheet.show(context, widget.audioHandler);
                  },
                );
              },
              childCount: favorites.length,
            ),
          ),
        );
      },
    );
  }

  /// Playlists Only View (Filtered)
  Widget _buildPlaylistsOnlyView(Color primaryColor) {
    return SliverMainAxisGroup(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        _buildPlaylistsList(primaryColor),
        const SliverToBoxAdapter(
            child: SizedBox(height: AppSpacing.bottomContentInset)),
      ],
    );
  }

  /// Playlists follow the same sort menu as songs where it makes sense.
  List<Playlist> _sortPlaylists(List<Playlist> input) {
    final list = List<Playlist>.from(input);
    if (_sortMode == 'Titolo') {
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return list;
  }

  Widget _buildPlaylistsList(Color primaryColor) {
    return ValueListenableBuilder<List<Playlist>>(
      valueListenable: StorageService.instance.playlistsNotifier,
      builder: (context, playlistsRaw, _) {
        final playlists = _sortPlaylists(playlistsRaw);
        if (playlists.isEmpty) {
          return SliverToBoxAdapter(
            child: AppEmptyState(
              icon: CupertinoIcons.music_albums,
              title: 'Nessuna playlist creata',
              subtitle: 'Crea la tua prima raccolta personalizzata.',
              actionLabel: 'Crea playlist',
              onAction: () => _showNewPlaylistDialog(context),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final p = playlists[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  leading: _buildPlaylistCover(p, primaryColor),
                  title: Text(
                    p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle(Theme.of(context).colorScheme),
                  ),
                  subtitle: Text(
                    'Playlist \u2022 ${p.songs.length} brani',
                    style: AppText.caption(Theme.of(context).colorScheme),
                  ),
                  trailing: Icon(CupertinoIcons.chevron_right,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 16),
                  onTap: () {
                    PlaybackLogService.instance
                        .log('UI', 'library: apri playlist "${p.title}"');
                    Navigator.push(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => PlaylistScreen(
                            playlist: p, audioHandler: widget.audioHandler),
                      ),
                    );
                  },
                );
              },
              childCount: playlists.length,
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistCover(Playlist p, Color primaryColor) {
    if (p.thumbnailUrl != null && p.thumbnailUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: CachedNetworkImage(
          imageUrl: p.thumbnailUrl!,
          width: 54,
          height: 54,
          fit: BoxFit.cover,
          memCacheWidth: 140,
          memCacheHeight: 140,
          placeholder: (_, _) => _buildPlaceholderCover(primaryColor),
          errorWidget: (_, _, _) => _buildPlaceholderCover(primaryColor),
        ),
      );
    }

    final songsWithThumb = p.songs.where((s) => s.thumbnailUrl.isNotEmpty).toList();
    if (songsWithThumb.length >= 4) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: SizedBox(
          width: 54,
          height: 54,
          child: Column(
            children: [
              Row(
                children: [
                  _buildMiniThumb(songsWithThumb[0].thumbnailUrl),
                  _buildMiniThumb(songsWithThumb[1].thumbnailUrl),
                ],
              ),
              Row(
                children: [
                  _buildMiniThumb(songsWithThumb[2].thumbnailUrl),
                  _buildMiniThumb(songsWithThumb[3].thumbnailUrl),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (songsWithThumb.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: CachedNetworkImage(
          imageUrl: songsWithThumb.first.thumbnailUrl,
          width: 54,
          height: 54,
          fit: BoxFit.cover,
          memCacheWidth: 140,
          memCacheHeight: 140,
          placeholder: (_, _) => _buildPlaceholderCover(primaryColor),
          errorWidget: (_, _, _) => _buildPlaceholderCover(primaryColor),
        ),
      );
    }

    return _buildPlaceholderCover(primaryColor);
  }

  Widget _buildMiniThumb(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      width: 27,
      height: 27,
      fit: BoxFit.cover,
      memCacheWidth: 60,
      memCacheHeight: 60,
      placeholder: (_, _) => Container(width: 27, height: 27, color: Theme.of(context).colorScheme.surface),
      errorWidget: (_, _, _) => Container(width: 27, height: 27, color: Theme.of(context).colorScheme.surface),
    );
  }

  Widget _buildPlaceholderCover(Color primaryColor) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(CupertinoIcons.music_albums, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 26),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: cs.onSurface.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withValues(alpha: 0.28)),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 14),
            Text(title, style: AppText.tileTitle(cs)),
            const SizedBox(height: 2),
            Text(subtitle, style: AppText.caption(cs)),
          ],
        ),
      ),
    );
  }

  void _showNewPlaylistDialog(BuildContext context) async {
    final controller = TextEditingController();
    await showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Nuova Playlist'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            placeholder: 'Nome della playlist',
            autofocus: true,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            child: Text('Annulla'),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            child: Text('Crea'),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                StorageService.instance.createPlaylist(name);
              }
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _showImportPlaylistDialog(BuildContext context) async {
    PlaybackLogService.instance.log('UI', 'library: import dialog');
    final controller = TextEditingController();
    final primaryColor = Theme.of(context).colorScheme.primary;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetCtx) {
        bool isLoading = false;
        String statusText = '';

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 24,
                // Keyboard when open, home indicator otherwise: keeps the
                // action button clear of both.
                bottom: MediaQuery.viewInsetsOf(context).bottom +
                    MediaQuery.viewPaddingOf(context).bottom +
                    16,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: AppRadius.sheet,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Handle bar
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Header with Icon
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: primaryColor.withValues(alpha: 0.28)),
                        ),
                        child: Icon(CupertinoIcons.arrow_down_doc_fill, color: primaryColor, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Importa Playlist',
                              style: AppText.tileTitle(Theme.of(context).colorScheme)
                                  .copyWith(fontSize: 17),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Supporta link Spotify e YouTube Music',
                              style: AppText.caption(Theme.of(context).colorScheme),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Text Field with Paste Button
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            enabled: !isLoading,
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Incolla link Spotify o YouTube...',
                              hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(CupertinoIcons.doc_on_clipboard, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
                          tooltip: 'Incolla dagli appunti',
                          onPressed: isLoading
                              ? null
                              : () async {
                                  final data = await Clipboard.getData('text/plain');
                                  if (data?.text != null) {
                                    controller.text = data!.text!.trim();
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // CTA Button / Loading Indicator
                  if (isLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: primaryColor),
                          ),
                          const SizedBox(width: 14),
                          Text(
                            statusText.isNotEmpty ? statusText : 'Importazione ultra-veloce in corso...',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85), fontSize: 14),
                          ),
                        ],
                      ),
                    )
                  else
                    FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.md)),
                      ),
                      onPressed: () async {
                        final url = controller.text.trim();
                        if (url.isEmpty) return;

                        setSheetState(() {
                          isLoading = true;
                          statusText = 'Lettura playlist Spotify...';
                        });

                        final created = await PlaylistImporterService.instance.importFromUrl(
                          url,
                          onProgress: (cur, tot) {
                            setSheetState(() {
                              statusText = 'Importati $cur di $tot brani...';
                            });
                          },
                        );

                        if (bottomSheetCtx.mounted) {
                          Navigator.pop(bottomSheetCtx);
                        }
                        if (!context.mounted) return;

                        if (created == null) {
                          PlaybackLogService.instance
                              .log('UI', 'library: import fallito');
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Import non riuscito: link non valido o playlist privata.'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          return;
                        }
                        if (created.songs.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Playlist importata ma senza brani disponibili.'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          return;
                        }

                        PlaybackLogService.instance
                            .log('UI', 'library: import ok "${created.title}"');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Playlist "${created.title}" importata con successo!'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );

                        // Naviga istantaneamente alla playlist appena creata!
                        Navigator.push(
                          context,
                          CupertinoPageRoute(
                            builder: (_) => PlaylistScreen(
                              playlist: created,
                              audioHandler: widget.audioHandler,
                            ),
                          ),
                        );
                      },
                      child: Text(
                        'Importa Istantaneamente',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
    controller.dispose();
  }
}

/// Keeps the filter segmented control pinned under the large title while the
/// library content scrolls beneath it.
class _FilterHeaderDelegate extends SliverPersistentHeaderDelegate {
  _FilterHeaderDelegate({
    required this.height,
    required this.background,
    required this.child,
  });

  final double height;
  final Color background;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: background,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 6, AppSpacing.lg, 8),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_FilterHeaderDelegate oldDelegate) =>
      oldDelegate.child != child ||
      oldDelegate.height != height ||
      oldDelegate.background != background;
}
