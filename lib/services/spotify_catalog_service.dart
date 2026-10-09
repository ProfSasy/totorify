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

/// Service that provides curated Spotify categories, charts, and playlist bundles
/// with 100% authentic Spotify metadata and instant caching.
class SpotifyCatalogService {
  static final SpotifyCatalogService instance = SpotifyCatalogService._internal();
  SpotifyCatalogService._internal();

  // In-memory cache for loaded playlist songs
  final Map<String, List<Song>> _cachedPlaylists = {};

  // Official Spotify Chart and Playlist IDs (100% verified & active)
  static const String top50ItalyId = '37i9dQZEVXbIQnj7RRhdSX';
  static const String top50GlobalId = '37i9dQZEVXbMDoHDwVN2tF';
  static const String canzoniDelMomentoId = '37i9dQZF1DX8Uebhn9wzrS';
  static const String generazioneZId = '37i9dQZF1DWZjqjZMudx9T';
  static const String todayTopHitsId = '37i9dQZF1DXcBWIGoYBM5M';
  static const String viralHitsId = '37i9dQZF1DX2L0iB23Enbq';

  /// Featured Spotify playlists for the Home Screen carousels
  final List<SpotifyPlaylistBundle> featuredPlaylists = const [
    SpotifyPlaylistBundle(
      id: top50ItalyId,
      title: 'Top 50 - Italia',
      subtitle: 'Il tuo aggiornamento quotidiano sui brani più ascoltati in Italia.',
      coverUrl: 'https://charts-images.scdn.co/assets/locale_en/regional/daily/region_it_large.jpg',
    ),
    SpotifyPlaylistBundle(
      id: canzoniDelMomentoId,
      title: 'Canzoni del Momento',
      subtitle: 'Tutte le hit e i brani più ascoltati in Italia in questo momento.',
      coverUrl: 'https://i.scdn.co/image/ab67706f00000002b273294dd0290a183d2cb2f9',
    ),
    SpotifyPlaylistBundle(
      id: generazioneZId,
      title: 'Generazione Z',
      subtitle: 'Il meglio del rap, trap e urban italiano: Sfera, Geolier, Capo Plaza, Lazza.',
      coverUrl: 'https://i.scdn.co/image/ab67706f00000002b93849553b3be1a2fe7e4e1a',
    ),
    SpotifyPlaylistBundle(
      id: top50GlobalId,
      title: 'Top 50 - Global',
      subtitle: 'I 50 brani più ascoltati in tutto il mondo in questo momento.',
      coverUrl: 'https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_large.jpg',
    ),
    SpotifyPlaylistBundle(
      id: todayTopHitsId,
      title: 'Today’s Top Hits',
      subtitle: 'I più grandi successi internazionali del momento.',
      coverUrl: 'https://i.scdn.co/image/ab67706f0000000271992d3b45eb1297df9c6bf7',
    ),
    SpotifyPlaylistBundle(
      id: viralHitsId,
      title: 'Viral Hits',
      subtitle: 'I brani più virali e di tendenza su social e streaming.',
      coverUrl: 'https://charts-images.scdn.co/assets/locale_en/viral/daily/region_global_large.jpg',
    ),
  ];

  /// Spotify "Sfoglia tutto" (Browse All) category tiles
  final List<SpotifyCategoryItem> browseCategories = const [
    SpotifyCategoryItem(
      title: 'Pop & Hit',
      color: Color(0xFF148A08),
      playlistId: todayTopHitsId,
      coverUrl: 'https://i.scdn.co/image/ab67706f0000000271992d3b45eb1297df9c6bf7',
    ),
    SpotifyCategoryItem(
      title: 'Hip-Hop & Trap',
      color: Color(0xFFBC5900),
      playlistId: generazioneZId,
      coverUrl: 'https://i.scdn.co/image/ab67706f00000002b93849553b3be1a2fe7e4e1a',
    ),
    SpotifyCategoryItem(
      title: 'Classifiche Italia',
      color: Color(0xFF8D67AB),
      playlistId: top50ItalyId,
      coverUrl: 'https://charts-images.scdn.co/assets/locale_en/regional/daily/region_it_large.jpg',
    ),
    SpotifyCategoryItem(
      title: 'Canzoni del Momento',
      color: Color(0xFF283EA3),
      playlistId: canzoniDelMomentoId,
      coverUrl: 'https://i.scdn.co/image/ab67706f00000002b273294dd0290a183d2cb2f9',
    ),
    SpotifyCategoryItem(
      title: 'Viral Hits',
      color: Color(0xFFE91429),
      playlistId: viralHitsId,
      coverUrl: 'https://charts-images.scdn.co/assets/locale_en/viral/daily/region_global_large.jpg',
    ),
    SpotifyCategoryItem(
      title: 'Global Top 50',
      color: Color(0xFFD84000),
      playlistId: top50GlobalId,
      coverUrl: 'https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_large.jpg',
    ),
  ];

  /// Loads tracks from a Spotify playlist with in-memory caching and real album cover resolution.
  Future<List<Song>> getPlaylistSongs(String playlistId) async {
    if (_cachedPlaylists.containsKey(playlistId)) {
      return _cachedPlaylists[playlistId]!;
    }

    try {
      final spotifyData = await SpotifyService.instance.fetchPlaylist(playlistId);
      if (spotifyData != null && spotifyData.tracks.isNotEmpty) {
        final songs = spotifyData.tracks.map((t) {
          final cached = SpotifyService.instance.getCachedCover(t.trackId);
          return Song(
            id: 'spotify_${t.trackId}',
            title: t.title,
            artist: t.artist,
            album: t.album ?? spotifyData.title,
            duration: Duration(milliseconds: t.durationMs),
            thumbnailUrl: cached ?? t.coverUrl ?? spotifyData.coverUrl ?? '',
            spotifyTrackId: t.trackId,
          );
        }).toList();

        // 1. Immediately enrich the top 20 tracks with high concurrency for instant HD render
        final topIds = spotifyData.tracks.take(20).map((t) => t.trackId).toList();
        final initialCovers = await SpotifyService.instance.fetchTrackCoversBatch(topIds, concurrency: 8);

        for (int i = 0; i < songs.length; i++) {
          final tId = spotifyData.tracks[i].trackId;
          if (initialCovers.containsKey(tId)) {
            songs[i] = songs[i].copyWith(thumbnailUrl: initialCovers[tId]);
          }
        }

        _cachedPlaylists[playlistId] = songs;

        // 2. Asynchronously resolve ALL remaining tracks in background so full queue has real covers
        if (songs.length > 20) {
          unawaited(() async {
            final remainingIds = spotifyData.tracks.skip(20).map((t) => t.trackId).toList();
            final remainingCovers = await SpotifyService.instance.fetchTrackCoversBatch(remainingIds, concurrency: 8);
            final cached = _cachedPlaylists[playlistId];
            if (cached != null) {
              for (int i = 20; i < cached.length; i++) {
                final tId = spotifyData.tracks[i].trackId;
                if (remainingCovers.containsKey(tId)) {
                  cached[i] = cached[i].copyWith(thumbnailUrl: remainingCovers[tId]);
                }
              }
            }
          }());
        }

        return songs;
      }
    } catch (e) {
      debugPrint('SpotifyCatalogService.getPlaylistSongs error: $e');
    }

    // Spotify fetch failed: return nothing instead of silently substituting
    // unrelated trending songs under the requested playlist title.
    return const [];
  }
}
