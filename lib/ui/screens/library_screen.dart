import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/playlist_importer_service.dart';
import '../../services/storage_service.dart';
import '../app_navigation.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_sheet.dart';
import '../widgets/cover_card.dart';
import '../widgets/filter_pill.dart';
import '../widgets/player_sheet.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/song_tile.dart';
import '../widgets/top_bar.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const LibraryScreen({super.key, required this.audioHandler});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

/// One thing kept in the library, shown as a row or as a card.
class _Entry {
  const _Entry({
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.onTap,
    this.round = false,
  });

  final String title;
  final String subtitle;
  final Widget Function(double size) cover;
  final VoidCallback onTap;
  final bool round;
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const List<String> _filters = ['Playlist', 'Artisti', 'Scaricati', 'Preferiti'];
  static const List<String> _sortModes = ['Recenti', 'Titolo', 'Artista'];
  static const double _chipsHeight = 46;

  /// Null shows everything.
  String? _filter;
  String _sortMode = _sortModes.first;
  bool _grid = StorageService.instance.libraryGrid;

  final ValueNotifier<bool> _barSolid = ValueNotifier<bool>(false);

  bool get _showsSongs => _filter == 'Scaricati' || _filter == 'Preferiti';

  @override
  void dispose() {
    _barSolid.dispose();
    super.dispose();
  }

  /// Applies the selected ordering to a song list without mutating it.
  List<Song> _sortSongs(List<Song> songs) {
    final list = List<Song>.from(songs);
    switch (_sortMode) {
      case 'Titolo':
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case 'Artista':
        list.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
    }
    return list;
  }

  /// Playlists follow the same sort menu: by title, or the newest first.
  List<Playlist> _sortPlaylists(List<Playlist> input) {
    if (_sortMode == 'Titolo') {
      return List<Playlist>.from(input)
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return input.reversed.toList();
  }

  void _setFilter(String? filter) {
    PlaybackLogService.instance.log('UI', 'library: filtro "${filter ?? 'tutto'}"');
    setState(() => _filter = filter);
  }

  Future<void> _pickSort() async {
    final picked = await showChoiceSheet<String>(
      context,
      title: 'Ordina per',
      options: [for (final mode in _sortModes) (mode, mode)],
      selected: _sortMode,
    );
    if (picked == null || !mounted) return;
    PlaybackLogService.instance.log('UI', 'library: ordina "$picked"');
    setState(() => _sortMode = picked);
  }

  void _toggleGrid() {
    PlaybackLogService.instance.log('UI', 'library: vista ${_grid ? 'elenco' : 'griglia'}');
    setState(() => _grid = !_grid);
    StorageService.instance.setLibraryGrid(_grid);
  }

  void _openPlaylist(Playlist playlist) {
    PlaybackLogService.instance.log('UI', 'library: apri playlist "${playlist.title}"');
    Navigator.push(
      context,
      CupertinoPageRoute<void>(
        builder: (_) => PlaylistScreen(
          playlist: playlist,
          audioHandler: widget.audioHandler,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final storage = StorageService.instance;
    final topInset = TopBar.extent(context, bottom: _chipsHeight);
    final backdrop = NowPlayingBackdrop(
      audioHandler: widget.audioHandler,
      intensity: 0.6,
      extent: 0.32,
    );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: backdrop),
          NotificationListener<ScrollNotification>(
            onNotification: TopBar.watch(_barSolid),
            child: ListenableBuilder(
              listenable: Listenable.merge([
                storage.playlistsNotifier,
                storage.favoritesNotifier,
                storage.downloadsNotifier,
                storage.followedArtistsNotifier,
                widget.audioHandler.playbackIndicator,
              ]),
              builder: (context, _) => CustomScrollView(
                controller: AppNavigation.rootScrollers[AppNavigation.libraryTab],
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: topInset)),
                  SliverToBoxAdapter(child: _buildSortRow(cs)),
                  if (_showsSongs)
                    _buildSongs(
                      _filter == 'Scaricati'
                          ? storage.downloadsNotifier.value
                          : storage.favoritesNotifier.value,
                    )
                  else
                    ..._buildEntries(cs),
                  const SliverToBoxAdapter(
                      child: SizedBox(height: AppSpacing.bottomContentInset)),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopBar(
              solid: _barSolid,
              backdrop: backdrop,
              bottom: SizedBox(height: _chipsHeight, child: _buildChips(cs)),
              child: Row(
                children: [
                  const ProfileButton(),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'La tua libreria',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.screenTitle(cs).copyWith(fontSize: 22),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Crea o importa una playlist',
                    icon: const Icon(AppIcons.add, size: 30),
                    onPressed: _showAddMenu,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChips(ColorScheme cs) {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 4, AppSpacing.lg, 8),
      children: [
        if (_filter != null) ...[
          Semantics(
            button: true,
            label: 'Togli il filtro',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setFilter(null),
              child: Container(
                width: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(AppIcons.close, size: 18, color: cs.onSurface),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        for (final filter in _filters)
          if (_filter == null || _filter == filter)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: FilterPill(
                label: filter,
                selected: _filter == filter,
                onTap: () => _setFilter(_filter == filter ? null : filter),
              ),
            ),
      ],
    );
  }

  Widget _buildSortRow(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 2, AppSpacing.xs, 2),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _pickSort,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.sort, size: 18, color: cs.onSurface),
                  const SizedBox(width: 6),
                  Text(
                    _sortMode,
                    style: AppText.caption(cs).copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (!_showsSongs)
            IconButton(
              tooltip: _grid ? 'Mostra come elenco' : 'Mostra come griglia',
              icon: Icon(_grid ? AppIcons.list : AppIcons.grid,
                  size: 20, color: cs.onSurface),
              onPressed: _toggleGrid,
            )
          else
            const SizedBox(height: 48),
        ],
      ),
    );
  }

  // ── Playlists and artists ─────────────────────────────────────────────────

  List<_Entry> _entries(ColorScheme cs) {
    final storage = StorageService.instance;
    final favorites = storage.favoritesNotifier.value;
    final downloads = storage.downloadsNotifier.value;
    final showPlaylists = _filter == null || _filter == 'Playlist';
    final showArtists = _filter == null || _filter == 'Artisti';

    Widget tinted(double size, IconData icon, List<Color> colors, Color ink) =>
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: AppRadius.cover,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          child: Icon(icon, size: size * 0.42, color: ink),
        );

    return [
      if (showPlaylists) ...[
        _Entry(
          title: 'Brani che ti piacciono',
          subtitle: 'Playlist • ${favorites.length} brani',
          cover: (size) => tinted(
            size,
            AppIcons.heartFilled,
            [cs.primary, Color.lerp(cs.primary, Colors.white, 0.45)!],
            cs.onPrimary,
          ),
          onTap: () => _openPlaylist(Playlist(
            id: 'system_favorites',
            title: 'Brani che ti piacciono',
            songs: favorites,
            isSystem: true,
          )),
        ),
        _Entry(
          title: 'Brani scaricati',
          subtitle: 'Sul dispositivo • ${downloads.length} brani',
          cover: (size) => tinted(
            size,
            AppIcons.downloaded,
            [cs.surfaceContainerHighest, cs.surfaceContainerHigh],
            cs.primary,
          ),
          onTap: () => _openPlaylist(Playlist(
            id: 'system_downloads',
            title: 'Brani scaricati',
            songs: downloads,
            isSystem: true,
          )),
        ),
        for (final playlist in _sortPlaylists(storage.playlistsNotifier.value))
          _Entry(
            title: playlist.title,
            subtitle: 'Playlist • ${playlist.songs.length} brani',
            cover: (size) => AppCover(
              url: playlistCoverUrl(playlist),
              size: size,
              icon: AppIcons.playlist,
            ),
            onTap: () => _openPlaylist(playlist),
          ),
      ],
      if (showArtists)
        for (final artist in storage.followedArtistsNotifier.value)
          _Entry(
            title: artist.name,
            subtitle: 'Artista',
            round: true,
            cover: (size) => AppCover(
              url: artist.imageUrl,
              size: size,
              circle: true,
              icon: AppIcons.artist,
            ),
            onTap: () => ArtistScreen.open(
              context,
              widget.audioHandler,
              artist: artist,
            ),
          ),
    ];
  }

  List<Widget> _buildEntries(ColorScheme cs) {
    final entries = _entries(cs);
    if (entries.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AppEmptyState(
            icon: AppIcons.artist,
            title: 'Non segui ancora nessun artista',
            subtitle: 'Apri la pagina di un artista e tocca "Segui".',
          ),
        ),
      ];
    }

    if (_grid) {
      const spacing = AppSpacing.md;
      final width = (MediaQuery.sizeOf(context).width - 2 * AppSpacing.lg - 2 * spacing) / 3;
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisExtent: CoverCard.heightFor(width, subtitleLines: 2),
              crossAxisSpacing: spacing,
              mainAxisSpacing: AppSpacing.sm,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final entry = entries[index];
                return CoverCard(
                  imageUrl: null,
                  cover: entry.cover(width),
                  title: entry.title,
                  subtitle: entry.subtitle,
                  subtitleLines: 2,
                  size: width,
                  circle: entry.round,
                  onTap: entry.onTap,
                );
              },
              childCount: entries.length,
            ),
          ),
        ),
      ];
    }

    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _EntryRow(entry: entries[index]),
          childCount: entries.length,
        ),
      ),
      if (_filter != 'Artisti' && StorageService.instance.playlistsNotifier.value.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Crea la tua prima playlist',
                    style: AppText.tileTitle(cs).copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'Oppure importane una da Spotify o da YouTube Music.',
                  style: AppText.caption(cs),
                ),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton(
                  onPressed: _showAddMenu,
                  child: const Text('Crea o importa'),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  // ── Songs (downloads, favourites) ─────────────────────────────────────────

  Widget _buildSongs(List<Song> raw) {
    final songs = _sortSongs(raw);
    if (songs.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _filter == 'Scaricati'
            ? const AppEmptyState(
                icon: AppIcons.download,
                title: 'Nessun brano scaricato',
                subtitle: 'Apri il menu di un brano e scegli "Scarica".',
              )
            : const AppEmptyState(
                icon: AppIcons.heart,
                title: 'Nessun brano nei preferiti',
                subtitle: 'Tocca il cuore su un brano per ritrovarlo qui.',
              ),
      );
    }
    final indicator = widget.audioHandler.playbackIndicator.value;
    final playingId = indicator.$2 ? indicator.$1 : null;

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final song = songs[index];
          return SongTile(
            song: song,
            isPlaying: playingId == song.id,
            onTap: () {
              widget.audioHandler.playSong(song, queue: songs);
              PlayerSheet.show(context, widget.audioHandler);
            },
          );
        },
        childCount: songs.length,
      ),
    );
  }

  // ── Create / import ───────────────────────────────────────────────────────

  void _showAddMenu() {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    showAppSheet<void>(
      context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetAction(
            icon: AppIcons.playlist,
            label: 'Nuova playlist',
            subtitle: 'Crea una raccolta con i tuoi brani',
            onTap: () async {
              Navigator.pop(sheetContext);
              final name = await askPlaylistName(rootContext);
              if (name == null) return;
              final created = await StorageService.instance.createPlaylist(name);
              if (mounted) _openPlaylist(created);
            },
          ),
          SheetAction(
            icon: AppIcons.link,
            label: 'Importa una playlist',
            subtitle: 'Dal link di una playlist pubblica di Spotify o YouTube',
            onTap: () {
              Navigator.pop(sheetContext);
              _showImportSheet();
            },
          ),
        ],
      ),
    );
  }

  void _showImportSheet() {
    PlaybackLogService.instance.log('UI', 'library: import dialog');
    final messenger = ScaffoldMessenger.of(context);
    showAppSheet<void>(
      context,
      builder: (_) => _ImportSheet(
        onImported: (created) {
          if (created == null) {
            PlaybackLogService.instance.log('UI', 'library: import fallito');
            messenger.showSnackBar(const SnackBar(
              content: Text('Import non riuscito: link non valido o playlist privata.'),
            ));
            return;
          }
          if (created.songs.isEmpty) {
            messenger.showSnackBar(const SnackBar(
              content: Text('Playlist importata, ma senza brani disponibili.'),
            ));
            return;
          }
          PlaybackLogService.instance
              .log('UI', 'library: import ok "${created.title}"');
          messenger.showSnackBar(
            SnackBar(content: Text('"${created.title}" importata')),
          );
          if (mounted) _openPlaylist(created);
        },
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: entry.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 7),
        child: Row(
          children: [
            entry.cover(60),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle(cs),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileSubtitle(cs),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sheet that reads a playlist from a link and saves it in the library.
class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.onImported});

  /// Called once the sheet has closed, with the playlist that was created
  /// (null when the link could not be read).
  final void Function(Playlist? created) onImported;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = false;
  String _status = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final url = _controller.text.trim();
    if (url.isEmpty || _loading) return;
    // Kept now: the sheet may be closed before the import ends.
    final onImported = widget.onImported;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _status = 'Lettura della playlist…';
    });

    final created = await PlaylistImporterService.instance.importFromUrl(
      url,
      onProgress: (current, total) {
        if (mounted) setState(() => _status = 'Importati $current di $total brani…');
      },
    );
    if (mounted) Navigator.pop(context);
    onImported(created);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Importa una playlist',
              style: AppText.sectionTitle(cs).copyWith(fontSize: 18)),
          const SizedBox(height: 4),
          Text(
            'Incolla il link di una playlist pubblica di Spotify o YouTube Music.',
            style: AppText.caption(cs),
          ),
          const SizedBox(height: AppSpacing.lg),
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: !_loading,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _import(),
                    style: TextStyle(color: cs.onSurface, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'https://open.spotify.com/playlist/…',
                      hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: 14),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(AppIcons.paste, color: cs.onSurfaceVariant, size: 20),
                  tooltip: 'Incolla dagli appunti',
                  onPressed: _loading
                      ? null
                      : () async {
                          final data = await Clipboard.getData('text/plain');
                          final text = data?.text?.trim();
                          if (text != null && text.isNotEmpty) _controller.text = text;
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CupertinoActivityIndicator(radius: 9),
                  const SizedBox(width: AppSpacing.md),
                  Flexible(
                    child: Text(
                      _status,
                      style: TextStyle(color: cs.onSurface, fontSize: 14),
                    ),
                  ),
                ],
              ),
            )
          else
            FilledButton(onPressed: _import, child: const Text('Importa')),
        ],
      ),
    );
  }
}
