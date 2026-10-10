import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/album.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/ytmusic_catalog_service.dart';
import '../widgets/app_empty_state.dart';
import 'playlist_screen.dart';

/// Page of a release (album, single or EP): loads its tracks and shows them
/// like any other collection, with play, shuffle and download.
class AlbumScreen extends StatefulWidget {
  final Album album;
  final AudioPlayerHandler audioHandler;

  const AlbumScreen({super.key, required this.album, required this.audioHandler});

  static Future<void> open(
    BuildContext context,
    AudioPlayerHandler audioHandler,
    Album album,
  ) {
    PlaybackLogService.instance
        .log('UI', 'apri ${album.type.toLowerCase()} "${album.title}" di ${album.artist}');
    return Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => AlbumScreen(album: album, audioHandler: audioHandler),
      ),
    );
  }

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  late Future<(Album, List<Song>)?> _tracks = _load();

  Future<(Album, List<Song>)?> _load() =>
      YTMusicCatalogService.instance.albumTracks(widget.album);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(Album, List<Song>)?>(
      future: _tracks,
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        if (loaded != null) {
          final (album, songs) = loaded;
          return PlaylistScreen(
            audioHandler: widget.audioHandler,
            playlist: Playlist(
              id: 'album_${album.id}',
              title: album.title,
              description: [album.caption, if (album.artist.isNotEmpty) album.artist]
                  .join(' • '),
              thumbnailUrl: album.coverUrl,
              songs: songs,
              isSystem: true,
            ),
          );
        }

        final colorScheme = Theme.of(context).colorScheme;
        final waiting = snapshot.connectionState != ConnectionState.done;
        return Scaffold(
          backgroundColor: colorScheme.surfaceDim,
          appBar: AppBar(
            backgroundColor: colorScheme.surface,
            leading: IconButton(
              icon: Icon(CupertinoIcons.back, color: colorScheme.onSurface),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(widget.album.title),
          ),
          body: waiting
              ? const Center(child: CupertinoActivityIndicator())
              : AppEmptyState(
                  icon: CupertinoIcons.music_albums,
                  title: 'Brani non disponibili',
                  subtitle: 'Non sono riuscito a leggere "${widget.album.title}".',
                  actionLabel: 'Riprova',
                  onAction: () => setState(() => _tracks = _load()),
                ),
        );
      },
    );
  }
}
