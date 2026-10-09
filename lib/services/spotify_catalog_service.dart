import 'dart:async';
import 'package:flutter/material.dart';
import '../models/song.dart';
import 'spotify_service.dart';

class SpotifyCategoryItem {
  final String title;
  final Color color;
  final String playlistId;
  final String coverUrl;

  const SpotifyCategoryItem({
    required this.title,
    required this.color,
    required this.playlistId,
    required this.coverUrl,
  });
}

class SpotifyPlaylistBundle {
  final String id;
  final String title;
  final String subtitle;
  final String coverUrl;

  const SpotifyPlaylistBundle({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
  });
}

/// Spotify's editorial playlists and charts shown on the Home and Search
/// screens. Their tracks are read from Spotify's public embed pages.
///
/// Every id below was checked against the playlist it names: an id that
/// points somewhere else shows the wrong music under the right title.
class SpotifyCatalogService {
  static final SpotifyCatalogService instance = SpotifyCatalogService._internal();
  SpotifyCatalogService._internal();

  final Map<String, List<Song>> _cachedPlaylists = {};

  static const String top50ItalyId = '37i9dQZEVXbIQnj7RRhdSX';
  static const String top50GlobalId = '37i9dQZEVXbMDoHDwVN2tF';
  static const String hotHitsItaliaId = '37i9dQZF1DX6wfQutivYYr';
  static const String newMusicFridayItaliaId = '37i9dQZF1DWVKDF4ycOESi';
  static const String todayTopHitsId = '37i9dQZF1DXcBWIGoYBM5M';
  static const String viralHitsId = '37i9dQZF1DX2L0iB23Enbq';
  static const String rapCaviarId = '37i9dQZF1DX0XUsuxWHRQd';
  static const String chillHitsId = '37i9dQZF1DX4WYpdgoIcn6';
  static const String workoutId = '37i9dQZF1DX70RN3TfWWJh';

  static const String _top50ItalyCover =
      'https://charts-images.scdn.co/assets/locale_en/regional/daily/region_it_large.jpg';
  static const String _top50GlobalCover =
      'https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_large.jpg';
  static const String _hotHitsItaliaCover =
      'https://i.scdn.co/image/ab67706f00000002cb64faffda27af7d42bc2a75';
  static const String _newMusicFridayItaliaCover =
      'https://i.scdn.co/image/ab67706f0000000268b984c5a906f5154bc92ac9';
  static const String _todayTopHitsCover =
      'https://i.scdn.co/image/ab67706f00000002526040498d89ec622e9d3495';
  static const String _viralHitsCover =
      'https://i.scdn.co/image/ab67706f00000002204335eb7d241ef0dbf5c5ad';
  static const String _rapCaviarCover =
      'https://i.scdn.co/image/ab67706f00000002785c58430ad4196ef17ab19d';

  /// Playlists of the Home carousel.
  final List<SpotifyPlaylistBundle> featuredPlaylists = const [
    SpotifyPlaylistBundle(
      id: top50ItalyId,
      title: 'Top 50 - Italia',
      subtitle: 'I brani più ascoltati in Italia, aggiornati ogni giorno.',
      coverUrl: _top50ItalyCover,
    ),
    SpotifyPlaylistBundle(
      id: hotHitsItaliaId,
      title: 'Hot Hits Italia',
      subtitle: 'Le hit del momento in Italia.',
      coverUrl: _hotHitsItaliaCover,
    ),
    SpotifyPlaylistBundle(
      id: newMusicFridayItaliaId,
      title: 'New Music Friday Italia',
      subtitle: 'Le nuove uscite della settimana.',
      coverUrl: _newMusicFridayItaliaCover,
    ),
    SpotifyPlaylistBundle(
      id: top50GlobalId,
      title: 'Top 50 - Global',
      subtitle: 'I 50 brani più ascoltati nel mondo.',
      coverUrl: _top50GlobalCover,
    ),
    SpotifyPlaylistBundle(
      id: todayTopHitsId,
      title: 'Today’s Top Hits',
      subtitle: 'I successi internazionali del momento.',
      coverUrl: _todayTopHitsCover,
    ),
    SpotifyPlaylistBundle(
      id: viralHitsId,
      title: 'Viral Hits',
      subtitle: 'I brani più virali su social e streaming.',
      coverUrl: _viralHitsCover,
    ),
  ];

  /// Playlists behind the category chips of the Home, by chip label.
  static const Map<String, String> homeCategories = {
    'Top Hits Italia': hotHitsItaliaId,
    'Nuove Uscite': newMusicFridayItaliaId,
    'Rap': rapCaviarId,
    'Relax & Chill': chillHitsId,
    'Workout': workoutId,
  };

  /// "Sfoglia tutto" tiles of the Search screen.
  final List<SpotifyCategoryItem> browseCategories = const [
    SpotifyCategoryItem(
      title: 'Pop & Hit',
      color: Color(0xFF148A08),
      playlistId: todayTopHitsId,
      coverUrl: _todayTopHitsCover,
    ),
    SpotifyCategoryItem(
      title: 'Hip-Hop',
      color: Color(0xFFBC5900),
      playlistId: rapCaviarId,
      coverUrl: _rapCaviarCover,
    ),
    SpotifyCategoryItem(
      title: 'Classifiche Italia',
      color: Color(0xFF8D67AB),
      playlistId: top50ItalyId,
      coverUrl: _top50ItalyCover,
    ),
    SpotifyCategoryItem(
      title: 'Hit del momento',
      color: Color(0xFF283EA3),
      playlistId: hotHitsItaliaId,
      coverUrl: _hotHitsItaliaCover,
    ),
    SpotifyCategoryItem(
      title: 'Viral Hits',
      color: Color(0xFFE91429),
      playlistId: viralHitsId,
      coverUrl: _viralHitsCover,
    ),
    SpotifyCategoryItem(
      title: 'Global Top 50',
      color: Color(0xFFD84000),
      playlistId: top50GlobalId,
      coverUrl: _top50GlobalCover,
    ),
  ];

  /// Tracks of a Spotify playlist, with their album covers. Kept for the
  /// session; [refresh] reads the playlist again (charts change daily).
  /// Empty when Spotify cannot be reached.
  Future<List<Song>> getPlaylistSongs(String playlistId, {bool refresh = false}) async {
    final cached = _cachedPlaylists[playlistId];
    if (cached != null && !refresh) return cached;

    try {
      final spotifyData = await SpotifyService.instance.fetchPlaylist(playlistId);
      if (spotifyData != null && spotifyData.tracks.isNotEmpty) {
        final songs = spotifyData.tracks.map((t) {
          final cover = SpotifyService.instance.getCachedCover(t.trackId);
          return Song(
            id: 'spotify_${t.trackId}',
            title: t.title,
            artist: t.artist,
            // The embed page does not say the album: the playlist stands in,
            // and the player shows it as where the track is playing from.
            album: spotifyData.title,
            duration: Duration(milliseconds: t.durationMs),
            thumbnailUrl: cover ?? spotifyData.coverUrl ?? '',
            spotifyTrackId: t.trackId,
          );
        }).toList();

        // Covers of the first tracks before showing the list; the rest
        // follows in the background.
        const firstBatch = 20;
        final topIds = spotifyData.tracks.take(firstBatch).map((t) => t.trackId).toList();
        final initialCovers =
            await SpotifyService.instance.fetchTrackCoversBatch(topIds, concurrency: 6);
        for (var i = 0; i < songs.length; i++) {
          final cover = initialCovers[spotifyData.tracks[i].trackId];
          if (cover != null) songs[i] = songs[i].copyWith(thumbnailUrl: cover);
        }

        _cachedPlaylists[playlistId] = songs;

        if (songs.length > firstBatch) {
          unawaited(() async {
            final remainingIds =
                spotifyData.tracks.skip(firstBatch).map((t) => t.trackId).toList();
            // Slowly: nobody is waiting for these, and a burst of requests
            // gets the whole app rate-limited by Spotify.
            final covers =
                await SpotifyService.instance.fetchTrackCoversBatch(remainingIds, concurrency: 2);
            // Skipped when the playlist was read again meanwhile.
            if (!identical(_cachedPlaylists[playlistId], songs)) return;
            for (var i = firstBatch; i < songs.length; i++) {
              final cover = covers[spotifyData.tracks[i].trackId];
              if (cover != null) songs[i] = songs[i].copyWith(thumbnailUrl: cover);
            }
          }());
        }

        return songs;
      }
    } catch (e) {
      debugPrint('SpotifyCatalogService.getPlaylistSongs error: $e');
    }

    // Spotify could not be read: what was loaded before is better than
    // nothing, and nothing is better than unrelated songs under this title.
    return cached ?? const [];
  }
}
