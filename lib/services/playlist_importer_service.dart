import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import 'cover_art_service.dart';
import 'spotify_service.dart';
import 'storage_service.dart';
import 'ytmusic_service.dart';
import 'track_matcher_service.dart';

class PlaylistImporterService {
  static final PlaylistImporterService instance = PlaylistImporterService._internal();
  PlaylistImporterService._internal();

  /// Importa una playlist da link (Spotify o YouTube Music) ad altissima velocità.
  Future<Playlist?> importFromUrl(
    String url, {
    void Function(int current, int total)? onProgress,
  }) async {
    final cleanUrl = url.trim();

    if (cleanUrl.contains('spotify.com') || cleanUrl.startsWith('spotify:')) {
      return _importFromSpotifyInstant(cleanUrl, onProgress: onProgress);
    } else {
      return _importFromYouTube(cleanUrl, onProgress: onProgress);
    }
  }

  /// Importazione ISTANTANEA da Spotify:
  /// Scarica l'intera playlist con copertina originale Spotify e minutaggi esatti in < 1 secondo!
  /// Risolve in background le copertine dei singoli album e gli ID di riproduzione.
  Future<Playlist?> _importFromSpotifyInstant(
    String spotifyUrl, {
    void Function(int current, int total)? onProgress,
  }) async {
    try {
      final spotifyData = await SpotifyService.instance.fetchPlaylist(spotifyUrl);
      if (spotifyData == null || spotifyData.tracks.isEmpty) {
        debugPrint('SpotifyService: playlist non trovata o vuota');
        return null;
      }

      onProgress?.call(1, spotifyData.tracks.length);

      final songs = <Song>[];
      for (final t in spotifyData.tracks) {
        songs.add(Song(
          id: 'spotify_${t.trackId}',
          title: t.title,
          artist: t.artist,
          duration: Duration(milliseconds: t.durationMs), // Minutaggio ESATTO Spotify!
          thumbnailUrl: spotifyData.coverUrl ?? '', // Copertina originale Spotify!
          spotifyTrackId: t.trackId,
        ));
      }

      // Crea e salva la playlist in Hive in UNA SOLA operazione atomica
      final playlist = Playlist(
        id: 'playlist_${DateTime.now().millisecondsSinceEpoch}',
        title: spotifyData.title,
        description: spotifyData.description,
        thumbnailUrl: spotifyData.coverUrl,
        songs: songs,
      );

      await StorageService.instance.savePlaylist(playlist);
      onProgress?.call(songs.length, songs.length);

      // Avvia in background il perfezionamento HD delle copertine e il pre-caching dello streaming
      _refinePlaylistInBackground(playlist);

      return playlist;
    } catch (e) {
      debugPrint('PlaylistImporterService._importFromSpotifyInstant error: $e');
      return null;
    }
  }

  /// Perfeziona in background con un pool concorrente le copertine degli album (640x640 HD)
  /// e pre-risolve gli ID YouTube per una riproduzione a latenza zero.
  void _refinePlaylistInBackground(Playlist playlist) {
    unawaited(() async {
      const concurrency = 4;
      final songsToProcess = List<Song>.from(playlist.songs);
      if (songsToProcess.isEmpty) return;

      int index = 0;
      final updates = <String, Song>{};

      Future<void> flushUpdates() async {
        if (updates.isEmpty) return;
        final toApply = Map<String, Song>.from(updates);
        updates.clear();
        await StorageService.instance.batchUpdateSongsInPlaylist(playlist.id, toApply);
      }

      final flushTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
        unawaited(flushUpdates().catchError((Object e) {
          debugPrint('PlaylistImporterService.flush: $e');
        }));
      });

      Future<void> worker() async {
        while (index < songsToProcess.length) {
          final i = index++;
          final song = songsToProcess[i];
          final trackId = song.spotifyTrackId;
          if (trackId == null) continue;

          try {
            // 1. Recupera copertina HD album Spotify
            final hdCover = await SpotifyService.instance.fetchTrackCoverHD(trackId);

            // 2. Pre-risolve il video YouTube da riprodurre e lo mette in cache
            final ytId = StorageService.instance.getCachedYouTubeMapping(song.id) ??
                await TrackMatcherService.instance.resolveAndCacheStreamId(song);

            // copyWith keeps the old value when ytId is null (no match).
            final updated = song.copyWith(
              thumbnailUrl: hdCover ?? song.thumbnailUrl,
              youtubeVideoId: ytId,
            );
            updates[song.id] = updated;
          } catch (e) {
            debugPrint('PlaylistImporterService background worker on song ${song.title}: $e');
          }
        }
      }

      final futures = List.generate(
        concurrency.clamp(1, songsToProcess.length),
        (_) => worker(),
      );
      await Future.wait(futures);
      flushTimer.cancel();
      await flushUpdates();
    }());
  }

  /// YouTube playlists come with video thumbnails: swap them for the
  /// official album covers once the playlist is saved.
  void _upgradeCoversInBackground(Playlist playlist) {
    unawaited(() async {
      try {
        final updates = <String, Song>{};
        final upgraded =
            await CoverArtService.instance.withOriginalCovers(playlist.songs);
        for (var i = 0; i < upgraded.length; i++) {
          if (upgraded[i].thumbnailUrl != playlist.songs[i].thumbnailUrl) {
            updates[upgraded[i].id] = upgraded[i];
          }
        }
        if (updates.isEmpty) return;
        await StorageService.instance
            .batchUpdateSongsInPlaylist(playlist.id, updates);
      } catch (e) {
        debugPrint('PlaylistImporterService._upgradeCoversInBackground: $e');
      }
    }());
  }

  Future<Playlist?> _importFromYouTube(
    String url, {
    void Function(int current, int total)? onProgress,
  }) async {
    final ytPlaylist = await YTMusicService.instance.getPlaylist(url);
    if (ytPlaylist == null) return null;

    final created = Playlist(
      id: 'playlist_${DateTime.now().millisecondsSinceEpoch}',
      title: ytPlaylist.title,
      description: ytPlaylist.description,
      thumbnailUrl: ytPlaylist.thumbnailUrl,
      songs: ytPlaylist.songs,
    );

    await StorageService.instance.savePlaylist(created);
    onProgress?.call(ytPlaylist.songs.length, ytPlaylist.songs.length);
    _upgradeCoversInBackground(created);

    return created;
  }

}
