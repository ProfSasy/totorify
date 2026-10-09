import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'cover_art_service.dart';
import 'deezer_service.dart';
import 'storage_service.dart';
import 'ytmusic_service.dart';

/// Songs that fit after a given song. Feeds autoplay at the end of the
/// queue, Smart Shuffle and the "Consigliati" list in the queue.
///
/// Two sources are blended: what goes with the song playing now (its
/// artist's radio) and what the listening history says the user likes (the
/// radios of their most played artists). Candidates by artists the user
/// already listens to rank higher; songs heard recently are left out.
class RecommendationService {
  RecommendationService._internal();
  static final RecommendationService instance = RecommendationService._internal();

  static const int _maxCached = 40;
  static const int _tasteArtists = 3;

  /// History entries whose songs are too fresh to be recommended again.
  static const int recentWindow = 30;

  final Map<String, List<Song>> _cache = {};
  final Map<String, List<Song>> _radioCache = {};

  /// Identity of a song across catalogs: the same track has a different id
  /// on Spotify, Apple, Deezer and YouTube.
  static String songKey(Song song) => '${DeezerService.normalize(song.title)}|${artistKey(song)}';

  static String artistKey(Song song) =>
      DeezerService.normalize(DeezerService.primaryArtist(song.artist));

  /// How much the user listens to each artist, from [history] (most recent
  /// first). Recent plays weigh more than old ones.
  static Map<String, double> artistAffinity(List<Song> history) {
    final affinity = <String, double>{};
    for (var i = 0; i < history.length; i++) {
      final key = artistKey(history[i]);
      if (key.isEmpty) continue;
      affinity[key] = (affinity[key] ?? 0) + 1 / (1 + i / 10);
    }
    return affinity;
  }

  /// Orders the candidates for [seed].
  ///
  /// [contextual] goes with the seed, [personal] comes from the user's top
  /// artists; both are best first. A candidate scores on its position in its
  /// list (contextual ones start higher) plus the user's affinity for its
  /// artist. The seed, duplicates and songs in the last [recentWindow]
  /// history entries are dropped.
  static List<Song> rank({
    required Song seed,
    required List<Song> contextual,
    required List<Song> personal,
    required List<Song> history,
  }) {
    final affinity = artistAffinity(history);
    final maxAffinity = affinity.values.fold<double>(0, (a, b) => a > b ? a : b);
    final excluded = <String>{
      songKey(seed),
      for (final played in history.take(recentWindow)) songKey(played),
    };

    final scores = <String, double>{};
    final songs = <String, Song>{};

    void score(List<Song> list, double top, double spread) {
      for (var i = 0; i < list.length; i++) {
        final song = list[i];
        final key = songKey(song);
        if (excluded.contains(key)) continue;
        final position = top - spread * (i / list.length);
        final taste = maxAffinity > 0
            ? 0.5 * (affinity[artistKey(song)] ?? 0) / maxAffinity
            : 0.0;
        final total = position + taste;
        final previous = scores[key];
        // In both lists: fits the moment and the user's taste.
        scores[key] = previous == null
            ? total
            : (previous > total ? previous : total) + 0.2;
        songs.putIfAbsent(key, () => song);
      }
    }

    score(contextual, 1.0, 0.5);
    score(personal, 0.7, 0.4);

    // Ties keep the order the sources gave (List.sort is not stable).
    final order = {for (final (i, key) in scores.keys.indexed) key: i};
    final keys = scores.keys.toList()
      ..sort((a, b) {
        final byScore = scores[b]!.compareTo(scores[a]!);
        return byScore != 0 ? byScore : order[a]!.compareTo(order[b]!);
      });
    return [for (final key in keys) songs[key]!];
  }

  /// Recommendations for [song], best first. [youtubeSeedId] is the YouTube
  /// video currently playing for it, used when the catalog has no match.
  Future<List<Song>> forSong(Song song, {String? youtubeSeedId}) async {
    final cached = _cache[song.id];
    if (cached != null) return cached;

    final history = StorageService.instance.getHistory();
    final sources = await Future.wait([
      _contextual(song, youtubeSeedId),
      _fromHistory(song, history),
    ]);
    final ranked = rank(
      seed: song,
      contextual: sources[0],
      personal: sources[1],
      history: history,
    );

    // Empty results are not cached: a network failure must be retried.
    if (ranked.isNotEmpty) {
      if (_cache.length >= _maxCached) _cache.remove(_cache.keys.first);
      _cache[song.id] = ranked;
    }
    return ranked;
  }

  Future<List<Song>> _contextual(Song song, String? youtubeSeedId) async {
    final radio = await _radioOf(song);
    if (radio.isNotEmpty || youtubeSeedId == null || youtubeSeedId.isEmpty) {
      return radio;
    }
    return _fromYouTube(youtubeSeedId);
  }

  /// Radios of the artists the user plays most, other than the seed's.
  Future<List<Song>> _fromHistory(Song seed, List<Song> history) async {
    final affinity = artistAffinity(history);
    final seedArtist = artistKey(seed);
    final topArtists = (affinity.keys.where((key) => key != seedArtist).toList()
          ..sort((a, b) => affinity[b]!.compareTo(affinity[a]!)))
        .take(_tasteArtists);

    // The most recent song of each artist identifies it in the catalog.
    final radios = await Future.wait([
      for (final artist in topArtists)
        _radioOf(history.firstWhere((s) => artistKey(s) == artist)),
    ]);

    // Round-robin, so one artist's radio does not fill the whole list.
    final merged = <Song>[];
    for (var i = 0; radios.any((radio) => i < radio.length); i++) {
      for (final radio in radios) {
        if (i < radio.length) merged.add(radio[i]);
      }
    }
    return merged;
  }

  Future<List<Song>> _radioOf(Song song) async {
    try {
      final artistId = (await DeezerService.instance.artistOf(song))?.id;
      if (artistId == null) return [];
      final cached = _radioCache[artistId];
      if (cached != null) return cached;

      final radio = await DeezerService.instance.artistRadio(artistId);
      if (radio.isNotEmpty) {
        if (_radioCache.length >= _maxCached) _radioCache.remove(_radioCache.keys.first);
        _radioCache[artistId] = radio;
      }
      return radio;
    } catch (e) {
      debugPrint('RecommendationService._radioOf: $e');
      return [];
    }
  }

  Future<List<Song>> _fromYouTube(String videoId) async {
    try {
      final related = await YTMusicService.instance.getRelatedSongs(videoId);
      return CoverArtService.instance.withOriginalCovers(related);
    } catch (e) {
      debugPrint('RecommendationService._fromYouTube: $e');
      return [];
    }
  }
}
