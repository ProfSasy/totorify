import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/auth_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/recommendation_service.dart';
import '../../services/spotify_catalog_service.dart';
import '../../services/storage_service.dart';
import '../app_navigation.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_cover.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/bounce_button.dart';
import '../widgets/cover_card.dart';
import '../widgets/filter_pill.dart';
import '../widgets/player_sheet.dart';
import '../widgets/section_header.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/song_tile.dart';
import '../widgets/top_bar.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class HomeScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const HomeScreen({super.key, required this.audioHandler});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Each chip is a Spotify editorial playlist.
  static final List<String> _categories =
      SpotifyCatalogService.homeCategories.keys.toList();
  static const int _categorySongs = 30;
  static const int _quickTiles = 8;
  String _selectedCategory = _categories.first;

  List<Song> _trendingSongs = [];
  bool _isLoading = true;
  int _trendingGeneration = 0;

  /// What is being opened (a playlist or a mix): its card shows a spinner
  /// and nothing else can be opened meanwhile.
  String? _openingId;

  // "Mix" cards: one per artist the user plays most.
  List<Artist> _mixArtists = const [];
  String _mixSignature = '';

  String? _savedUserName;
  final ValueNotifier<bool> _barSolid = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_onAuthChanged);
    StorageService.instance.historyNotifier.addListener(_refreshMixes);
    AuthService.instance.getSavedUserName().then((name) {
      if (!mounted || name == null || name.isEmpty) return;
      setState(() => _savedUserName = name);
    });
    _fetchTrending();
    _refreshMixes();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    StorageService.instance.historyNotifier.removeListener(_refreshMixes);
    _barSolid.dispose();
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

  /// Looks the mixes up again only when the artists played most change.
  void _refreshMixes() {
    final history = StorageService.instance.getHistory();
    final signature = RecommendationService.topArtistKeys(history).join('|');
    if (signature == _mixSignature) return;
    _mixSignature = signature;
    RecommendationService.instance.mixArtists(history).then((artists) {
      if (!mounted || _mixSignature != signature) return;
      setState(() => _mixArtists = artists);
    });
  }

  void _showUnavailable(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what non raggiungibile. Riprova tra poco.'),
        duration: const Duration(seconds: 2),
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

  void _play(Song song, List<Song> queue) {
    widget.audioHandler.playSong(song, queue: queue);
    PlayerSheet.show(context, widget.audioHandler);
  }

  void _openPlaylist(Playlist playlist) {
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

  /// Loads what a card stands for, with a spinner on the card meanwhile.
  Future<void> _open(
    String id, {
    required String what,
    required Future<List<Song>> Function() load,
    required void Function(List<Song> songs) then,
  }) async {
    if (_openingId != null) return;
    setState(() => _openingId = id);
    try {
      final songs = await load();
      if (!mounted) return;
      if (songs.isEmpty) {
        _showUnavailable(what);
      } else {
        then(songs);
      }
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _openSpotifyPlaylist(SpotifyPlaylistBundle bundle) {
    PlaybackLogService.instance.log('UI', 'home: apri playlist "${bundle.title}"');
    return _open(
      bundle.id,
      what: 'Playlist',
      load: () => SpotifyCatalogService.instance.getPlaylistSongs(bundle.id),
      then: (songs) => _openPlaylist(Playlist(
        id: bundle.id,
        title: bundle.title,
        description: bundle.subtitle,
        thumbnailUrl: bundle.coverUrl,
        songs: songs,
        isSystem: true,
      )),
    );
  }

  Future<void> _openMix(Artist artist) {
    PlaybackLogService.instance.log('UI', 'home: apri mix "${artist.name}"');
    return _open(
      'mix_${artist.id}',
      what: 'Mix',
      load: () => RecommendationService.instance.mixOf(artist),
      then: (songs) => _openPlaylist(Playlist(
        id: 'mix_${artist.id}',
        title: 'Mix ${artist.name}',
        description: '${artist.name} e artisti simili, scelti per te',
        thumbnailUrl: artist.imageUrl,
        songs: songs,
        isSystem: true,
      )),
    );
  }

  void _openFavorites() {
    final favorites = StorageService.instance.getFavorites();
    PlaybackLogService.instance.log('UI', 'home: apri preferiti');
    _openPlaylist(Playlist(
      id: 'system_favorites',
      title: 'Brani che ti piacciono',
      songs: favorites,
      isSystem: true,
    ));
  }

  void _openHistory() {
    final history = StorageService.instance.getHistory();
    PlaybackLogService.instance.log('UI', 'home: apri cronologia');
    if (history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Qui troverai i brani che ascolti.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    _openPlaylist(Playlist(
      id: 'history',
      title: 'Ascoltati di recente',
      description: 'I tuoi ultimi brani riprodotti',
      songs: history,
      thumbnailUrl: history.first.thumbnailUrl,
      isSystem: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final storage = StorageService.instance;
    final topInset = TopBar.extent(context);
    final backdrop = NowPlayingBackdrop(audioHandler: widget.audioHandler);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: backdrop),
          NotificationListener<ScrollNotification>(
            onNotification: TopBar.watch(_barSolid),
            child: RefreshIndicator(
              edgeOffset: topInset,
              onRefresh: () {
                PlaybackLogService.instance.log('UI', 'home: refresh');
                return _fetchTrending(refresh: true);
              },
              color: cs.onPrimary,
              backgroundColor: cs.primary,
              child: CustomScrollView(
                controller: AppNavigation.rootScrollers[AppNavigation.homeTab],
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: topInset + AppSpacing.sm)),

                  // ── Quick access: favourites, recents, charts ───────────
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    sliver: ListenableBuilder(
                      listenable: Listenable.merge([
                        storage.historyNotifier,
                        widget.audioHandler.playbackIndicator,
                      ]),
                      builder: (context, _) => _buildQuickGrid(cs),
                    ),
                  ),

                  // ── Mixes built on the listening history ────────────────
                  if (_mixArtists.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SectionHeader('Mix per te')),
                    SliverToBoxAdapter(
                      child: _CardRow(
                        height: CoverCard.heightFor(150, subtitleLines: 2),
                        itemCount: _mixArtists.length,
                        itemBuilder: (context, index) {
                          final artist = _mixArtists[index];
                          return CoverCard(
                            imageUrl: artist.imageUrl,
                            title: 'Mix ${artist.name}',
                            subtitle: '${artist.name} e artisti simili',
                            subtitleLines: 2,
                            size: 150,
                            badge: 'MIX',
                            icon: AppIcons.radio,
                            busy: _openingId == 'mix_${artist.id}',
                            onTap: () => _openMix(artist),
                          );
                        },
                      ),
                    ),
                  ],

                  // ── Recently played ─────────────────────────────────────
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<List<Song>>(
                      valueListenable: storage.historyNotifier,
                      builder: (context, history, _) {
                        if (history.isEmpty) return const SizedBox.shrink();
                        final recent = history.take(12).toList();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SectionHeader(
                              'Ascoltati di recente',
                              trailing: _SeeAll(onTap: _openHistory),
                            ),
                            _CardRow(
                              height: CoverCard.heightFor(118),
                              itemCount: recent.length,
                              itemBuilder: (context, index) {
                                final song = recent[index];
                                return CoverCard(
                                  imageUrl: song.thumbnailUrl,
                                  title: song.title,
                                  subtitle: song.artist,
                                  size: 118,
                                  onTap: () {
                                    PlaybackLogService.instance
                                        .log('UI', 'home: play "${song.title}"');
                                    _play(song, history);
                                  },
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  // ── Followed artists ────────────────────────────────────
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<List<Artist>>(
                      valueListenable: storage.followedArtistsNotifier,
                      builder: (context, artists, _) {
                        if (artists.isEmpty) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SectionHeader('I tuoi artisti'),
                            _CardRow(
                              height: CoverCard.heightFor(118),
                              itemCount: artists.length,
                              itemBuilder: (context, index) => CoverCard(
                                imageUrl: artists[index].imageUrl,
                                title: artists[index].name,
                                subtitle: 'Artista',
                                size: 118,
                                circle: true,
                                icon: AppIcons.artist,
                                onTap: () => ArtistScreen.open(
                                  context,
                                  widget.audioHandler,
                                  artist: artists[index],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  // ── The user's playlists ────────────────────────────────
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<List<Playlist>>(
                      valueListenable: storage.playlistsNotifier,
                      builder: (context, playlists, _) {
                        if (playlists.isEmpty) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SectionHeader('Le tue playlist'),
                            _CardRow(
                              height: CoverCard.heightFor(140),
                              itemCount: playlists.length,
                              itemBuilder: (context, index) {
                                final playlist = playlists[index];
                                return CoverCard(
                                  imageUrl: playlistCoverUrl(playlist),
                                  title: playlist.title,
                                  subtitle: '${playlist.songs.length} brani',
                                  icon: AppIcons.playlist,
                                  onTap: () {
                                    PlaybackLogService.instance.log('UI',
                                        'home: apri playlist "${playlist.title}"');
                                    _openPlaylist(playlist);
                                  },
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  // ── Charts and new releases ─────────────────────────────
                  const SliverToBoxAdapter(
                      child: SectionHeader('Classifiche e novità')),
                  SliverToBoxAdapter(
                    child: _CardRow(
                      height: CoverCard.heightFor(150, subtitleLines: 2),
                      itemCount:
                          SpotifyCatalogService.instance.featuredPlaylists.length,
                      itemBuilder: (context, index) {
                        final bundle =
                            SpotifyCatalogService.instance.featuredPlaylists[index];
                        return CoverCard(
                          imageUrl: bundle.coverUrl,
                          title: bundle.title,
                          subtitle: bundle.subtitle,
                          subtitleLines: 2,
                          size: 150,
                          icon: AppIcons.playlist,
                          busy: _openingId == bundle.id,
                          onTap: () => _openSpotifyPlaylist(bundle),
                        );
                      },
                    ),
                  ),

                  // ── Songs by category ───────────────────────────────────
                  const SliverToBoxAdapter(child: SectionHeader('Da ascoltare ora')),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 34,
                      child: ListView.separated(
                        padding:
                            const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                        scrollDirection: Axis.horizontal,
                        itemCount: _categories.length,
                        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
                        itemBuilder: (context, index) {
                          final category = _categories[index];
                          return FilterPill(
                            label: category,
                            selected: category == _selectedCategory,
                            onTap: () {
                              if (category == _selectedCategory) return;
                              PlaybackLogService.instance
                                  .log('UI', 'home: categoria $category');
                              setState(() => _selectedCategory = category);
                              _fetchTrending();
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.sm)),

                  if (_isLoading)
                    const SliverToBoxAdapter(child: SongListSkeleton(count: 6))
                  else if (_trendingSongs.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.xl),
                        child: Center(
                          child: Text(
                            'Nessun brano trovato. Trascina in basso per riprovare.',
                            textAlign: TextAlign.center,
                            style: AppText.caption(cs),
                          ),
                        ),
                      ),
                    )
                  else
                    ValueListenableBuilder<(String?, bool)>(
                      valueListenable: widget.audioHandler.playbackIndicator,
                      builder: (context, indicator, _) {
                        final currentId = indicator.$2 ? indicator.$1 : null;
                        return SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = _trendingSongs[index];
                              return SongTile(
                                song: song,
                                isPlaying: currentId == song.id,
                                onTap: () => _play(song, _trendingSongs),
                              );
                            },
                            childCount: _trendingSongs.length,
                          ),
                        );
                      },
                    ),
                  const SliverToBoxAdapter(
                      child: SizedBox(height: AppSpacing.bottomContentInset)),
                ],
              ),
            ),
          ),

          // ── Header: profile, greeting, history and settings ─────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopBar(
              solid: _barSolid,
              backdrop: backdrop,
              child: Row(
                children: [
                  const ProfileButton(),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _firstName().isEmpty
                            ? _greeting()
                            : '${_greeting()}, ${_firstName()}',
                        maxLines: 1,
                        style: AppText.screenTitle(cs).copyWith(fontSize: 22),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Ascoltati di recente',
                    icon: const Icon(AppIcons.history, size: 26),
                    onPressed: _openHistory,
                  ),
                  IconButton(
                    tooltip: 'Impostazioni',
                    icon: const Icon(AppIcons.settings, size: 25),
                    onPressed: () => ProfileButton.openSettings(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Two columns of shortcuts: the favourites first, then the songs played
  /// last, and the charts where the history is still short.
  Widget _buildQuickGrid(ColorScheme cs) {
    final history = StorageService.instance.historyNotifier.value;
    final indicator = widget.audioHandler.playbackIndicator.value;
    final playingId = indicator.$2 ? indicator.$1 : null;

    final seen = <String>{};
    final recent = history
        .where((song) => seen.add(song.id))
        .take(_quickTiles - 1)
        .toList();
    final charts = SpotifyCatalogService.instance.featuredPlaylists
        .take(_quickTiles - 1 - recent.length);

    final tiles = <Widget>[
      _QuickTile(
        title: 'Brani che ti piacciono',
        cover: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [cs.primary, AppTheme.lift(cs.primary, 0.45)],
            ),
          ),
          child: Icon(AppIcons.heartFilled, color: cs.onPrimary, size: 24),
        ),
        onTap: _openFavorites,
      ),
      for (final song in recent)
        _QuickTile(
          title: song.title,
          cover: AppCover(url: song.thumbnailUrl, size: _QuickTile.height, radius: 0),
          playing: playingId == song.id,
          onTap: () {
            PlaybackLogService.instance.log('UI', 'home: play "${song.title}"');
            _play(song, history);
          },
        ),
      for (final bundle in charts)
        _QuickTile(
          title: bundle.title,
          cover: AppCover(
            url: bundle.coverUrl,
            size: _QuickTile.height,
            radius: 0,
            icon: AppIcons.playlist,
          ),
          busy: _openingId == bundle.id,
          onTap: () => _openSpotifyPlaylist(bundle),
        ),
    ];

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: _QuickTile.height,
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
      ),
      delegate: SliverChildListDelegate(tiles),
    );
  }
}

/// A shortcut of the Home grid: small cover, two lines of title.
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.title,
    required this.cover,
    required this.onTap,
    this.playing = false,
    this.busy = false,
  });

  static const double height = 56;

  final String title;
  final Widget cover;
  final bool playing;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return BounceButton(
      onPressed: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: [
            SizedBox.square(dimension: height, child: cover),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: CupertinoActivityIndicator(radius: 8),
              )
            else if (playing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: PlayingBars(color: cs.primary, height: 14),
              )
            else
              const SizedBox(width: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// A horizontal row of cards with the page margins.
class _CardRow extends StatelessWidget {
  const _CardRow({
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.lg),
        itemBuilder: itemBuilder,
      ),
    );
  }
}

class _SeeAll extends StatelessWidget {
  const _SeeAll({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.md, top: 4, bottom: 4),
        child: Text(
          'Mostra tutto',
          style: AppText.caption(cs).copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
