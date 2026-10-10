import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/artist.dart';
import '../models/song.dart';

/// A song matched against the Deezer catalog: its official cover and artist.
class DeezerTrackMatch {
  final String trackId;
  final String coverUrl;
  final Artist artist;

  const DeezerTrackMatch({
    required this.trackId,
    required this.coverUrl,
    required this.artist,
  });
}

/// Public Deezer API (no key, no account). Used for metadata: official
/// album covers, release dates and artist radio. Artist pages come from
/// [YTMusicCatalogService], which also knows the smaller artists. Audio never comes
/// from Deezer: songs built here carry a `deezer_` id that the track matcher
/// resolves to a YouTube stream like `spotify_` and `itunes_` ids.
class DeezerService {
  DeezerService._internal();
  static final DeezerService instance = DeezerService._internal();

  static const _base = 'https://api.deezer.com';
  static const idPrefix = 'deezer_';

  // The API allows 50 requests per 5 seconds: a few parallel calls are safe.
  static const int _maxConcurrent = 4;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  final Map<String, DeezerTrackMatch?> _matchCache = {};
  final Map<String, Future<DeezerTrackMatch?>> _matchInFlight = {};

  static final RegExp _brackets = RegExp(r'\s*[\(\[][^\)\]]*[\)\]]');
  static final RegExp _feat =
      RegExp(r'\s+(feat\.?|ft\.?|featuring)\s+.*', caseSensitive: false);
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);
  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _channelSuffix =
      RegExp(r'(\s*-\s*topic|\s*vevo|\s+official)$', caseSensitive: false);
  static final RegExp _artistSeparators =
      RegExp(r'\s*[,;&/]\s*|\s+(?:x|e|and|feat\.?|ft\.?)\s+', caseSensitive: false);

  /// Lowercase title/name without brackets, "feat." tails and punctuation.
  static String normalize(String text) => text
      .replaceAll(_brackets, '')
      .replaceAll(_feat, '')
      .replaceAll(_nonWord, ' ')
      .toLowerCase()
      .replaceAll(_spaces, ' ')
      .trim();

  /// First credited artist, without YouTube channel suffixes ("- Topic", "VEVO").
  static String primaryArtist(String artist) {
    final cleaned = artist.replaceAll(_channelSuffix, '').trim();
    final first = cleaned.split(_artistSeparators).first.trim();
    return first.isEmpty ? cleaned : first;
  }

  Future<dynamic> _get(String path) async {
    if (_running >= _maxConcurrent) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final response = await http
          .get(Uri.parse('$_base$path'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        debugPrint('DeezerService GET $path: HTTP ${response.statusCode}');
        return null;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      // Quota and lookup failures come back as HTTP 200 with an "error" body.
      if (data is Map && data['error'] != null) {
        debugPrint('DeezerService GET $path: ${data['error']}');
        return null;
      }
      return data;
    } catch (e) {
      debugPrint('DeezerService GET $path: $e');
      return null;
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  List<Map<String, dynamic>> _list(dynamic data) {
    final raw = data is Map ? data['data'] : null;
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Artist? _artistFrom(dynamic raw) {
    if (raw is! Map || raw['id'] == null) return null;
    return Artist(
      id: raw['id'].toString(),
      name: raw['name'] as String? ?? '',
      imageUrl: (raw['picture_xl'] ?? raw['picture_big'] ?? raw['picture_medium'] ?? '') as String,
    );
  }

  String _coverFrom(dynamic album) {
    if (album is! Map) return '';
    return (album['cover_xl'] ?? album['cover_big'] ?? album['cover_medium'] ?? '') as String;
  }

  Song? _songFrom(Map<String, dynamic> track) {
    final id = track['id'];
    final title = track['title'] as String?;
    final artist = (track['artist'] as Map?)?['name'] as String?;
    final cover = _coverFrom(track['album']);
    if (id == null || title == null || artist == null || cover.isEmpty) return null;
    return Song(
      id: '$idPrefix$id',
      title: title,
      artist: artist,
      album: (track['album'] as Map?)?['title'] as String?,
      duration: Duration(seconds: (track['duration'] as num?)?.toInt() ?? 0),
      thumbnailUrl: cover,
    );
  }

  List<Song> _songsFrom(dynamic data) => [
        for (final track in _list(data))
          ?_songFrom(track),
      ];

  // ── Track matching ────────────────────────────────────────────────────────

  /// Finds [song] in the Deezer catalog. Returns null when no result is a
  /// confident match: a missing cover is better than a wrong one.
  Future<DeezerTrackMatch?> matchTrack(Song song) {
    if (_matchCache.containsKey(song.id)) return Future.value(_matchCache[song.id]);
    final running = _matchInFlight[song.id];
    if (running != null) return running;

    final future = _matchTrack(song).then((match) {
      _matchCache[song.id] = match;
      return match;
    }).whenComplete(() {
      // Block body on purpose: returning the removed future from here would
      // make this future wait on itself.
      _matchInFlight.remove(song.id);
    });
    _matchInFlight[song.id] = future;
    return future;
  }

  Future<DeezerTrackMatch?> _matchTrack(Song song) async {
    // YouTube uploads often read "Artist - Title (Official Video)" with the
    // channel as artist: try that reading as well as the plain one.
    final readings = <(String, String)>[
      (normalize(song.title), normalize(primaryArtist(song.artist))),
    ];
    final dash = song.title.indexOf(' - ');
    if (dash > 0) {
      readings.insert(0, (
        normalize(song.title.substring(dash + 3)),
        normalize(primaryArtist(song.title.substring(0, dash))),
      ));
    }

    for (final (title, artist) in readings) {
      if (title.isEmpty) continue;
      final query = Uri.encodeQueryComponent('$artist $title'.trim());
      final results = _list(await _get('/search?q=$query&limit=8'));
      final best = _pickMatch(results, title, artist, song.duration);
      if (best != null) return best;
    }
    return null;
  }

  DeezerTrackMatch? _pickMatch(
    List<Map<String, dynamic>> results,
    String title,
    String artist,
    Duration duration,
  ) {
    Map<String, dynamic>? best;
    var bestScore = 0;

    for (final track in results) {
      final candTitle = normalize((track['title_short'] ?? track['title'] ?? '') as String);
      final candArtist = normalize(((track['artist'] as Map?)?['name'] ?? '') as String);
      if (candTitle.isEmpty || candArtist.isEmpty) continue;

      final sameTitle = candTitle == title;
      final titleOk = sameTitle ||
          (candTitle.length >= 4 && title.contains(candTitle)) ||
          (title.length >= 4 && candTitle.contains(title));
      if (!titleOk) continue;

      final artistOk = artist.isNotEmpty &&
          (candArtist == artist || candArtist.contains(artist) || artist.contains(candArtist));
      final candSeconds = (track['duration'] as num?)?.toInt() ?? 0;
      final diff = (duration.inSeconds > 0 && candSeconds > 0)
          ? (duration.inSeconds - candSeconds).abs()
          : null;
      final durationOk = diff != null && diff <= 4;
      if (!artistOk && !durationOk) continue;

      var score = 1;
      if (sameTitle) score += 4;
      if (artistOk) score += 4;
      if (durationOk) score += 3;
      // A remix or live cut wins over the plain version only when the
      // duration confirms it.
      if ((track['title_version'] as String? ?? '').trim().isNotEmpty) score -= 2;
      if (score > bestScore) {
        bestScore = score;
        best = track;
      }
    }

    if (best == null) return null;
    final cover = _coverFrom(best['album']);
    final matchedArtist = _artistFrom(best['artist']);
    if (cover.isEmpty || matchedArtist == null) return null;
    return DeezerTrackMatch(
      trackId: best['id'].toString(),
      coverUrl: cover,
      artist: matchedArtist,
    );
  }

  /// Details of a Deezer track: its ISRC (the code that identifies one
  /// recording in every catalog) and release date. Null on failure.
  Future<({String? isrc, DateTime? released})?> trackDetails(String trackId) async {
    final data = await _get('/track/$trackId');
    if (data is! Map) return null;
    final isrc = data['isrc'] as String?;
    return (
      isrc: (isrc == null || isrc.isEmpty) ? null : isrc,
      released: DateTime.tryParse(data['release_date'] as String? ?? ''),
    );
  }

  // ── Artists ───────────────────────────────────────────────────────────────

  /// Deezer artist for a display name taken from a song ("Annalisa", "Daft
  /// Punk - Topic"). Null when nobody has exactly that name: a namesake's
  /// radio would be worse than none.
  Future<Artist?> findArtist(String name) async {
    final wanted = normalize(primaryArtist(name));
    if (wanted.isEmpty) return null;
    final query = Uri.encodeQueryComponent(primaryArtist(name));
    final results = _list(await _get('/search/artist?q=$query&limit=10'));
    // Several artists can share a name: the one meant is the most followed.
    Map<String, dynamic>? best;
    var bestFans = -1;
    for (final raw in results) {
      if (normalize(raw['name'] as String? ?? '') != wanted) continue;
      final fans = (raw['nb_fan'] as num?)?.toInt() ?? 0;
      if (fans > bestFans) {
        best = raw;
        bestFans = fans;
      }
    }
    return _artistFrom(best);
  }

  /// Artist of [song]: taken from the matched track when possible, which is
  /// exact, and from a name search otherwise.
  Future<Artist?> artistOf(Song song) async {
    final match = await matchTrack(song);
    if (match != null) return match.artist;
    return findArtist(song.artist);
  }

  /// A mix of the artist and similar artists: the base for recommendations.
  Future<List<Song>> artistRadio(String artistId, {int limit = 40}) async =>
      _songsFrom(await _get('/artist/$artistId/radio?limit=$limit'));
}
