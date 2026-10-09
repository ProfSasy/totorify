import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/artist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/deezer_service.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/app_skeleton.dart';
import '../widgets/mini_player.dart';
import '../widgets/player_sheet.dart';
import '../widgets/section_header.dart';
import '../widgets/song_tile.dart';

/// Artist page: follow, popular tracks and similar artists.
///
/// Opens either from a known [artist] or from a [song], whose artist is
/// resolved against the catalog first.
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
  static const int _collapsedTracks = 5;

  Artist? _artist;
  List<Song> _topSongs = [];
  List<Artist> _related = [];
  bool _loading = true;
  bool _showAllTracks = false;

  @override
  void initState() {
    super.initState();
    _artist = widget.artist;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final artist = widget.artist ??
        await DeezerService.instance.artistOf(widget.song!);
    if (artist == null) {
      if (!mounted) return;
      setState(() {
        _artist = null;
        _loading = false;
      });
      return;
    }
    if (mounted) setState(() => _artist = artist);

    final results = await Future.wait([
      DeezerService.instance.artistTopSongs(artist.id),
      DeezerService.instance.relatedArtists(artist.id),
      // Search results carry no fan count: fetch the full profile.
      if (artist.fans == 0) DeezerService.instance.getArtist(artist.id),
    ]);
    if (!mounted) return;

    final full = results.length > 2 ? results[2] as Artist? : null;
    setState(() {
      _artist = full ?? artist;
      _topSongs = results[0] as List<Song>;
      _related = results[1] as List<Artist>;
      _loading = false;
    });
  }

  String _formatFans(int fans) {
    if (fans >= 1000000) return '${(fans / 1000000).toStringAsFixed(1)} mln di fan';
    if (fans >= 1000) return '${(fans / 1000).toStringAsFixed(0)} mila fan';
    return '$fans fan';
  }

  void _play(Song song) {
    widget.audioHandler.playSong(song, queue: _topSongs);
    PlayerSheet.show(context, widget.audioHandler);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final artist = _artist;

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
                  artist?.name ?? widget.song?.artist ?? '',
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
                          subtitle:
                              'Non ho trovato "${widget.song?.artist ?? ''}" nel catalogo.',
                          actionLabel: 'Riprova',
                          onAction: _load,
                        ),
                )
              else ...[
                SliverToBoxAdapter(child: _buildHeader(artist, colorScheme)),
                const SliverToBoxAdapter(child: SectionHeader('Popolari')),
                if (_loading)
                  const SliverToBoxAdapter(child: SongListSkeleton(count: 5))
                else if (_topSongs.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text('Nessun brano disponibile.',
                          style: AppText.caption(colorScheme)),
                    ),
                  )
                else
                  _buildTopSongs(colorScheme),
                if (_related.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionHeader('Artisti simili')),
                  SliverToBoxAdapter(child: _buildRelated(colorScheme)),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(Artist artist, ColorScheme colorScheme) {
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
          if (artist.fans > 0) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_formatFans(artist.fans), style: AppText.caption(colorScheme)),
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
                onPressed:
                    _topSongs.isEmpty ? null : () => _play(_topSongs.first),
                icon: const Icon(CupertinoIcons.play_fill, size: 16),
                label: const Text('Riproduci'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopSongs(ColorScheme colorScheme) {
    final visible = _showAllTracks
        ? _topSongs
        : _topSongs.take(_collapsedTracks).toList();
    final canExpand = _topSongs.length > _collapsedTracks;

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
                onTap: () => _play(song),
              ),
            if (canExpand)
              Center(
                child: TextButton(
                  onPressed: () =>
                      setState(() => _showAllTracks = !_showAllTracks),
                  child: Text(_showAllTracks ? 'Mostra meno' : 'Mostra altri'),
                ),
              ),
          ]),
        );
      },
    );
  }

  Widget _buildRelated(ColorScheme colorScheme) {
    return SizedBox(
      height: 148,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: _related.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
        itemBuilder: (context, index) => ArtistChip(
          artist: _related[index],
          onTap: () => ArtistScreen.open(
            context,
            widget.audioHandler,
            artist: _related[index],
          ),
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
