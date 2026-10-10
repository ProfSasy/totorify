import 'dart:async';

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
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/mini_player.dart';
import '../widgets/player_sheet.dart';
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
    return Navigator.of(context).push(
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

  String get _wantedName =>
      widget.artist?.name ?? DeezerService.primaryArtist(widget.song!.artist);

  @override
  void initState() {
    super.initState();
    _artist = widget.artist;
    _load();
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final artist = _artist;
    final page = _page;

    return Scaffold(
      backgroundColor: colorScheme.surfaceDim,
      bottomNavigationBar: SafeArea(
        top: false,
        child: MiniPlayer(audioHandler: widget.audioHandler),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AmbientBackdrop(
              artworkUrl: (artist?.imageUrl.isNotEmpty ?? false) ? artist!.imageUrl : null,
              intensity: 0.35,
            ),
          ),
          CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverAppBar(
                pinned: true,
                elevation: 0,
                backgroundColor: colorScheme.surface.withValues(alpha: 0.85),
                leading: IconButton(
                  icon: Icon(CupertinoIcons.back, color: colorScheme.onSurface),
                  onPressed: () => Navigator.pop(context),
                ),
                title: Text(
                  artist?.name ?? _wantedName,
                  style: AppText.screenTitle(colorScheme),
                ),
              ),
              if (artist == null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _loading
                      ? const Center(child: CupertinoActivityIndicator())
                      : AppEmptyState(
                          icon: CupertinoIcons.person_crop_circle_badge_xmark,
                          title: 'Artista non trovato',
                          subtitle: 'Non ho trovato "$_wantedName" nel catalogo.',
                          actionLabel: 'Riprova',
                          onAction: _load,
                        ),
                )
              else ...[
                SliverToBoxAdapter(child: _buildHeader(artist, colorScheme)),
                if (_loading)
                  const SliverToBoxAdapter(child: SongListSkeleton(count: 5))
                else if (page == null)
                  SliverToBoxAdapter(
                    child: AppEmptyState(
                      icon: CupertinoIcons.wifi_exclamationmark,
                      title: 'Pagina non disponibile',
                      subtitle: 'Non sono riuscito a leggere la pagina di ${artist.name}.',
                      actionLabel: 'Riprova',
                      onAction: _load,
                    ),
                  )
                else
                  ..._buildSections(page, colorScheme),
                const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
              ],
            ],
          ),
        ],
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
        _buildSongs(popular, page.topSongs),
        if (page.allSongs != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton(
                onPressed: _openingAllSongs ? null : _openAllSongs,
                child: _openingAllSongs
                    ? const CupertinoActivityIndicator(radius: 9)
                    : const Text('Mostra tutti i brani'),
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

  Widget _buildHeader(Artist artist, ColorScheme colorScheme) {
    final topSongs = _page?.topSongs ?? const <Song>[];
    // Something to start from even when the catalog has no "popular" list.
    final playable = topSongs.isNotEmpty ? topSongs : _appearsOn;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        children: [
          ArtistAvatar(artist: artist, size: 168),
          const SizedBox(height: AppSpacing.lg),
          Text(
            artist.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.display(colorScheme),
          ),
          if (artist.audience.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(artist.audience, style: AppText.caption(colorScheme)),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ValueListenableBuilder<List<Artist>>(
                valueListenable: StorageService.instance.followedArtistsNotifier,
                builder: (context, _, _) {
                  final following =
                      StorageService.instance.isFollowingArtist(artist.id);
                  return OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: following
                          ? colorScheme.primary
                          : colorScheme.onSurface,
                      side: BorderSide(
                        color: following
                            ? colorScheme.primary
                            : colorScheme.onSurface.withValues(alpha: 0.3),
                      ),
                      shape: const StadiumBorder(),
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
                    icon: Icon(
                      following ? CupertinoIcons.checkmark : CupertinoIcons.plus,
                      size: 16,
                    ),
                    label: Text(following ? 'Segui già' : 'Segui'),
                  );
                },
              ),
              const SizedBox(width: AppSpacing.md),
              FilledButton.icon(
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: playable.isEmpty
                    ? null
                    : () => _play(playable.first, playable),
                icon: const Icon(CupertinoIcons.play_fill, size: 16),
                label: const Text('Riproduci'),
              ),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                tooltip: 'Riproduzione casuale',
                onPressed: playable.isEmpty
                    ? null
                    : () {
                        final shuffled = List<Song>.from(playable)..shuffle();
                        _play(shuffled.first, shuffled);
                      },
                icon: Icon(CupertinoIcons.shuffle, color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSongs(List<Song> visible, List<Song> queue) {
    return ValueListenableBuilder<(String?, bool)>(
      valueListenable: widget.audioHandler.playbackIndicator,
      builder: (context, indicator, _) {
        final playingId = indicator.$2 ? indicator.$1 : null;
        return SliverList(
          delegate: SliverChildListDelegate([
            for (final song in visible)
              SongTile(
                song: song,
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
      height: 206,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: releases.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
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
      height: 148,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: related.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
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
        child: Text(
          description,
          maxLines: _showFullBio ? null : 4,
          overflow: _showFullBio ? TextOverflow.visible : TextOverflow.ellipsis,
          style: AppText.caption(colorScheme).copyWith(height: 1.45),
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: _size,
      height: _size,
      color: colorScheme.surfaceContainerHigh,
      child: Icon(CupertinoIcons.music_albums,
          size: 44, color: colorScheme.onSurfaceVariant),
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: _size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: album.coverUrl.isEmpty
                  ? placeholder
                  : CachedNetworkImage(
                      imageUrl: album.coverUrl,
                      width: _size,
                      height: _size,
                      fit: BoxFit.cover,
                      memCacheWidth: 420,
                      placeholder: (_, _) => placeholder,
                      errorWidget: (_, _, _) => placeholder,
                    ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption(colorScheme).copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              album.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption(colorScheme),
            ),
          ],
        ),
      ),
    );
  }
}

/// Round artist picture with a placeholder for missing images.
class ArtistAvatar extends StatelessWidget {
  final Artist artist;
  final double size;

  const ArtistAvatar({super.key, required this.artist, required this.size});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: colorScheme.surfaceContainerHigh,
      child: Icon(CupertinoIcons.person_fill,
          size: size * 0.45, color: colorScheme.onSurfaceVariant),
    );

    return ClipOval(
      child: artist.imageUrl.isEmpty
          ? placeholder
          : CachedNetworkImage(
              imageUrl: artist.imageUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              memCacheWidth: (size * 3).round(),
              placeholder: (_, _) => placeholder,
              errorWidget: (_, _, _) => placeholder,
            ),
    );
  }
}

/// Avatar with the artist name underneath, for horizontal artist rows.
class ArtistChip extends StatelessWidget {
  final Artist artist;
  final VoidCallback onTap;

  const ArtistChip({super.key, required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: 104,
        child: Column(
          children: [
            ArtistAvatar(artist: artist, size: 96),
            const SizedBox(height: AppSpacing.sm),
            Text(
              artist.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption(colorScheme)
                  .copyWith(color: colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
