import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/lyrics_model.dart';
import 'auth_service.dart';

/// What a source is asked for: the song, cleaned of what YouTube adds to
/// titles and channel names.
@immutable
class LyricsQuery {
  const LyricsQuery({
    required this.title,
    required this.artist,
    required this.primaryArtist,
    this.album,
    this.durationSec = 0,
    this.videoId,
  });

  final String title;
  final String artist;
  final String primaryArtist;
  final String? album;
  final int durationSec;

  /// The YouTube video the song plays from, for the sources that know
  /// lyrics by video.
  final String? videoId;
}

/// A place lyrics come from. [find] answers with the lyrics, null when it
/// has none; it throws when it could not be asked (no network, an error of
/// the server), so that a missing answer is not taken for "no lyrics".
@immutable
class LyricsSource {
  const LyricsSource(this.id, this.name, this.description, this.find);

  final String id;
  final String name;
  final String description;
  final Future<Lyrics?> Function(LyricsQuery query) find;
}

/// The sources of lyrics, the same YumaPlayer uses: open databases of
/// timed lyrics, the karaoke ones (word by word) and YouTube Music's own.
class LyricsSources {
  LyricsSources._();

  static final http.Client _client = http.Client();
  static const Duration _timeout = Duration(seconds: 9);
  static const Map<String, String> _headers = {
    'User-Agent': 'Totorify/1.0 (https://github.com/ProfSasy/totorify)',
    'Accept': 'application/json',
  };

  static final List<LyricsSource> all = [
    const LyricsSource(
      'youlyplus',
      'YouLyPlus',
      'Testi karaoke da più servizi, parola per parola',
      _youLyPlus,
    ),
    const LyricsSource('lrclib', 'LRCLIB', 'Archivio aperto di testi sincronizzati', _lrclib),
    const LyricsSource(
      'simpmusic',
      'SimpMusic',
      'Testi legati ai video di YouTube, spesso parola per parola',
      _simpMusic,
    ),
    const LyricsSource(
      'betterlyrics',
      'BetterLyrics',
      'Testi di Apple Music parola per parola (solo quelli già in archivio)',
      _betterLyrics,
    ),
    const LyricsSource('unison', 'Unison', 'Testi scelti e votati dalla comunità', _unison),
    const LyricsSource('kugou', 'KuGou', 'Grande archivio, forte sulla musica asiatica', _kuGou),
    const LyricsSource(
      'youtube',
      'YouTube Music',
      "Il testo di YouTube Music, senza tempi (serve l'accesso con Google)",
      _youtubeMusic,
    ),
  ];

  static LyricsSource? byId(String id) {
    for (final source in all) {
      if (source.id == id) return source;
    }
    return null;
  }

  static List<String> get defaultOrder => [for (final source in all) source.id];

  static Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) =>
      _client.get(uri, headers: headers ?? _headers).timeout(_timeout);

  /// A 404 is the answer "not here", and so is a refusal that will not
  /// change (a key required); anything else but 200 is a failure.
  static bool _found(http.Response response) {
    if (response.statusCode == 200) return true;
    if (const {401, 403, 404}.contains(response.statusCode)) return false;
    throw http.ClientException('HTTP ${response.statusCode}', response.request?.url);
  }

  // ── LRCLIB ──────────────────────────────────────────────────────────────

  static Lyrics? _fromLrclib(Map<String, dynamic> data) {
    final synced = data['syncedLyrics'] as String?;
    final plain = data['plainLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      return Lyrics.fromLrc(synced, plainFallback: plain, source: 'LRCLIB');
    }
    if (plain != null && plain.trim().isNotEmpty) {
      return Lyrics(plainLyrics: plain, source: 'LRCLIB');
    }
    return null;
  }

  static Future<Lyrics?> _lrclibGet(String title, String artist, int? duration) async {
    final uri = Uri.parse('https://lrclib.net/api/get').replace(
      queryParameters: {
        'track_name': title,
        'artist_name': artist,
        if (duration != null && duration > 0) 'duration': '$duration',
      },
    );
    final response = await _get(uri);
    if (!_found(response)) return null;
    return _fromLrclib(json.decode(response.body) as Map<String, dynamic>);
  }

  static Future<Lyrics?> _lrclibSearch(String q, LyricsQuery query) async {
    final uri = Uri.parse('https://lrclib.net/api/search').replace(queryParameters: {'q': q});
    final response = await _get(uri);
    if (!_found(response)) return null;
    final wanted = query.primaryArtist.toLowerCase();
    for (final item in json.decode(response.body) as List<dynamic>) {
      final data = item as Map<String, dynamic>;
      // A wrong-artist hit is worse than no lyrics at all.
      final artist = (data['artistName'] as String? ?? '').toLowerCase();
      if (wanted.isNotEmpty && artist.isNotEmpty && !artist.contains(wanted)) continue;
      final duration = (data['duration'] as num?)?.toInt() ?? 0;
      if (query.durationSec > 0 && duration > 0 && (duration - query.durationSec).abs() > 12) {
        continue;
      }
      final lyrics = _fromLrclib(data);
      if (lyrics != null) return lyrics;
    }
    return null;
  }

  static Future<Lyrics?> _lrclib(LyricsQuery query) async {
    final duration = query.durationSec;
    return await _lrclibGet(query.title, query.artist, duration) ??
        (duration > 0 ? await _lrclibGet(query.title, query.artist, null) : null) ??
        (query.primaryArtist != query.artist
            ? await _lrclibGet(query.title, query.primaryArtist, null)
            : null) ??
        await _lrclibSearch('${query.title} ${query.primaryArtist}', query) ??
        await _lrclibSearch(query.title, query);
  }

  // ── BetterLyrics (Apple Music, word by word) ────────────────────────────

  static Future<Lyrics?> _betterLyrics(LyricsQuery query) async {
    final uri = Uri.parse('https://lyrics-api.boidu.dev/getLyrics').replace(
      queryParameters: {
        's': query.title,
        'a': query.primaryArtist,
        if (query.album != null && query.album!.isNotEmpty) 'al': query.album!,
        if (query.durationSec > 0) 'd': '${query.durationSec}',
      },
    );
    final response = await _get(uri, headers: const {});
    if (!_found(response)) return null;
    final ttml = _ttmlIn(response.body);
    if (ttml == null) return null;
    return Lyrics.fromTtml(ttml, source: 'BetterLyrics');
  }

  /// The TTML in an answer that is TTML itself or JSON carrying it.
  static String? _ttmlIn(String body) {
    final text = body.trim();
    if (text.startsWith('<')) return text;
    if (!text.startsWith('{')) return null;
    final data = json.decode(text);
    if (data is! Map) return null;
    final direct = data['ttml'];
    if (direct is String && direct.contains('<')) return direct;
    final inner = data['lyrics'];
    if (inner is Map && inner['ttml'] is String) return inner['ttml'] as String;
    return null;
  }

  // ── YouLyPlus (karaoke from several services) ───────────────────────────

  static const List<String> _youLyPlusMirrors = [
    'https://lyricsplus.binimum.org/',
    'https://lyricsplus.prjktla.my.id/',
    'https://lyricsplus.prjktla.workers.dev/',
    'https://lyricsplus.atomix.one/',
    'https://lyricsplus-seven.vercel.app/',
  ];

  static Future<Lyrics?> _youLyPlus(LyricsQuery query) async {
    final parameters = {
      'title': query.title,
      'artist': query.primaryArtist,
      if (query.album != null && query.album!.isNotEmpty) 'album': query.album!,
      if (query.durationSec > 0) 'duration': '${query.durationSec}',
    };
    Object? lastError;
    for (final mirror in _youLyPlusMirrors) {
      try {
        final response = await _get(
          Uri.parse('${mirror}v2/lyrics/get').replace(queryParameters: parameters),
        );
        if (response.statusCode == 404) return null;
        if (response.statusCode != 200) {
          lastError = 'HTTP ${response.statusCode}';
          continue;
        }
        return _fromYouLyPlus(json.decode(response.body));
      } catch (e) {
        lastError = e;
      }
    }
    throw http.ClientException('YouLyPlus: $lastError');
  }

  static Lyrics? _fromYouLyPlus(Object? data) {
    if (data is! Map) return null;
    final raw = data['lyrics'];
    if (raw is! List || raw.isEmpty) return null;
    final wordByWord = '${data['type']}'.toLowerCase() == 'word';
    final lines = <LyricLine>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final time = (item['time'] as num?)?.toInt();
      final syllables = item['syllabus'];
      final words = <LyricWord>[];
      if (wordByWord && syllables is List) {
        for (final syllable in syllables) {
          if (syllable is! Map || syllable['isBackground'] == true) continue;
          final start = (syllable['time'] as num?)?.toInt();
          final text = syllable['text'] as String?;
          if (start == null || text == null || text.isEmpty) continue;
          final length = (syllable['duration'] as num?)?.toInt() ?? 500;
          words.add(
            LyricWord(
              start: Duration(milliseconds: start),
              end: Duration(milliseconds: start + length),
              text: text,
            ),
          );
        }
      }
      var text = (item['text'] as String? ?? '').trim();
      if (text.isEmpty && words.isNotEmpty) text = words.map((w) => w.text).join().trim();
      if (time == null || text.isEmpty) continue;
      lines.add(
        LyricLine(
          time: Duration(milliseconds: time),
          text: text,
          words: words,
        ),
      );
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(
      plainLyrics: lines.map((line) => line.text).join('\n'),
      syncedLyrics: lines,
      isSynced: true,
      source: 'YouLyPlus',
    );
  }

  // ── Unison (chosen by the community) ────────────────────────────────────

  static Future<Lyrics?> _unison(LyricsQuery query) async {
    Future<Lyrics?> ask(Map<String, String> parameters) async {
      final response = await _get(
        Uri.parse('https://unison.boidu.dev/lyrics').replace(queryParameters: parameters),
      );
      if (response.statusCode == 404) return null;
      if (!_found(response)) return null;
      final data = json.decode(response.body);
      if (data is! Map || data['success'] != true) return null;
      final entry = data['data'];
      final text = entry is Map ? entry['lyrics'] as String? : null;
      if (text == null || text.trim().isEmpty) return null;
      final lyrics = Lyrics.parseAny(text, source: 'Unison');
      return lyrics.isEmpty ? null : lyrics;
    }

    final video = query.videoId;
    return (video != null && video.isNotEmpty ? await ask({'v': video}) : null) ??
        await ask({
          'song': query.title,
          'artist': query.primaryArtist,
          if (query.album != null && query.album!.isNotEmpty) 'album': query.album!,
          if (query.durationSec > 0) 'duration': '${query.durationSec}',
        });
  }

  // ── SimpMusic (by YouTube video) ────────────────────────────────────────

  static Future<Lyrics?> _simpMusic(LyricsQuery query) async {
    final video = query.videoId;
    if (video == null || video.isEmpty) return null;
    final response = await _get(
      Uri.parse('https://api-lyrics.simpmusic.org/v1/$video'),
      headers: const {
        'Accept': 'application/json',
        'User-Agent': 'SimpMusicLyrics/1.0',
        'Content-Type': 'application/json',
      },
    );
    if (response.statusCode == 404) return null;
    if (!_found(response)) return null;
    final data = json.decode(response.body);
    if (data is! Map || data['type'] != 'success') return null;
    final tracks = [
      for (final track in (data['data'] as List? ?? const []))
        if (track is Map) track,
    ];
    if (tracks.isEmpty) return null;
    if (query.durationSec > 0) {
      int distance(Map track) =>
          (((track['durationSeconds'] as num?)?.toInt() ?? 0) - query.durationSec).abs();
      tracks.sort((a, b) => distance(a).compareTo(distance(b)));
    }
    final best = tracks.first;
    final rich = best['richSyncLyrics'] as String?;
    final synced = best['syncedLyrics'] as String?;
    final plain = best['plainLyric'] as String?;
    for (final text in [rich, synced, plain]) {
      if (text == null || text.trim().isEmpty) continue;
      final lyrics = Lyrics.parseAny(text, source: 'SimpMusic');
      if (lyrics.isNotEmpty) return lyrics;
    }
    return null;
  }

  // ── KuGou ───────────────────────────────────────────────────────────────

  static Future<Lyrics?> _kuGou(LyricsQuery query) async {
    final searchUrl = Uri.parse('https://mobileservice.kugou.com/api/v3/search/song').replace(
      queryParameters: {
        'version': '9108',
        'plat': '0',
        'pagesize': '8',
        'showtype': '0',
        'keyword': '${query.title} - ${query.primaryArtist}',
      },
    );
    final searchResp = await _get(
      searchUrl,
      headers: const {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
    );
    if (!_found(searchResp)) return null;
    final infoList = json.decode(searchResp.body)['data']?['info'] as List<dynamic>? ?? [];

    // Accepted only when artist and length agree: this catalog is huge and
    // the first hit is often another song.
    final wantedArtist = query.primaryArtist.toLowerCase();
    String? hash;
    for (final info in infoList) {
      final duration = (info['duration'] as num?)?.toInt() ?? 0;
      final singer = (info['singername'] as String? ?? '').toLowerCase();
      final artistOk = wantedArtist.isNotEmpty && singer.contains(wantedArtist);
      final durationOk = query.durationSec <= 0 || (duration - query.durationSec).abs() <= 8;
      if (!artistOk || !durationOk) continue;
      hash = info['hash'] as String?;
      if (hash != null && hash.isNotEmpty) break;
    }
    if (hash == null || hash.isEmpty) return null;

    final candidatesResp = await _get(
      Uri.parse(
        'https://lyrics.kugou.com/search',
      ).replace(queryParameters: {'ver': '1', 'man': 'yes', 'client': 'pc', 'hash': hash}),
    );
    if (!_found(candidatesResp)) return null;
    final candidates = json.decode(candidatesResp.body)['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) return null;
    final candidate = candidates.first;

    final downloadResp = await _get(
      Uri.parse('https://lyrics.kugou.com/download').replace(
        queryParameters: {
          'fmt': 'lrc',
          'charset': 'utf8',
          'client': 'pc',
          'ver': '1',
          'id': '${candidate['id']}',
          'accesskey': '${candidate['accesskey']}',
        },
      ),
    );
    if (!_found(downloadResp)) return null;
    final content = json.decode(downloadResp.body)['content'] as String?;
    if (content == null || content.isEmpty) return null;
    final lyrics = Lyrics.fromLrc(utf8.decode(base64Decode(content)), source: 'KuGou');
    return lyrics.isEmpty ? null : lyrics;
  }

  // ── YouTube Music ───────────────────────────────────────────────────────

  static const Map<String, Object> _androidMusic = {
    'client': {
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': '7.27.52',
      'androidSdkVersion': 34,
      'hl': 'it',
    },
  };

  static Future<Map<String, dynamic>?> _innerTube(
    String endpoint,
    Map<String, Object> body,
    String token,
  ) async {
    final response = await _client
        .post(
          Uri.parse('https://music.youtube.com/youtubei/v1/$endpoint?prettyPrint=false'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent':
                'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip',
            'Authorization': 'Bearer $token',
            'X-Goog-AuthUser': '0',
          },
          body: jsonEncode({'context': _androidMusic, ...body}),
        )
        .timeout(_timeout);
    if (!_found(response)) return null;
    return json.decode(response.body) as Map<String, dynamic>;
  }

  /// The lyrics YouTube Music shows under its "Lyrics" tab: plain text.
  /// YouTube gives them only to a signed-in account.
  static Future<Lyrics?> _youtubeMusic(LyricsQuery query) async {
    final video = query.videoId;
    if (video == null || video.isEmpty || !AuthService.isAvailable) return null;
    final token = await AuthService.instance.getValidAccessToken();
    if (token == null) return null;
    final next = await _innerTube('next', {'videoId': video}, token);
    final browseId = _findLyricsBrowseId(next);
    if (browseId == null) return null;
    final page = await _innerTube('browse', {'browseId': browseId}, token);
    final text = _findDescription(page);
    if (text == null || text.trim().isEmpty) return null;
    return Lyrics(plainLyrics: text.trim(), source: 'YouTube Music');
  }

  static String? _findLyricsBrowseId(Object? node) {
    if (node is Map) {
      final endpoint = node['browseEndpoint'];
      if (endpoint is Map) {
        final type =
            endpoint['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
        if (type == 'MUSIC_PAGE_TYPE_TRACK_LYRICS') return endpoint['browseId'] as String?;
      }
      for (final value in node.values) {
        final found = _findLyricsBrowseId(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findLyricsBrowseId(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String? _findDescription(Object? node) {
    if (node is Map) {
      final shelf = node['musicDescriptionShelfRenderer'];
      if (shelf is Map) {
        final runs = shelf['description']?['runs'];
        if (runs is List) return runs.map((run) => run is Map ? '${run['text'] ?? ''}' : '').join();
      }
      for (final value in node.values) {
        final found = _findDescription(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findDescription(value);
        if (found != null) return found;
      }
    }
    return null;
  }
}
