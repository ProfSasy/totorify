import 'dart:async';

import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/deezer_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../../services/ytmusic_catalog_service.dart';
import '../app_navigation.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/collection_header.dart';
import '../widgets/cover_card.dart';
import '../widgets/play_button.dart';
import '../widgets/player_sheet.dart';
import '../widgets/top_bar.dart';
import '../widgets/section_header.dart';
import '../widgets/song_tile.dart';
import 'album_screen.dart';
import 'playlist_screen.dart';

/// Artist page: popular tracks, albums, singles and EPs, the tracks the
/// artist appears on, similar artists and a short biography.
///
/// Opens either from a known [artist] or from a [song], whose first credited
/// artist is looked up in the catalog.
class ArtistScreen extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final Artist? artist;
  final Song? song;

  const ArtistScreen({
    super.key,
    required this.audioHandler,
    this.artist,
    this.song,
  }) : assert(artist != null || song != null);

  static Future<void> open(
    BuildContext context,
    AudioPlayerHandler audioHandler, {
    Artist? artist,
    Song? song,
  }) {
    // Also opened from sheets, which live above the tabs.
    return AppNavigation.push(
      context,
      CupertinoPageRoute<void>(
        builder: (_) => ArtistScreen(
          audioHandler: audioHandler,
          artist: artist,
          song: song,
        ),
      ),
    );
  }

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  static const int _popularShown = 5;
  // Below this many songs and releases of their own, an artist's page is
  // filled with the videos that exist only on YouTube.
  static const int _smallCatalog = 5;

  Artist? _artist;
  ArtistPage? _page;
  List<Album> _singles = const [];
  List<Album> _albums = const [];
  List<Song> _appearsOn = const [];
  bool _loading = true;
  bool _loadingExtras = false;
  bool _openingAllSongs = false;
  bool _showFullBio = false;

  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  String get _wantedName =>
      widget.artist?.name ?? DeezerService.primaryArtist(widget.song!.artist);

  @override
  void initState() {
    super.initState();
    _artist = widget.artist;
    _load();
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final catalog = YTMusicCatalogService.instance;
    final log = PlaybackLogService.instance;
    setState(() => _loading = true);

    var artist = widget.artist;
    if (artist == null || !YTMusicCatalogService.isCatalogArtistId(artist.id)) {
      final found = await catalog.findArtist(_wantedName);
      if (!mounted) return;
      if (found == null) {
        log.log('ARTIST', '"$_wantedName" non trovato nel catalogo');
        setState(() {
          _artist = null;
          _loading = false;
        });
        return;
      }
      // An artist followed with an older version keeps its place.
      if (artist != null) {
        await StorageService.instance.replaceFollowedArtist(artist.id, found);
      }
      artist = found;
    }
    if (!mounted) return;
    setState(() => _artist = artist);

    final page = await catalog.artistPage(artist.id);
    if (!mounted) return;
    if (page == null) {
      log.log('ARTIST', 'pagina di "${artist.name}" non leggibile');
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _page = page;
      _artist = page.artist;
      _albums = page.albums;
      _singles = page.singles;
      _loading = false;
      _loadingExtras = true;
    });
    // The followed copy takes the picture and numbers of the page.
    unawaited(StorageService.instance.replaceFollowedArtist(page.artist.id, page.artist));

    // What the page only hints at: every release, and the tracks by others.
    final ownTitles = [
      ...page.topSongs.map((s) => s.title),
      ...page.albums.map((a) => a.title),
      ...page.singles.map((a) => a.title),
    ];
    final extras = await Future.wait([
      catalog.appearsOn(
        page.artist,
        ownTitles: ownTitles,
        includeOwnVideos: ownTitles.length < _smallCatalog,
      ),
      page.moreSingles == null
          ? Future.value(page.singles)
          : catalog.releases(page.moreSingles!, artist: page.artist.name, kind: 'Single'),
      page.moreAlbums == null
          ? Future.value(page.albums)
          : catalog.releases(page.moreAlbums!, artist: page.artist.name, kind: 'Album'),
    ]);
    if (!mounted) return;
    final singles = extras[1] as List<Album>;
    final albums = extras[2] as List<Album>;
    setState(() {
      _appearsOn = extras[0] as List<Song>;
      if (singles.isNotEmpty) _singles = singles;
      if (albums.isNotEmpty) _albums = albums;
      _loadingExtras = false;
    });
    log.log(
      'ARTIST',
      '"${page.artist.name}": ${page.topSongs.length} popolari, ${_albums.length} album, '
      '${_singles.length} singoli/EP, ${_appearsOn.length} collaborazioni, '
      '${page.related.length} simili',
    );
  }

  void _play(Song song, List<Song> queue) {
    widget.audioHandler.playSong(song, queue: queue);
    PlayerSheet.show(context, widget.audioHandler);
  }

  Future<void> _openAllSongs() async {
    final page = _page;
    if (page?.allSongs == null || _openingAllSongs) return;
    setState(() => _openingAllSongs = true);
    final songs = await YTMusicCatalogService.instance
        .playlistTracks(page!.allSongs!, fallbackArtist: page.artist.name);
    if (!mounted) return;
    setState(() => _openingAllSongs = false);
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Elenco dei brani non disponibile. Riprova tra poco.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    Navigator.push(
      context,
      CupertinoPageRoute<void>(
        builder: (_) => PlaylistScreen(
          audioHandler: widget.audioHandler,
          playlist: Playlist(
            id: 'artist_songs_${page.artist.id}',
            title: page.artist.name,
            description: 'Tutti i brani',
            thumbnailUrl: page.artist.imageUrl,
            songs: songs,
            isSystem: true,
          ),
        ),
      ),
    );
  }

  /// Height of the picture at the top of the page.
  double _heroHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return math.min(size.width * 0.92, size.height * 0.44);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final artist = _artist;
    final page = _page;
    final imageUrl =
        (artist?.imageUrl.isNotEmpty ?? false) ? artist!.imageUrl : null;
    final heroHeight = _heroHeight(context);

    return Scaffold(
      backgroundColor: colorScheme.surfaceDim,
      body: AmbientTint(
        artworkUrl: imageUrl,
        fallback: colorScheme.primary,
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
                  if (artist == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _loading
                          ? const Center(child: CupertinoActivityIndicator())
                          : AppEmptyState(
                              icon: AppIcons.artistMissing,
                              title: 'Artista non trovato',
                              subtitle:
                                  'Non ho trovato "$_wantedName" nel catalogo.',
                              actionLabel: 'Riprova',
                              onAction: _load,
                            ),
                    )
                  else ...[
                    SliverToBoxAdapter(
                      child: _buildHero(artist, imageUrl, palette, heroHeight),
                    ),
                    SliverToBoxAdapter(
                      child: _buildActions(artist, palette, colorScheme),
                    ),
                    if (_loading)
                      const SliverToBoxAdapter(child: SongListSkeleton(count: 5))
                    else if (page == null)
                      SliverToBoxAdapter(
                        child: AppEmptyState(
                          icon: AppIcons.offline,
                          title: 'Pagina non disponibile',
                          subtitle:
                              'Non sono riuscito a leggere la pagina di ${artist.name}.',
                          actionLabel: 'Riprova',
                          onAction: _load,
                        ),
                      )
                    else
                      ..._buildSections(page, colorScheme),
                    const SliverToBoxAdapter(
                        child: SizedBox(height: AppSpacing.bottomContentInset)),
                  ],
                ],
              ),
            ),
            CollectionTopBar(
              title: artist?.name ?? _wantedName,
              palette: palette,
              scrollOffset: _scrollOffset,
              scrim: true,
              revealAt: heroHeight - TopBar.extent(context) - 56,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSections(ArtistPage page, ColorScheme colorScheme) {
    final popular = page.topSongs.take(_popularShown).toList();
    final nothing = popular.isEmpty &&
        _albums.isEmpty &&
        _singles.isEmpty &&
        _appearsOn.isEmpty &&
        !_loadingExtras;

    return [
      if (nothing)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              'Nessun brano di ${page.artist.name} nel catalogo.',
              style: AppText.caption(colorScheme),
            ),
          ),
        ),
      if (popular.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Popolari')),
        _buildSongs(popular, page.topSongs, numbered: true),
        if (page.allSongs != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Center(
                child: OutlinedButton(
                  onPressed: _openingAllSongs ? null : _openAllSongs,
                  child: _openingAllSongs
                      ? const CupertinoActivityIndicator(radius: 8)
                      : const Text('Mostra tutti i brani'),
                ),
              ),
            ),
          ),
      ],
      if (_albums.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Album')),
        SliverToBoxAdapter(child: _buildReleases(_albums)),
      ],
      if (_singles.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Singoli ed EP')),
        SliverToBoxAdapter(child: _buildReleases(_singles)),
      ],
      if (_appearsOn.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Collaborazioni e altri brani')),
        _buildSongs(_appearsOn, _appearsOn),
      ] else if (_loadingExtras)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Center(child: CupertinoActivityIndicator()),
          ),
        ),
      if (page.related.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Artisti simili')),
        SliverToBoxAdapter(child: _buildRelated(page.related)),
      ],
      if (page.description.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Informazioni')),
        SliverToBoxAdapter(child: _buildBio(page.description, colorScheme)),
      ],
    ];
  }

  /// The artist's picture, edge to edge, with the name over its lower part.
  Widget _buildHero(
    Artist artist,
    String? imageUrl,
    AmbientPalette palette,
    double height,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.surface, palette.deep],
        ),
      ),
      child: Icon(
        AppIcons.artist,
        size: height * 0.42,
        color: Colors.white.withValues(alpha: 0.18),
      ),
    );

    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Pulled down past its top, the page leaves no gap: the picture
          // stays attached to the edge of the screen and grows.
          ValueListenableBuilder<double>(
            valueListenable: _scrollOffset,
            builder: (context, offset, picture) {
              final pull = offset < 0 ? -offset : 0.0;
              return Positioned(
                top: -pull,
                left: 0,
                right: 0,
                height: height + pull,
                child: picture!,
              );
            },
            child: imageUrl == null
                ? placeholder
                : CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    memCacheWidth: (MediaQuery.sizeOf(context).width *
                            MediaQuery.devicePixelRatioOf(context))
                        .round(),
                    fadeInDuration: const Duration(milliseconds: 220),
                    placeholder: (_, _) => placeholder,
                    errorWidget: (_, _, _) => placeholder,
                  ),
          ),
          // The picture melts into the page, and darkens under the clock.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.35),
                      Colors.black.withValues(alpha: 0),
                      colorScheme.surfaceDim.withValues(alpha: 0),
                      colorScheme.surfaceDim,
                    ],
                    stops: const [0.0, 0.28, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            bottom: AppSpacing.sm,
            child: Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.display(colorScheme).copyWith(
                fontSize: 42,
                fontWeight: FontWeight.w900,
                letterSpacing: -1.4,
                height: 1.02,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(
    Artist artist,
    AmbientPalette palette,
    ColorScheme colorScheme,
  ) {
    final topSongs = _page?.topSongs ?? const <Song>[];
    // Something to start from even when the catalog has no "popular" list.
    final playable = topSongs.isNotEmpty ? topSongs : _appearsOn;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (artist.audience.isNotEmpty)
            Text(artist.audience, style: AppText.tileSubtitle(colorScheme)),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              ValueListenableBuilder<List<Artist>>(
                valueListenable: StorageService.instance.followedArtistsNotifier,
                builder: (context, _, _) {
                  final following =
                      StorageService.instance.isFollowingArtist(artist.id);
                  return OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          following ? palette.accent : colorScheme.onSurface,
                      side: BorderSide(
                        color: following ? palette.accent : colorScheme.outline,
                      ),
                    ),
                    onPressed: () {
                      PlaybackLogService.instance.log(
                        'UI',
                        following
                            ? 'artista: smetti di seguire "${artist.name}"'
                            : 'artista: segui "${artist.name}"',
                      );
                      StorageService.instance.toggleFollowArtist(artist);
                    },
                    child: Text(following ? 'Segui già' : 'Segui'),
                  );
                },
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Riproduzione casuale',
                onPressed: playable.isEmpty
                    ? null
                    : () {
                        final shuffled = List<Song>.from(playable)..shuffle();
                        _play(shuffled.first, shuffled);
                      },
                icon: Icon(AppIcons.shuffle,
                    size: 28, color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: AppSpacing.sm),
              ValueListenableBuilder<(String?, bool)>(
                valueListenable: widget.audioHandler.playbackIndicator,
                builder: (context, indicator, _) {
                  final currentId = widget.audioHandler.currentSong?.id;
                  final isCurrent = currentId != null &&
                      playable.any((song) => song.id == currentId);
                  final playing = isCurrent && indicator.$2;
                  return PlayButton(
                    color: palette.accent,
                    playing: playing,
                    onPressed: playable.isEmpty
                        ? null
                        : () {
                            if (playing) {
                              widget.audioHandler.pause();
                            } else if (isCurrent) {
                              widget.audioHandler.play();
                            } else {
                              _play(playable.first, playable);
                            }
                          },
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSongs(List<Song> visible, List<Song> queue, {bool numbered = false}) {
    return ValueListenableBuilder<(String?, bool)>(
      valueListenable: widget.audioHandler.playbackIndicator,
      builder: (context, indicator, _) {
        final playingId = indicator.$2 ? indicator.$1 : null;
        return SliverList(
          delegate: SliverChildListDelegate([
            for (final (i, song) in visible.indexed)
              SongTile(
                song: song,
                index: numbered ? i + 1 : null,
                isPlaying: playingId == song.id,
                onTap: () => _play(song, queue),
              ),
          ]),
        );
      },
    );
  }

  Widget _buildReleases(List<Album> releases) {
    return SizedBox(
      height: AlbumCard.rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: releases.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.lg),
        itemBuilder: (context, index) => AlbumCard(
          album: releases[index],
          onTap: () =>
              AlbumScreen.open(context, widget.audioHandler, releases[index]),
        ),
      ),
    );
  }

  Widget _buildRelated(List<Artist> related) {
    return SizedBox(
      height: ArtistChip.rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: related.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.lg),
        itemBuilder: (context, index) => ArtistChip(
          artist: related[index],
          onTap: () => ArtistScreen.open(
            context,
            widget.audioHandler,
            artist: related[index],
          ),
        ),
      ),
    );
  }

  Widget _buildBio(String description, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showFullBio = !_showFullBio),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: AppRadius.card,
          ),
          child: Text(
            description,
            maxLines: _showFullBio ? null : 5,
            overflow: _showFullBio ? TextOverflow.visible : TextOverflow.ellipsis,
            style: AppText.tileSubtitle(colorScheme).copyWith(height: 1.45),
          ),
        ),
      ),
    );
  }
}

/// Square cover of a release with its title and kind, for horizontal rows.
class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;

  const AlbumCard({super.key, required this.album, required this.onTap});

  static const double _size = 140;

  /// Height of a row of these cards.
  static double get rowHeight => CoverCard.heightFor(_size);

  @override
  Widget build(BuildContext context) => CoverCard(
        imageUrl: album.coverUrl,
        title: album.title,
        subtitle: album.caption,
        size: _size,
        icon: AppIcons.album,
        onTap: onTap,
      );
}

/// Round picture with the artist name underneath, for horizontal rows.
class ArtistChip extends StatelessWidget {
  final Artist artist;
  final VoidCallback onTap;

  const ArtistChip({super.key, required this.artist, required this.onTap});

  static const double _size = 116;

  /// Height of a row of these cards.
  static double get rowHeight => CoverCard.heightFor(_size);

  @override
  Widget build(BuildContext context) => CoverCard(
        imageUrl: artist.imageUrl,
        title: artist.name,
        subtitle: 'Artista',
        size: _size,
        circle: true,
        icon: AppIcons.artist,
        onTap: onTap,
      );
}
