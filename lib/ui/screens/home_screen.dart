import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/auth_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/spotify_catalog_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/player_sheet.dart';
import '../widgets/section_header.dart';
import '../widgets/song_tile.dart';
import 'playlist_screen.dart';

class HomeScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const HomeScreen({super.key, required this.audioHandler});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // Each chip is a Spotify editorial playlist.
  static final List<String> _categories =
      SpotifyCatalogService.homeCategories.keys.toList();
  static const int _categorySongs = 30;
  String _selectedCategory = _categories.first;

  List<Song> _trendingSongs = [];
  bool _isLoading = true;
  int _trendingGeneration = 0;
  bool _openingPlaylist = false;

  String? _savedUserName;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_onAuthChanged);
    AuthService.instance.getSavedUserName().then((name) {
      if (!mounted || name == null || name.isEmpty) return;
      setState(() => _savedUserName = name);
    });
    _fetchTrending();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  Future<void> _fetchTrending({bool refresh = false}) async {
    final generation = ++_trendingGeneration;
    final playlistId = SpotifyCatalogService.homeCategories[_selectedCategory]!;
    setState(() => _isLoading = true);
    final songs = await SpotifyCatalogService.instance
        .getPlaylistSongs(playlistId, refresh: refresh);
    // A stale response from a previously selected chip must not overwrite
    // the list of the current one.
    if (!mounted || generation != _trendingGeneration) return;
    setState(() {
      _trendingSongs = songs.take(_categorySongs).toList();
      _isLoading = false;
    });
  }

  void _showPlaylistUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Playlist non raggiungibile. Riprova tra poco.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) return 'Buongiorno';
    if (hour >= 12 && hour < 18) return 'Buon pomeriggio';
    return 'Buonasera';
  }

  /// Only the given name: the header greets "Mario", not "Mario Rossi".
  /// The full name stays available in Settings → Account.
  String _firstName() {
    final raw = AuthService.instance.currentUser?.displayName?.trim() ??
        _savedUserName?.trim() ??
        '';
    if (raw.isEmpty) return '';
    return raw.split(RegExp(r'\s+')).first;
  }

  /// Header greeting: a soft salutation followed by the given name in full
  /// emphasis. A FittedBox guarantees the whole line is always visible —
  /// it scales down instead of truncating, at any name length or text size.
  Widget _greetingTitle(ColorScheme cs, {double fontSize = 30}) {
    final greeting = _greeting();
    final name = _firstName();
    final base = AppText.display(cs).copyWith(fontSize: fontSize);
    final Widget line;
    if (name.isEmpty) {
      line = Text(greeting, maxLines: 1, style: base);
    } else {
      line = Text.rich(
        TextSpan(
          text: '$greeting, ',
          style: base.copyWith(
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.65),
          ),
          children: [TextSpan(text: name, style: base)],
        ),
        maxLines: 1,
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: line,
    );
  }

  Future<void> _openSpotifyPlaylist(SpotifyPlaylistBundle bundle) async {
    if (_openingPlaylist) return;
    _openingPlaylist = true;
    PlaybackLogService.instance.log('UI', 'home: apri playlist "${bundle.title}"');
    try {
      // Show instant feedback with cached songs or load dynamically
      final songs =
          await SpotifyCatalogService.instance.getPlaylistSongs(bundle.id);
      if (!mounted) return;
      if (songs.isEmpty) {
        _showPlaylistUnavailable();
        return;
      }

      final pl = Playlist(
        id: bundle.id,
        title: bundle.title,
        description: bundle.subtitle,
        thumbnailUrl: bundle.coverUrl,
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
      _openingPlaylist = false;
    }
  }

  Future<void> _playSpotifyPlaylist(SpotifyPlaylistBundle bundle) async {
    if (_openingPlaylist) return;
    _openingPlaylist = true;
    PlaybackLogService.instance.log('UI', 'home: play playlist "${bundle.title}"');
    try {
      final songs =
          await SpotifyCatalogService.instance.getPlaylistSongs(bundle.id);
      if (!mounted) return;
      if (songs.isEmpty) {
        _showPlaylistUnavailable();
        return;
      }

      widget.audioHandler.playSong(songs.first, queue: songs);
      PlayerSheet.show(context, widget.audioHandler);
    } finally {
      _openingPlaylist = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final primaryColor = Theme.of(context).colorScheme.primary;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          // Ambient aurora: echoes the track that is playing (or the accent
          // when silent) behind the whole screen, so browsing stays
          // connected to the music.
          Positioned.fill(
            child: StreamBuilder<MediaItem?>(
              stream: widget.audioHandler.mediaItem,
              builder: (context, snapshot) => AmbientBackdrop(
                artworkUrl: snapshot.data?.artUri?.toString(),
                intensity: 0.7,
              ),
            ),
          ),
          SafeArea(
            top: false,
            bottom: false,
            child: RefreshIndicator(
              onRefresh: () {
                PlaybackLogService.instance.log('UI', 'home: refresh');
                return _fetchTrending(refresh: true);
              },
              color: primaryColor,
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  // ── 1. Top bar: greeting & utility icons ───────────────────
                  SliverAppBar(
                    backgroundColor: cs.surface.withValues(alpha: 0.85),
                    pinned: true,
                    elevation: 0,
                    titleSpacing: 16,
                    centerTitle: false,
                    title: _greetingTitle(cs, fontSize: 24),
                    actions: [
                      IconButton(
                        tooltip: 'Ascoltati di recente',
                        icon: Icon(CupertinoIcons.time,
                            size: 24, color: cs.onSurface),
                        onPressed: () {
                          final history = StorageService.instance.getHistory();
                          if (history.isNotEmpty) {
                            Navigator.push(
                              context,
                              CupertinoPageRoute(
                                builder: (_) => PlaylistScreen(
                                  playlist: Playlist(
                                    id: 'history',
                                    title: 'Ascoltati di recente',
                                    description: 'I tuoi ultimi brani riprodotti',
                                    songs: history,
                                    thumbnailUrl: history.first.thumbnailUrl,
                                    isSystem: true,
                                  ),
                                  audioHandler: widget.audioHandler,
                                ),
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),

                  // Two-column quick-access grid, reactive to the history list.
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: ValueListenableBuilder<List<Song>>(
                        valueListenable: StorageService.instance.historyNotifier,
                        builder: (context, recent, _) {
                          final tiles = recent.isEmpty
                              ? <Widget>[
                                  _buildFavoritesQuickTile(),
                                  ...SpotifyCatalogService.instance.featuredPlaylists
                                      .take(5)
                                      .map(_buildSpotifyQuickTile),
                                ]
                              : recent
                                  .take(6)
                                  .map((song) => _buildRecentQuickTile(song, recent))
                                  .toList();
                          return GridView.count(
                            crossAxisCount: 2,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 2.8,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: tiles,
                          );
                        },
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 24)),

                  // ── 3. Horizontal Carousel: Classifiche Ufficiali Spotify ─────
                  SliverToBoxAdapter(
                    child: SectionHeader(
                      'Classifiche in evidenza',
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs),
                      trailing: Text(
                        'In evidenza',
                        style: AppText.caption(Theme.of(context).colorScheme)
                            .copyWith(color: primaryColor, letterSpacing: 0.4),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 215,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        scrollDirection: Axis.horizontal,
                        itemCount: SpotifyCatalogService.instance.featuredPlaylists.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 14),
                        itemBuilder: (context, index) {
                          final bundle = SpotifyCatalogService.instance.featuredPlaylists[index];
                          return _buildFeaturedPlaylistCard(bundle);
                        },
                      ),
                    ),
                  ),

                  // ── 4. Horizontal Carousel: Ascoltati di Recente ─────────────
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<List<Song>>(
                      valueListenable: StorageService.instance.historyNotifier,
                      builder: (context, history, _) {
                        if (history.isEmpty) return const SizedBox.shrink();

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SectionHeader(
                              'Ascoltati di recente',
                              padding: EdgeInsets.fromLTRB(
                                  AppSpacing.lg,
                                  AppSpacing.lg,
                                  AppSpacing.lg,
                                  AppSpacing.xs),
                            ),
                            SizedBox(
                              height: 185,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                scrollDirection: Axis.horizontal,
                                itemCount: history.take(10).length,
                                separatorBuilder: (_, _) => const SizedBox(width: 14),
                                itemBuilder: (context, index) {
                                  final song = history[index];
                                  return _buildRecentSongCard(song, history);
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 12)),

                  // ── 5. Category Filter Pills ──────────────────────────────────
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 40,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        scrollDirection: Axis.horizontal,
                        itemCount: _categories.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final cat = _categories[index];
                          final isSelected = cat == _selectedCategory;
                          return ChoiceChip(
                            showCheckmark: false,
                            label: Text(cat),
                            selected: isSelected,
                            onSelected: (selected) {
                              if (selected) {
                                PlaybackLogService.instance
                                    .log('UI', 'home: categoria $cat');
                                setState(() => _selectedCategory = cat);
                                _fetchTrending();
                              }
                            },
                            selectedColor: primaryColor,
                            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                            labelStyle: TextStyle(
                              color: isSelected ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                              fontSize: 13,
                            ),
                            shape: RoundedRectangleBorder(borderRadius: AppRadius.chip),
                            side: isSelected
                                ? BorderSide.none
                                : BorderSide(
                                    color: Theme.of(context).colorScheme.outlineVariant,
                                  ),
                          );
                        },
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 12)),

                  // ── 6. Section Header: Hit del Momento ────────────────────────
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _selectedCategory,
                            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                          ),
                          if (_trendingSongs.isNotEmpty)
                            TextButton.icon(
                              icon: Icon(CupertinoIcons.play_circle_fill, color: primaryColor, size: 18),
                              label: Text(
                                'Riproduci Tutti',
                                style: TextStyle(color: primaryColor, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () {
                                PlaybackLogService.instance.log(
                                    'UI', 'home: riproduci tutti $_selectedCategory');
                                widget.audioHandler.playSong(_trendingSongs.first, queue: _trendingSongs);
                                PlayerSheet.show(context, widget.audioHandler);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),

                  // ── 7. Reactive Song List with Live Indicator ─────────────────
                  if (_isLoading)
                    const SliverToBoxAdapter(
                      child: SongListSkeleton(count: 6),
                    )
                  else if (_trendingSongs.isEmpty)
                     SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 40),
                        child: Center(
                          child: Text('Nessun brano trovato.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ),
                      ),
                    )
                  else
                    ValueListenableBuilder<(String?, bool)>(
                      valueListenable: widget.audioHandler.playbackIndicator,
                      builder: (context, indicator, _) {
                        final currentId = indicator.$2 ? indicator.$1 : null;

                        return SliverPadding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.bottomContentInset),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final song = _trendingSongs[index];
                                final isPlaying = currentId == song.id;

                                return SongTile(
                                  song: song,
                                  isPlaying: isPlaying,
                                  onTap: () {
                                    widget.audioHandler.playSong(song, queue: _trendingSongs);
                                    PlayerSheet.show(context, widget.audioHandler);
                                  },
                                );
                              },
                              childCount: _trendingSongs.length,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Quick tile that opens the favourites.
  Widget _buildFavoritesQuickTile() {
    return InkWell(
      onTap: () {
        final favorites = StorageService.instance.getFavorites();
        if (favorites.isNotEmpty) {
          Navigator.push(
            context,
            CupertinoPageRoute(
              builder: (_) => PlaylistScreen(
                playlist: Playlist(
                  id: 'system_favorites',
                  title: 'Brani che ti piacciono',
                  description: 'Tutti i tuoi brani preferiti',
                  songs: favorites,
                  thumbnailUrl: favorites.first.thumbnailUrl,
                  isSystem: true,
                ),
                audioHandler: widget.audioHandler,
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Nessun brano nei preferiti. Tocca il cuore per aggiungerne uno!'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient(Theme.of(context).colorScheme),
              ),
              child: Icon(
                CupertinoIcons.heart_fill,
                color: Theme.of(context).colorScheme.onPrimary,
                size: 24,
              ),
            ),
            const SizedBox(width: 8),
             Expanded(
              child: Text(
                'Brani che ti piacciono',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentQuickTile(Song song, List<Song> queue) {
    return InkWell(
      onTap: () {
        widget.audioHandler.playSong(song, queue: queue);
        PlayerSheet.show(context, widget.audioHandler);
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            CachedNetworkImage(
              imageUrl: song.thumbnailUrl,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              placeholder: (_, _) => Container(
                  color: Theme.of(context).colorScheme.surface),
              errorWidget: (_, _, _) => Container(
                  color: Theme.of(context).colorScheme.surface),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Semantics(
                button: true,
                label: 'Riproduci ${song.title}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    PlaybackLogService.instance
                        .log('UI', 'home: play "${song.title}"');
                    widget.audioHandler.playSong(song, queue: queue);
                    PlayerSheet.show(context, widget.audioHandler);
                  },
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppTheme.primaryGradient(
                              Theme.of(context).colorScheme),
                        ),
                        child: Icon(
                          CupertinoIcons.play_fill,
                          color: Theme.of(context).colorScheme.onPrimary,
                          size: 14,
                        ),
                      ),
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

  /// Quick-access tile of a playlist: cover on the left, play on the right.
  Widget _buildSpotifyQuickTile(SpotifyPlaylistBundle bundle) {
    return InkWell(
      onTap: () => _openSpotifyPlaylist(bundle),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            CachedNetworkImage(
              imageUrl: bundle.coverUrl,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              memCacheWidth: 120,
              memCacheHeight: 120,
              placeholder: (_, _) => Container(color: Theme.of(context).colorScheme.surface),
              errorWidget: (_, _, _) => Container(color: Theme.of(context).colorScheme.surface),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                bundle.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Semantics(
                button: true,
                label: 'Riproduci ${bundle.title}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _playSpotifyPlaylist(bundle),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppTheme.primaryGradient(
                              Theme.of(context).colorScheme),
                        ),
                        child: Icon(
                          CupertinoIcons.play_fill,
                          color: Theme.of(context).colorScheme.onPrimary,
                          size: 14,
                        ),
                      ),
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

  /// Square cover card of the playlist carousel.
  Widget _buildFeaturedPlaylistCard(SpotifyPlaylistBundle bundle) {
    return GestureDetector(
      onTap: () => _openSpotifyPlaylist(bundle),
      child: SizedBox(
        width: 145,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: CachedNetworkImage(
                      imageUrl: bundle.coverUrl,
                      width: 145,
                      height: 145,
                      fit: BoxFit.cover,
                      memCacheWidth: 290,
                      memCacheHeight: 290,
                      placeholder: (_, _) => Container(color: Theme.of(context).colorScheme.surface),
                      errorWidget: (_, _, _) => Container(color: Theme.of(context).colorScheme.surface),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () => _playSpotifyPlaylist(bundle),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppTheme.primaryGradient(
                            Theme.of(context).colorScheme),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(
                        CupertinoIcons.play_fill,
                        color: Theme.of(context).colorScheme.onPrimary,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              bundle.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
            ),
            const SizedBox(height: 2),
            Text(
              bundle.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }

  /// Square cover card of a recently played song.
  Widget _buildRecentSongCard(Song song, List<Song> queue) {
    return GestureDetector(
      onTap: () {
        widget.audioHandler.playSong(song, queue: queue);
        PlayerSheet.show(context, widget.audioHandler);
      },
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CachedNetworkImage(
                imageUrl: song.thumbnailUrl,
                width: 120,
                height: 120,
                fit: BoxFit.cover,
                memCacheWidth: 240,
                memCacheHeight: 240,
                placeholder: (_, _) => Container(color: Theme.of(context).colorScheme.surface),
                errorWidget: (_, _, _) => Container(color: Theme.of(context).colorScheme.surface),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}
