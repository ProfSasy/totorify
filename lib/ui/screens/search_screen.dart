import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/cover_art_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/spotify_catalog_service.dart';
import '../../services/storage_service.dart';
import '../../services/track_matcher_service.dart';
import '../../services/ytmusic_catalog_service.dart';
import '../../services/spotify_service.dart';
import '../../services/spotify_internal_auth_service.dart';
import '../app_navigation.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/bounce_button.dart';
import '../widgets/filter_pill.dart';
import '../widgets/player_sheet.dart';
import '../widgets/section_header.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/song_tile.dart';
import '../widgets/top_bar.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class SearchScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const SearchScreen({super.key, required this.audioHandler});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const String _allKinds = 'Tutto';

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Kind of result shown: everything, or one of the pills.
  String _kind = _allKinds;
  List<Song> _results = [];
  List<Artist> _artistResults = [];
  List<Album> _albumResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  Timer? _debounce;
  int _searchGeneration = 0;
  List<String> _recentSearches = [];
  bool _openingCategory = false;

  final List<String> _suggestedQueries = [
    'Sanremo 2026',
    'Top Hits Italia',
    'Taylor Swift',
    'The Weeknd',
    'Sfera Ebbasta',
    'Coldplay',
    'Lofi Hip Hop',
    'Geolier',
  ];

  @override
  void initState() {
    super.initState();
    _recentSearches = StorageService.instance.getRecentSearches();
  }

  /// Live search: fires automatically ~400ms after the last keystroke.
  void _onQueryChanged(String value) {
    setState(() {}); // refresh the clear button visibility
    _debounce?.cancel();
    final clean = value.trim();
    if (clean.isEmpty) {
      _searchGeneration++;
      setState(() {
        _results = [];
        _artistResults = [];
        _albumResults = [];
        _isSearching = false;
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 420),
      () => _performSearch(clean),
    );
  }

  /// Explicit search: adds the query to the recent-searches list.
  Future<void> _submitSearch(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    _debounce?.cancel();
    await StorageService.instance.addRecentSearch(clean);
    if (!mounted) return;
    setState(() => _recentSearches = StorageService.instance.getRecentSearches());
    await _performSearch(clean);
  }

  Future<void> _performSearch(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    final generation = ++_searchGeneration;
    PlaybackLogService.instance.log('UI', 'search: cerco "$clean"');
    setState(() {
      _isSearching = true;
      _hasSearched = true;
    });

    var found = const CatalogSearch();
    try {
      found = await YTMusicCatalogService.instance.search(clean);
    } catch (e) {
      debugPrint('SearchScreen catalog error: $e');
    }
    var songs = _rankTracks(clean, found);

    if (songs.isEmpty && SpotifyInternalAuthService.instance.hasSpDcCookie) {
      try {
        songs = await SpotifyService.instance.searchTracks(clean);
      } catch (e) {
        debugPrint('SearchScreen Spotify error: $e');
      }
    }

    if (!mounted || generation != _searchGeneration) return;
    PlaybackLogService.instance.log(
      'UI',
      'search: "$clean" -> ${songs.length} brani, ${found.artists.length} artisti, '
      '${found.albums.length} album',
    );
    setState(() {
      _results = songs;
      _artistResults = found.artists.take(8).toList();
      _albumResults = found.albums.take(10).toList();
      _isSearching = false;
    });
    unawaited(_upgradeCovers(songs, generation));
  }

  /// One list of tracks out of what the catalog found: its best match, the
  /// songs, then the music videos (a song released only as a video is found
  /// nowhere else). Tracks that carry every word of the query come first:
  /// when the catalog has no such song it fills the list with loose matches.
  List<Song> _rankTracks(String query, CatalogSearch found) {
    // The catalog's best match can be the video of a song that is also in
    // the list: the song goes in its place, and a video that is the same
    // length as its song (the same audio, with pictures) is left out.
    final matcher = TrackMatcherService.instance;
    final songIds = {for (final song in found.songs) song.id};
    Song? songOf(Song video) => songIds.contains(video.id)
        ? null
        : found.songs.where((song) => matcher.isVideoOf(video, song)).firstOrNull;
    bool sameAudio(Song video, Song song) =>
        video.duration > Duration.zero &&
        song.duration > Duration.zero &&
        (video.duration - song.duration).abs() <= const Duration(seconds: 10);

    final top = found.topSong;
    final topSong = top == null ? null : songOf(top);
    final seen = <String>{};
    final tracks = <Song>[
      ?(topSong ?? top),
      ...found.songs,
      ...[?top, ...found.videos]
          .where((video) => !YTMusicCatalogService.isAlteredVersion(video.title))
          .where((video) {
            final song = songOf(video);
            return song == null || !sameAudio(video, song);
          })
          .take(8),
    ].where((song) => seen.add(song.id)).toList();

    final words = YTMusicCatalogService.normalize(query).split(' ');
    bool matches(Song song) {
      final text = ' ${YTMusicCatalogService.normalize(
        '${song.title} ${song.artist} ${song.album ?? ''}',
      )} ';
      return words.every((word) => text.contains(' $word'));
    }

    return [
      ...tracks.where(matches),
      ...tracks.where((song) => !matches(song)),
    ];
  }

  /// Video results come with a YouTube frame as artwork: swap in the
  /// official album cover once it is resolved.
  Future<void> _upgradeCovers(List<Song> songs, int generation) async {
    if (!songs.any((s) => CoverArtService.needsOriginal(s.thumbnailUrl))) return;
    try {
      final upgraded = await CoverArtService.instance.withOriginalCovers(songs);
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _results = upgraded);
    } catch (e) {
      debugPrint('SearchScreen._upgradeCovers: $e');
    }
  }

  Future<void> _clearRecentSearches() async {
    await StorageService.instance.clearRecentSearches();
    if (!mounted) return;
    setState(() => _recentSearches = []);
  }

  Future<void> _openCategory(SpotifyCategoryItem category) async {
    if (_openingCategory) return;
    _openingCategory = true;
    PlaybackLogService.instance
        .log('UI', 'search: categoria "${category.title}"');
    try {
      final songs = await SpotifyCatalogService.instance
          .getPlaylistSongs(category.playlistId);
      if (!mounted) return;

      final pl = Playlist(
        id: category.playlistId,
        title: category.title,
        description: 'I migliori brani del genere ${category.title}',
        thumbnailUrl: category.coverUrl,
        songs: songs,
        isSystem: true,
      );

      Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => PlaylistScreen(
            playlist: pl,
            audioHandler: widget.audioHandler,
          ),
        ),
      );
    } finally {
      _openingCategory = false;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _searching => _searchController.text.isNotEmpty || _hasSearched;

  void _leaveSearch() {
    PlaybackLogService.instance.log('UI', 'search: chiudi ricerca');
    _searchFocus.unfocus();
    _searchController.clear();
    _onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: NowPlayingBackdrop(
              audioHandler: widget.audioHandler,
              intensity: 0.6,
              extent: 0.32,
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The title collapses while a search is active: the bar stays,
                // the header gets out of the way.
                AnimatedSize(
                  duration: AppMotion.base,
                  curve: AppMotion.standard,
                  alignment: Alignment.topLeft,
                  child: _searching
                      ? const SizedBox(width: double.infinity, height: AppSpacing.sm)
                      : SizedBox(
                          height: TopBar.height,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg),
                            child: Row(
                              children: [
                                const ProfileButton(),
                                const SizedBox(width: AppSpacing.md),
                                Text(
                                  'Cerca',
                                  style: AppText.screenTitle(cs).copyWith(fontSize: 22),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
                  child: _buildSearchField(cs),
                ),
                if (_hasResults) _buildResultFilters(),
                const SizedBox(height: AppSpacing.sm),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The field is light, like a sheet of paper on the dark page: it is the
  /// one thing this tab is for.
  Widget _buildSearchField(ColorScheme cs) {
    const ink = Color(0xFF121212);
    const hint = Color(0xFF5E5E5E);
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      // The field sits between two slots whose content changes as soon as
      // something is typed (the lens becomes a back arrow, a clear button
      // appears). The slots keep their place and the field its key: were
      // the field rebuilt from scratch, it would lose the focus and the
      // keyboard would close under the user's fingers.
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: _searching
                ? IconButton(
                    tooltip: 'Chiudi la ricerca',
                    icon: const Icon(AppIcons.back, color: ink, size: 19),
                    onPressed: _leaveSearch,
                  )
                : const Icon(AppIcons.search, color: ink, size: 24),
          ),
          Expanded(
            key: const ValueKey('search_field'),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: _onQueryChanged,
              onSubmitted: _submitSearch,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              style: const TextStyle(
                color: ink,
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
              ),
              cursorColor: ink,
              decoration: const InputDecoration(
                isCollapsed: true,
                hintText: 'Cosa vuoi ascoltare?',
                hintStyle: TextStyle(
                  color: hint,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                ),
                border: InputBorder.none,
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: _isSearching
                ? const CupertinoActivityIndicator(color: ink, radius: 9)
                : _searchController.text.isNotEmpty
                    ? IconButton(
                        tooltip: 'Cancella',
                        icon: const Icon(AppIcons.clear, color: hint, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                          _searchFocus.requestFocus();
                        },
                      )
                    : null,
          ),
        ],
      ),
    );
  }

  bool get _hasResults =>
      _results.isNotEmpty || _artistResults.isNotEmpty || _albumResults.isNotEmpty;

  List<Playlist> get _playlistMatches {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return StorageService.instance
        .getPlaylists()
        .where((p) => p.title.toLowerCase().contains(query))
        .take(5)
        .toList();
  }

  List<SpotifyCategoryItem> get _categoryMatches {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return SpotifyCatalogService.instance.browseCategories
        .where((c) => c.title.toLowerCase().contains(query))
        .take(5)
        .toList();
  }

  /// The kinds of result the search actually found, "all" first.
  List<String> get _kinds => [
        _allKinds,
        if (_results.isNotEmpty) 'Brani',
        if (_artistResults.isNotEmpty) 'Artisti',
        if (_albumResults.isNotEmpty) 'Album',
        if (_playlistMatches.isNotEmpty || _categoryMatches.isNotEmpty) 'Playlist',
      ];

  /// The kind being shown: a kind that a new search no longer has cannot
  /// stay selected.
  String get _activeKind => _kinds.contains(_kind) ? _kind : _allKinds;

  /// One pill per kind of result.
  Widget _buildResultFilters() {
    final kinds = _kinds;
    final selected = _activeKind;

    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
        itemCount: kinds.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) => FilterPill(
          label: kinds[index],
          selected: kinds[index] == selected,
          onTap: () {
            PlaybackLogService.instance.log('UI', 'search: filtro "${kinds[index]}"');
            setState(() => _kind = kinds[index]);
          },
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isSearching && _results.isEmpty) {
      return const SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        child: SongListSkeleton(count: 7),
      );
    }

    if (_hasResults) {
      final userPlaylists = _playlistMatches;
      final categories = _categoryMatches;
      final playlistMatches = userPlaylists.length + categories.length;
      final kind = _activeKind;
      final all = kind == _allKinds;
      bool visible(String wanted) => all || kind == wanted;

      return ValueListenableBuilder<(String?, bool)>(
        valueListenable: widget.audioHandler.playbackIndicator,
        builder: (context, indicator, _) {
          final currentId = indicator.$2 ? indicator.$1 : null;

          return CustomScrollView(
            controller: AppNavigation.rootScrollers[AppNavigation.searchTab],
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              if (visible('Artisti') && _artistResults.isNotEmpty) ...[
                if (all)
                  const SliverToBoxAdapter(
                    child: SectionHeader(
                      'Artisti',
                      padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
                    ),
                  ),
                if (all)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: ArtistChip.rowHeight,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding:
                            const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                        itemCount: _artistResults.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: AppSpacing.lg),
                        itemBuilder: (context, index) => ArtistChip(
                          artist: _artistResults[index],
                          onTap: () => ArtistScreen.open(
                            context,
                            widget.audioHandler,
                            artist: _artistResults[index],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final artist = _artistResults[index];
                        return _ResultTile(
                          title: artist.name,
                          subtitle: artist.audience.isEmpty
                              ? 'Artista'
                              : 'Artista • ${artist.audience}',
                          coverUrl: artist.imageUrl,
                          icon: AppIcons.artist,
                          round: true,
                          onTap: () => ArtistScreen.open(
                            context,
                            widget.audioHandler,
                            artist: artist,
                          ),
                        );
                      },
                      childCount: _artistResults.length,
                    ),
                  ),
              ],
              if (visible('Brani') && _results.isNotEmpty) ...[
                if (all)
                  const SliverToBoxAdapter(
                    child: SectionHeader(
                      'Brani',
                      padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                    ),
                  ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = _results[index];
                      return SongTile(
                        song: song,
                        isPlaying: currentId == song.id,
                        onTap: () {
                          widget.audioHandler.playSong(song, queue: _results);
                          PlayerSheet.show(context, widget.audioHandler);
                        },
                      );
                    },
                    childCount: _results.length,
                  ),
                ),
              ],
              if (visible('Album') && _albumResults.isNotEmpty) ...[
                if (all)
                  const SliverToBoxAdapter(
                      child: SectionHeader('Album, singoli ed EP')),
                if (all)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: AlbumCard.rowHeight,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding:
                            const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                        itemCount: _albumResults.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: AppSpacing.lg),
                        itemBuilder: (context, index) => AlbumCard(
                          album: _albumResults[index],
                          onTap: () => AlbumScreen.open(
                            context,
                            widget.audioHandler,
                            _albumResults[index],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final album = _albumResults[index];
                        return _ResultTile(
                          title: album.title,
                          subtitle: [
                            album.caption,
                            if (album.artist.isNotEmpty) album.artist,
                          ].join(' • '),
                          coverUrl: album.coverUrl,
                          icon: AppIcons.album,
                          onTap: () => AlbumScreen.open(
                            context,
                            widget.audioHandler,
                            album,
                          ),
                        );
                      },
                      childCount: _albumResults.length,
                    ),
                  ),
              ],
              if (visible('Playlist') && playlistMatches > 0) ...[
                if (all) const SliverToBoxAdapter(child: SectionHeader('Playlist')),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index < userPlaylists.length) {
                        final playlist = userPlaylists[index];
                        return _ResultTile(
                          title: playlist.title,
                          subtitle: 'Playlist • ${playlist.songs.length} brani',
                          coverUrl: playlistCoverUrl(playlist),
                          icon: AppIcons.playlist,
                          onTap: () {
                            PlaybackLogService.instance.log('UI',
                                'search: apri playlist "${playlist.title}"');
                            Navigator.push(
                              context,
                              CupertinoPageRoute<void>(
                                builder: (_) => PlaylistScreen(
                                  playlist: playlist,
                                  audioHandler: widget.audioHandler,
                                ),
                              ),
                            );
                          },
                        );
                      }
                      final category = categories[index - userPlaylists.length];
                      return _ResultTile(
                        title: category.title,
                        subtitle: 'Playlist • Spotify',
                        coverUrl: category.coverUrl,
                        icon: AppIcons.playlist,
                        onTap: () => _openCategory(category),
                      );
                    },
                    childCount: playlistMatches,
                  ),
                ),
              ],
              const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.bottomContentInset)),
            ],
          );
        },
      );
    }

    if (_hasSearched) {
      return const AppEmptyState(
        icon: AppIcons.search,
        title: 'Nessun risultato',
        subtitle: 'Prova con un altro titolo o artista.',
      );
    }

    return _buildBrowseAllView();
  }

  /// What the tab shows before a search: the last searches, a few ideas,
  /// and the genres to browse.
  Widget _buildBrowseAllView() {
    final categories = SpotifyCatalogService.instance.browseCategories;
    final cs = Theme.of(context).colorScheme;

    Widget chip(String query, {IconData? icon}) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            PlaybackLogService.instance.log('UI', 'search: chip "$query"');
            _searchController.text = query;
            _submitSearch(query);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: AppRadius.chip,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

    return CustomScrollView(
      controller: AppNavigation.rootScrollers[AppNavigation.searchTab],
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (_recentSearches.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionHeader(
              'Ricerche recenti',
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
              trailing: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _clearRecentSearches,
                child: Text(
                  'Cancella',
                  style: AppText.caption(cs).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final query in _recentSearches)
                    chip(query, icon: AppIcons.history),
                ],
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(
          child: SectionHeader(
            'Prova a cercare',
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [for (final query in _suggestedQueries) chip(query)],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SectionHeader('Sfoglia tutto')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.bottomContentInset),
          sliver: SliverGrid.count(
            crossAxisCount: 2,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 1.7,
            children: categories.map(_buildCategoryCard).toList(),
          ),
        ),
      ],
    );
  }

  /// Card of a genre: its color, its name, and a cover leaning out of the
  /// bottom right corner.
  Widget _buildCategoryCard(SpotifyCategoryItem category) {
    return BounceButton(
      onPressed: () => _openCategory(category),
      child: Container(
        decoration: BoxDecoration(
          color: category.color,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              top: AppSpacing.md,
              left: AppSpacing.md,
              right: 52,
              child: Text(
                category.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  height: 1.15,
                  color: Colors.white,
                ),
              ),
            ),
            Positioned(
              bottom: -6,
              right: -16,
              child: Transform.rotate(
                angle: 25 * (math.pi / 180),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(-2, 3),
                      ),
                    ],
                  ),
                  child: AppCover(
                    url: category.coverUrl,
                    size: 70,
                    icon: AppIcons.playlist,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Row of a search result that is not a song: an artist, a release, a
/// playlist.
class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.icon,
    required this.onTap,
    this.round = false,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final IconData icon;
  final bool round;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 7),
        child: Row(
          children: [
            AppCover(url: coverUrl, size: 50, circle: round, icon: icon),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle(cs),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileSubtitle(cs),
                  ),
                ],
              ),
            ),
            Icon(AppIcons.chevronRight, color: cs.onSurfaceVariant, size: 22),
          ],
        ),
      ),
    );
  }
}
