import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import 'playback_log_service.dart';
import 'spotify_internal_auth_service.dart';

class SpotifyTrack {
  final String trackId;
  final String title;
  final String artist;
  final int durationMs;

  /// Album cover, when the source already said it (the Web API does, the
  /// embed page does not).
  final String? coverUrl;

  const SpotifyTrack({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.durationMs,
    this.coverUrl,
  });
}

class SpotifyPlaylistData {
  final String id;
  final String title;
  final String? description;
  final String? coverUrl;
  final List<SpotifyTrack> tracks;

  /// How many tracks the public embed page listed. It lists at most
  /// [SpotifyService.embedLimit]: a playlist that reached it may have more,
  /// read afterwards with [SpotifyService.readRestOfPlaylist].
  final int embedCount;

  bool get mayHaveMore => embedCount >= SpotifyService.embedLimit;

  const SpotifyPlaylistData({
    required this.id,
    required this.title,
    this.description,
    this.coverUrl,
    required this.tracks,
    this.embedCount = 0,
  });
}

class SpotifyService {
  static final SpotifyService instance = SpotifyService._internal();
  SpotifyService._internal();

  static const int _maxCacheSize = 300;

  /// Tracks the public embed page lists at most: a longer playlist is cut
  /// there, and the rest is read with the Web API when logged in.
  static const int embedLimit = 100;

  // The rest of a long playlist: its list from Spotify's own player service,
  // the details of each track from its public page.
  static const String _playlistService = 'https://spclient.wg.spotify.com/playlist/v2/playlist';
  static const int _listPage = 100;
  static const int _detailsAtOnce = 4;
  static const int _batch = 20;

  // Spotify counts requests to its public pages per browser identity, and
  // answers 429 once one has asked too much: the second is tried then.
  static const _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';
  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';
  final Map<String, String> _coverCache = {};
  final http.Client _client = http.Client();

  void _cacheCover(String trackId, String url) {
    if (_coverCache.length >= _maxCacheSize) {
      _coverCache.remove(_coverCache.keys.first);
    }
    _coverCache[trackId] = url;
  }

  /// Recupera la copertina originale in HD (640x640) per un singolo trackId Spotify tramite oembed.
  Future<String?> fetchTrackCoverHD(String trackId) async {
    if (_coverCache.containsKey(trackId)) {
      return _coverCache[trackId];
    }
    try {
      final oembedUrl = 'https://open.spotify.com/oembed?url=https://open.spotify.com/track/$trackId';
      final response = await _client.get(
        Uri.parse(oembedUrl),
        headers: const {'User-Agent': _mobileUa},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final thumb = data['thumbnail_url'] as String?;
        if (thumb != null && thumb.isNotEmpty) {
          // Converte l'immagine oembed in HD (640x640)
          final hd = thumb.replaceAll('00001e02', '0000b273');
          _cacheCover(trackId, hd);
          return hd;
        }
      }
    } catch (e) {
      debugPrint('SpotifyService.fetchTrackCoverHD error for $trackId: $e');
    }
    return null;
  }

  /// Estrae l'ID della playlist Spotify da vari formati di URL o URI.
  String? extractPlaylistId(String urlOrUri) {
    final clean = urlOrUri.trim();
    final regExp = RegExp(r'playlist[:/]([a-zA-Z0-9]+)');
    final match = regExp.firstMatch(clean);
    if (match != null) return match.group(1);
    if (RegExp(r'^[a-zA-Z0-9]{22}$').hasMatch(clean)) return clean;
    return null;
  }

  /// Recupera tutti i metadati e brani della playlist da Spotify in < 1 secondo.
  Future<SpotifyPlaylistData?> fetchPlaylist(String urlOrId) async {
    final playlistId = extractPlaylistId(urlOrId);
    if (playlistId == null) return null;

    try {
      final embedUrl = 'https://open.spotify.com/embed/playlist/$playlistId';
      Future<http.Response> request(String userAgent) => _client.get(
            Uri.parse(embedUrl),
            headers: {
              'User-Agent': userAgent,
              'Accept': 'text/html,application/xhtml+xml',
              'Accept-Language': 'it-IT,it;q=0.9,en-US;q=0.8,en;q=0.7',
            },
          ).timeout(const Duration(seconds: 10));

      var response = await request(_mobileUa);
      if (response.statusCode == 429) response = await request(_desktopUa);

      if (response.statusCode != 200) {
        debugPrint('SpotifyService: HTTP ${response.statusCode} on embed');
        return null;
      }

      final html = response.body;
      final scriptMatch = RegExp(
        r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
        dotAll: true,
      ).firstMatch(html);

      if (scriptMatch == null) {
        debugPrint('SpotifyService: __NEXT_DATA__ non trovato nell\'embed');
        return null;
      }

      final jsonRaw = scriptMatch.group(1);
      if (jsonRaw == null || jsonRaw.isEmpty) {
        debugPrint('SpotifyService: __NEXT_DATA__ content is empty');
        return null;
      }

      dynamic decoded;
      try {
        decoded = json.decode(jsonRaw);
      } catch (e) {
        debugPrint('SpotifyService: json.decode error: $e');
        return null;
      }

      if (decoded is! Map<String, dynamic>) {
        debugPrint('SpotifyService: __NEXT_DATA__ payload is not a Map');
        return null;
      }
      final jsonData = decoded;
      final entity = jsonData['props']?['pageProps']?['state']?['data']?['entity'] as Map<String, dynamic>?;
      if (entity == null) return null;

      final title = entity['title'] as String? ?? 'Playlist Spotify';
      final description = entity['subtitle'] as String? ?? 'Importata da Spotify';

      // ── Copertina Ufficiale Playlist Spotify ──────────────────────────────
      String? playlistCover;
      final coverArtSources = entity['coverArt']?['sources'] as List<dynamic>?;
      if (coverArtSources != null && coverArtSources.isNotEmpty) {
        playlistCover = coverArtSources.first['url'] as String?;
      } else {
        final visualImages = entity['visualIdentity']?['image'] as List<dynamic>?;
        if (visualImages != null && visualImages.isNotEmpty) {
          playlistCover = visualImages.last['url'] as String?;
        }
      }

      final rawTracks = entity['trackList'] as List<dynamic>? ?? [];
      final tracks = <SpotifyTrack>[];

      for (final raw in rawTracks) {
        if (raw is! Map<String, dynamic>) continue;
        final trackTitle = raw['title'] as String? ?? '';
        final artist = raw['subtitle'] as String? ?? '';
        final durationMs = (raw['duration'] as num?)?.toInt() ?? 0;
        final uri = raw['uri'] as String? ?? '';

        if (trackTitle.isEmpty) continue;

        String trackId = uri.contains(':') ? uri.split(':').last : uri;
        if (trackId.isEmpty) {
          trackId = 'sp_${trackTitle.hashCode}_${artist.hashCode}';
        }

        tracks.add(SpotifyTrack(
          trackId: trackId,
          title: trackTitle,
          artist: artist,
          durationMs: durationMs,
        ));
      }

      return SpotifyPlaylistData(
        id: playlistId,
        title: title,
        description: description,
        coverUrl: playlistCover,
        tracks: tracks,
        embedCount: rawTracks.length,
      );
    } catch (e) {
      debugPrint('SpotifyService.fetchPlaylist error: $e');
      return null;
    }
  }

  /// Reads the tracks of a playlist after the first [from] and hands them to
  /// [onBatch] a few at a time, with the playlist's total; [onBatch] answers
  /// false to stop. The list comes from the service Spotify's own player
  /// reads it from, with the login (the Web API answers 429 to the player's
  /// login); each track's title, artists, length and cover from its public
  /// page. Returns how many tracks were handed over, or null when the list
  /// could not be read.
  Future<int?> readRestOfPlaylist(
    String playlistId, {
    required int from,
    required Future<bool> Function(List<SpotifyTrack> batch, int total) onBatch,
  }) async {
    final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
    if (token == null) {
      PlaybackLogService.instance.log('SPOTIFY', 'playlist $playlistId: oltre i primi $from serve l\'accesso a Spotify');
      return null;
    }

    // 1. The list: the uris after the first [from], a page at a time.
    final uris = <String>[];
    var total = from;
    try {
      for (var position = from; position < total || position == from;) {
        final response = await _client.get(
          Uri.parse('$_playlistService/$playlistId?from=$position&length=$_listPage'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'App-Platform': 'WebPlayer',
            'User-Agent': _desktopUa,
          },
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          PlaybackLogService.instance.log(
            'SPOTIFY',
            'playlist $playlistId: elenco HTTP ${response.statusCode} dopo $position brani',
          );
          if (uris.isEmpty) return null;
          break;
        }
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        total = (data['length'] as num?)?.toInt() ?? total;
        final items = data['contents']?['items'] as List<dynamic>? ?? const [];
        if (items.isEmpty) break;
        for (final item in items) {
          final uri = (item as Map<String, dynamic>)['uri'] as String?;
          if (uri != null) uris.add(uri);
        }
        position += items.length;
      }
    } catch (e) {
      PlaybackLogService.instance.log('SPOTIFY', 'playlist $playlistId: elenco non letto ($e)');
      if (uris.isEmpty) return null;
    }
    PlaybackLogService.instance.log(
      'SPOTIFY',
      'playlist $playlistId: $total brani in tutto, ne leggo ${uris.length} oltre i primi $from',
    );

    // 2. The details, a batch at a time, a few tracks at once.
    var handed = 0;
    var missing = 0;
    for (var start = 0; start < uris.length; start += _batch) {
      final chunk = uris.sublist(start, (start + _batch).clamp(0, uris.length));
      final found = List<SpotifyTrack?>.filled(chunk.length, null);
      var next = 0;
      Future<void> worker() async {
        while (next < chunk.length) {
          final i = next++;
          found[i] = await _trackOf(chunk[i]);
        }
      }

      await Future.wait([for (var w = 0; w < _detailsAtOnce; w++) worker()]);
      final batch = [for (final track in found) ?track];
      missing += chunk.length - batch.length;
      if (batch.isEmpty) continue;
      handed += batch.length;
      if (!await onBatch(batch, from + uris.length)) break;
    }
    PlaybackLogService.instance.log(
      'SPOTIFY',
      'playlist $playlistId: aggiunti $handed brani${missing > 0 ? ', $missing non letti' : ''}',
    );
    return handed;
  }

  /// A track of a playlist by its uri: a Spotify track from its public page,
  /// a local file of the owner from the uri itself. Null for anything else
  /// (podcast episodes) or when the page cannot be read.
  Future<SpotifyTrack?> _trackOf(String uri) async {
    if (uri.startsWith('spotify:local:')) {
      // spotify:local:artist:album:title:seconds, each part form-encoded.
      String part(String raw) => Uri.decodeQueryComponent(raw);
      final parts = uri.substring('spotify:local:'.length).split(':');
      if (parts.length < 4 || part(parts[2]).isEmpty) return null;
      final title = part(parts[2]);
      final artist = part(parts[0]);
      return SpotifyTrack(
        trackId: 'sp_${title.hashCode}_${artist.hashCode}',
        title: title,
        artist: artist,
        durationMs: (int.tryParse(parts[3]) ?? 0) * 1000,
      );
    }
    if (!uri.startsWith('spotify:track:')) return null;
    final id = uri.substring('spotify:track:'.length);
    final url = Uri.parse('https://open.spotify.com/embed/track/$id');
    try {
      http.Response? response;
      // The second browser identity, then a pause: the public pages answer
      // 429 to a burst of requests.
      for (final (ua, wait) in [(_mobileUa, 0), (_desktopUa, 0), (_mobileUa, 3)]) {
        if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
        response = await _client.get(url, headers: {
          'User-Agent': ua,
          'Accept': 'text/html,application/xhtml+xml',
        }).timeout(const Duration(seconds: 10));
        if (response.statusCode != 429) break;
      }
      if (response == null || response.statusCode != 200) return null;
      final match = RegExp(
        r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
        dotAll: true,
      ).firstMatch(response.body);
      if (match == null) return null;
      final entity = (json.decode(match.group(1)!) as Map<String, dynamic>)['props']?['pageProps']
          ?['state']?['data']?['entity'] as Map<String, dynamic>?;
      if (entity == null) return null;
      final title = (entity['title'] ?? entity['name']) as String? ?? '';
      if (title.isEmpty) return null;
      final artist = [
        for (final a in entity['artists'] as List<dynamic>? ?? const [])
          if (a is Map && a['name'] is String && (a['name'] as String).isNotEmpty) a['name'] as String,
      ].join(', ');
      String? cover;
      var width = 0;
      for (final image in entity['visualIdentity']?['image'] as List<dynamic>? ?? const []) {
        final w = (image['maxWidth'] as num?)?.toInt() ?? 0;
        if (image['url'] is String && w > width) {
          width = w;
          cover = image['url'] as String;
        }
      }
      return SpotifyTrack(
        trackId: id,
        title: title,
        artist: artist,
        durationMs: (entity['duration'] as num?)?.toInt() ?? 0,
        coverUrl: cover,
      );
    } catch (e) {
      debugPrint('SpotifyService._trackOf $id: $e');
      return null;
    }
  }

  String? getCachedCover(String trackId) => _coverCache[trackId];

  /// Recupera le copertine originali in HD per una lista di tracce in parallelo.
  Future<Map<String, String>> fetchTrackCoversBatch(
    List<String> trackIds, {
    int concurrency = 4,
  }) async {
    final results = <String, String>{};
    final toFetch = trackIds.where((id) {
      if (_coverCache.containsKey(id)) {
        results[id] = _coverCache[id]!;
        return false;
      }
      return true;
    }).toList();

    if (toFetch.isEmpty) return results;

    int index = 0;
    Future<void> worker() async {
      while (index < toFetch.length) {
        final i = index++;
        final id = toFetch[i];
        final url = await fetchTrackCoverHD(id);
        if (url != null) {
          results[id] = url;
        }
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, toFetch.length),
      (_) => worker(),
    );
    await Future.wait(workers);
    return results;
  }

  Future<List<Song>> searchTracks(String query) async {
    final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
    if (token == null) {
      return [];
    }

    final url = Uri.parse('https://api.spotify.com/v1/search?q=${Uri.encodeComponent(query)}&type=track&limit=15');
    final response = await _client.get(url, headers: {
      'Authorization': 'Bearer $token',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    }).timeout(const Duration(seconds: 6));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final tracks = data['tracks']['items'] as List<dynamic>;
      final result = <Song>[];
      for (final t in tracks) {
        final id = t['id'] as String;
        final title = t['name'] as String;
        final artists = (t['artists'] as List<dynamic>).map((a) => a['name']).join(', ');
        final album = t['album']['name'] as String;
        final durationMs = t['duration_ms'] as int;
        
        String? coverUrl;
        final images = t['album']['images'] as List<dynamic>?;
        if (images != null && images.isNotEmpty) {
          coverUrl = images.first['url'] as String; // High res
        }

        result.add(Song(
          id: 'spotify_$id',
          title: title,
          artist: artists,
          album: album,
          duration: Duration(milliseconds: durationMs),
          thumbnailUrl: coverUrl ?? '',
          spotifyTrackId: id,
        ));
      }
      return result;
    } else {
      debugPrint('Spotify search failed: HTTP ${response.statusCode}');
    }
    return [];
  }
}
