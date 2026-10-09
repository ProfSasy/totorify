import 'dart:async';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/cover_art_service.dart';
import '../../services/deezer_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/spotify_catalog_service.dart';
import '../../services/storage_service.dart';
import '../../services/ytmusic_service.dart';
import '../../services/spotify_service.dart';
import '../../services/spotify_internal_auth_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/player_sheet.dart';
import '../widgets/section_header.dart';
import '../widgets/song_tile.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class SearchScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  /// Called when the user taps the back button before the search bar:
  /// brings the MainShell back to the Home tab.
  final VoidCallback? onGoHome;

  const SearchScreen({
    super.key,
    required this.audioHandler,
    this.onGoHome,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Song> _results = [];
  List<Artist> _artistResults = [];
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
    PlaybackLogService.instance.log('UI', 'search: digitato "$value"');
    setState(() {}); // refresh the clear button visibility
    _debounce?.cancel();
    final clean = value.trim();
    if (clean.isEmpty) {
      _searchGeneration++;
      setState(() {
        _results = [];
        _artistResults = [];
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

    // Artists load alongside the songs; a failure only hides the row.
    final artistsFuture = DeezerService.instance.searchArtists(clean, limit: 6);

    List<Song> songs = [];
    try {
      songs = await YTMusicService.instance.search(clean);
    } catch (e) {
      debugPrint('SearchScreen YouTube error: $e');
    }
    
    if (songs.isEmpty && SpotifyInternalAuthService.instance.hasSpDcCookie) {
      try {
        songs = await SpotifyService.instance.searchTracks(clean);
      } catch (e) {
        debugPrint('SearchScreen Spotify error: $e');
      }
    }

    final artists = await artistsFuture;

    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _results = songs;
      _artistResults = artists;
      _isSearching = false;
    });
    unawaited(_upgradeCovers(songs, generation));
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          // Ambient aurora: same language as the other tabs, quiet behind
          // the search content.
          Positioned.fill(
            child: StreamBuilder<MediaItem?>(
              stream: widget.audioHandler.mediaItem,
              builder: (context, snapshot) => AmbientBackdrop(
                artworkUrl: snapshot.data?.artUri?.toString(),
                intensity: 0.45,
              ),
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
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: _searchController.text.isEmpty && !_hasSearched
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.lg,
                            AppSpacing.lg,
                            AppSpacing.md,
                          ),
                          child: Text('Cerca', style: AppText.screenTitle(cs)),
                        )
                      : const SizedBox(width: double.infinity),
                ),

                // Search bar with back-to-home button.
                AnimatedPadding(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    _searchController.text.isEmpty && !_hasSearched
                        ? 0
                        : AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Torna alla Home',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        icon: Icon(
                          CupertinoIcons.back,
                          color: cs.onSurface,
                          size: 24,
                        ),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          PlaybackLogService.instance
                              .log('UI', 'search: torna alla Home');
                          widget.onGoHome?.call();
                        },
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: cs.outlineVariant),
                          ),
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onQueryChanged,
                            onSubmitted: _submitSearch,
                            textInputAction: TextInputAction.search,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                            cursorColor: cs.primary,
                            decoration: InputDecoration(
                              hintText: 'Cosa vuoi ascoltare?',
                              hintStyle: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 14,
                              ),
                              prefixIcon: Icon(CupertinoIcons.search,
                                  color: cs.onSurfaceVariant, size: 20),
                              suffixIcon: _isSearching
                                  ? Padding(
                                      padding: const EdgeInsets.all(13),
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  cs.primary),
                                        ),
                                      ),
                                    )
                                  : _searchController.text.isNotEmpty
                                      ? IconButton(
                                          icon: Icon(
                                            CupertinoIcons.clear_circled_solid,
                                            color: cs.onSurfaceVariant,
                                            size: 20,
                                          ),
                                          onPressed: () {
                                            _searchController.clear();
                                            _onQueryChanged('');
                                          },
                                        )
                                      : null,
                              border: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: AppSpacing.lg),

                // Search results / Browse / Recent searches.
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ],
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

    if (_results.isNotEmpty) {
      final query = _searchController.text.trim().toLowerCase();
      final userPlaylists = query.isEmpty
          ? const <Playlist>[]
          : StorageService.instance
              .getPlaylists()
              .where((p) => p.title.toLowerCase().contains(query))
              .take(5)
              .toList();
      final categories = query.isEmpty
          ? const <SpotifyCategoryItem>[]
          : SpotifyCatalogService.instance.browseCategories
              .where((c) => c.title.toLowerCase().contains(query))
              .take(5)
              .toList();
      final playlistMatches = userPlaylists.length + categories.length;

      return ValueListenableBuilder<(String?, bool)>(
        valueListenable: widget.audioHandler.playbackIndicator,
        builder: (context, indicator, _) {
          final currentId = indicator.$2 ? indicator.$1 : null;

          return CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              if (_artistResults.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: SectionHeader(
                    'Artisti',
                    padding: EdgeInsets.fromLTRB(
                        AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 148,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                      itemCount: _artistResults.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: AppSpacing.md),
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
                ),
              ],
              const SliverToBoxAdapter(
                child: SectionHeader(
                  'Brani',
                  padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = _results[index];
                    final isPlaying = currentId == song.id;

                    return SongTile(
                      song: song,
                      isPlaying: isPlaying,
                      onTap: () {
                        widget.audioHandler.playSong(song, queue: _results);
                        PlayerSheet.show(context, widget.audioHandler);
                      },
                    );
                  },
                  childCount: _results.length,
                ),
              ),
              if (playlistMatches > 0) ...[
                const SliverToBoxAdapter(
                  child: SectionHeader(
                    'Playlist',
                    padding: EdgeInsets.fromLTRB(
                        AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index < userPlaylists.length) {
                        final playlist = userPlaylists[index];
                        return _PlaylistMatchTile(
                          title: playlist.title,
                          subtitle:
                              'Playlist \u2022 ${playlist.songs.length} brani',
                          coverUrl: _playlistMatchCover(playlist),
                          icon: CupertinoIcons.music_albums,
                          onTap: () {
                            PlaybackLogService.instance.log('UI',
                                'search: apri playlist "${playlist.title}"');
                            Navigator.push(
                              context,
                              CupertinoPageRoute(
                                builder: (_) => PlaylistScreen(
                                  playlist: playlist,
                                  audioHandler: widget.audioHandler,
                                ),
                              ),
                            );
                          },
                        );
                      }
                      final category =
                          categories[index - userPlaylists.length];
                      return _PlaylistMatchTile(
                        title: category.title,
                        subtitle: 'Playlist Spotify',
                        coverUrl: category.coverUrl,
                        icon: CupertinoIcons.news,
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
        icon: CupertinoIcons.search,
        title: 'Nessun risultato',
        subtitle: 'Prova con un altro titolo o artista.',
      );
    }

    return _buildBrowseAllView();
  }

  /// Spotify "Sfoglia tutto" view with tilted album artwork cards
  Widget _buildBrowseAllView() {
    final categories = SpotifyCatalogService.instance.browseCategories;
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (_recentSearches.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionHeader(
              'Ricerche recenti',
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.sm, AppSpacing.xs),
              trailing: TextButton(
                onPressed: _clearRecentSearches,
                child: Text('Cancella',
                    style: AppText.caption(cs).copyWith(color: cs.primary)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: _recentSearches.map((query) {
                  return ActionChip(
                    avatar: Icon(CupertinoIcons.time,
                        size: 14, color: cs.onSurfaceVariant),
                    label: Text(query),
                    backgroundColor: cs.surfaceContainerHigh,
                    labelStyle: TextStyle(
                      color: cs.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: AppRadius.chip),
                    side: BorderSide(color: cs.outlineVariant),
                    onPressed: () {
                      PlaybackLogService.instance
                          .log('UI', 'search: chip "$query"');
                      _searchController.text = query;
                      _submitSearch(query);
                    },
                  );
                }).toList(),
              ),
            ),
          ),
        ],

        // Suggested searches row
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: _suggestedQueries.map((query) {
                return ActionChip(
                  label: Text(query),
                  backgroundColor: cs.surfaceContainerHigh,
                  labelStyle: TextStyle(
                    color: cs.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  shape: RoundedRectangleBorder(
                      borderRadius: AppRadius.chip),
                  side: BorderSide(color: cs.outlineVariant),
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs, vertical: 2),
                  onPressed: () {
                    _searchController.text = query;
                    _submitSearch(query);
                  },
                );
              }).toList(),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),

        // Section Title: "Sfoglia tutto"
        const SliverToBoxAdapter(
          child: SectionHeader(
            'Sfoglia tutto',
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
          ),
        ),

        // 2-Column Grid of Spotify Category Cards with Tilted Artwork
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 120),
          sliver: SliverGrid.count(
            crossAxisCount: 2,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 1.65,
            children:
                categories.map((cat) => _buildSpotifyCategoryCard(cat)).toList(),
          ),
        ),
      ],
    );
  }

  /// The Spotify-signature category card with tilted cover peeking from bottom right
  Widget _buildSpotifyCategoryCard(SpotifyCategoryItem category) {
    return GestureDetector(
      onTap: () => _openCategory(category),
      child: Container(
        decoration: BoxDecoration(
          color: category.color,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Category Title on Top-Left
            Positioned(
              top: 12,
              left: 12,
              right: 48,
              child: Text(
                category.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),

            // Tilted Album Cover Peeking from Bottom Right (Signature Spotify Design)
            Positioned(
              bottom: -5,
              right: -15,
              child: Transform.rotate(
                angle: 25 * (math.pi / 180), // 25 degree clockwise tilt
                child: Container(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 10,
                        offset: const Offset(-2, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                    child: CachedNetworkImage(
                      imageUrl: category.coverUrl,
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                      memCacheWidth: 140,
                      memCacheHeight: 140,
                      placeholder: (_, _) => Container(color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.26)),
                      errorWidget: (_, _, _) => Container(color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.26)),
                    ),
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

/// Playlist row used by the search results: works for both the user's own
/// playlists and the Spotify browse categories.
class _PlaylistMatchTile extends StatelessWidget {
  const _PlaylistMatchTile({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: SizedBox(
          width: 52,
          height: 52,
          child: (coverUrl != null && coverUrl!.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: coverUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: 140,
                  memCacheHeight: 140,
                  placeholder: (_, _) => _placeholder(cs),
                  errorWidget: (_, _, _) => _placeholder(cs),
                )
              : _placeholder(cs),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.tileTitle(cs),
      ),
      subtitle: Text(
        subtitle,
        style: AppText.caption(cs),
      ),
      trailing: Icon(CupertinoIcons.chevron_right,
          color: cs.onSurfaceVariant, size: 16),
      onTap: onTap,
    );
  }

  Widget _placeholder(ColorScheme cs) => ColoredBox(
        color: cs.surfaceContainerHigh,
        child: Icon(icon, color: cs.onSurfaceVariant, size: 24),
      );
}

/// Best available cover for a playlist match: official cover, then the first
/// song thumbnail.
String? _playlistMatchCover(Playlist p) {
  if (p.thumbnailUrl != null && p.thumbnailUrl!.isNotEmpty) {
    return p.thumbnailUrl;
  }
  final withThumb = p.songs.where((s) => s.thumbnailUrl.isNotEmpty);
  if (withThumb.isNotEmpty) return withThumb.first.thumbnailUrl;
  return null;
}
