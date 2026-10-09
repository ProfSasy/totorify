import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import 'canvaz_proto.dart';
import 'deezer_service.dart';
import 'playback_log_service.dart';
import 'spotify_internal_auth_service.dart';
import 'storage_service.dart';

/// Outcome of one lookup step. [failed] marks a missing login or a network
/// error (as opposed to a definite "there is none"), worth retrying soon.
typedef _Lookup = ({String? value, bool failed});

/// What the compatibility ranking needs to know about a Spotify track.
typedef _TrackInfo = ({String? artistId, String artistName, DateTime? released});

/// A Canvas the artist uploaded for one of their tracks.
class _ArtistCanvas {
  final String trackId;
  final String url;
  final DateTime? released;

  const _ArtistCanvas(this.trackId, this.url, this.released);
}

/// Resolves the looping video shown behind the player ("Canvas").
///
/// 1. The track's own Canvas, exactly as Spotify assigns it: uploaded by the
///    artist for that track and looked up by track id.
/// 2. For tracks without one, the most compatible Canvas of the same artist:
///    the one whose track was released closest to this one (same release
///    first), so the visual belongs to the same era. A track is left without
///    a Canvas only when its artist has none at all.
///
/// Sources: Spotify's own canvas endpoint when logged in, and
/// canvasdownloader.com (same per-track data, plus every Canvas of an
/// artist) without a login. Artist and release date come from Spotify's
/// public embed page, or from Deezer for songs with no known Spotify track.
class CanvasService {
  static final CanvasService instance = CanvasService._internal();
  CanvasService._internal();

  static const int _maxCacheSize = 50;
  // Canvas files on Spotify's CDN do not expire, and "no canvas" is a stable
  // answer too: both are kept for the session's working span.
  static const Duration _cacheTtl = Duration(hours: 4);
  // A failure is retried soon: it must not hide the canvas for hours.
  static const Duration _failureTtl = Duration(minutes: 2);

  // Compatibility ranking: how many of an artist's canvases are compared.
  // Each one costs a request for its release date, once per session.
  static const int _maxArtistCandidates = 16;
  static const int _maxArtistPages = 2;
  static const int _maxParallelRequests = 4;
  static const int _maxArtistsCached = 40;
  static const int _maxTrackInfoCached = 400;

  static const _spotifyCanvasEndpoint =
      'https://spclient.wg.spotify.com/canvaz-cache/v0/canvases';
  static const _spotifyApi = 'https://api.spotify.com/v1';
  static const _spotifyEmbed = 'https://open.spotify.com/embed/track';
  static const _provider = 'https://www.canvasdownloader.com';
  static const _browserHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  };

  static final RegExp _sourceTag = RegExp(r'<source\s+src="([^"]+)"');
  // One entry of the provider's artist page: the video, then its track.
  static final RegExp _artistCanvasEntry = RegExp(
    r'<source\s+src="([^"#]+)[^"]*"[\s\S]*?spotify:track:([A-Za-z0-9]+)',
  );
  static final RegExp _embedData = RegExp(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
    dotAll: true,
  );

  final Map<String, (String?, DateTime)> _canvasCache = {};
  final Map<String, Future<String?>> _inFlight = {};
  final Map<String, _TrackInfo> _trackInfoCache = {};
  final Map<String, List<_ArtistCanvas>> _artistCanvasCache = {};
  final Map<String, Future<List<_ArtistCanvas>?>> _artistCanvasInFlight = {};
  final ValueNotifier<bool> isCanvasEnabledNotifier = ValueNotifier<bool>(true);

  bool get isEnabled => isCanvasEnabledNotifier.value;

  String? getCachedCanvasUrlSync(String songId) {
    if (!isEnabled) return null;
    final cached = _canvasCache[songId];
    if (cached != null && DateTime.now().isBefore(cached.$2)) {
      return cached.$1;
    }
    return null;
  }

  /// True when the answer for [songId] is known, including "no canvas".
  bool hasCachedResult(String songId) {
    final cached = _canvasCache[songId];
    return cached != null && DateTime.now().isBefore(cached.$2);
  }

  void setCanvasEnabled(bool enabled) {
    isCanvasEnabledNotifier.value = enabled;
    StorageService.instance.setCanvasEnabled(enabled);
  }

  /// Warms the canvas URL for [song] in the background, so the player can
  /// display the video instantly when the user opens it. Returns the URL
  /// when available (also from the fresh cache).
  Future<String?> prefetch(Song song) async {
    if (!isEnabled) return null;
    return getCanvasUrl(song);
  }

  /// Drops the cached answer for [songId] so the next request resolves it
  /// again. Used to retry after the video failed to play.
  void invalidate(String? songId) {
    if (songId == null) return;
    _canvasCache.remove(songId);
  }

  /// Canvas video URL for [song], or null when it has none. Concurrent
  /// requests for the same song (background prefetch and the player) share
  /// one resolution.
  Future<String?> getCanvasUrl(Song song) {
    if (!isEnabled) return Future.value(null);

    final cachedEntry = _canvasCache[song.id];
    if (cachedEntry != null) {
      if (DateTime.now().isBefore(cachedEntry.$2)) {
        return Future.value(cachedEntry.$1);
      }
      _canvasCache.remove(song.id);
    }

    final pending = _inFlight[song.id];
    if (pending != null) return pending;

    final future = _resolveAndCache(song);
    _inFlight[song.id] = future;
    return future.whenComplete(() => _inFlight.remove(song.id));
  }

  Future<String?> _resolveAndCache(Song song) async {
    _Lookup result;
    try {
      result = await _resolve(song);
    } catch (e) {
      debugPrint('CanvasService._resolve: $e');
      result = (value: null, failed: true);
    }
    // Misses are cached as well: without this every track change repeated
    // the whole lookup for the songs around the current one.
    if (_canvasCache.length >= _maxCacheSize) {
      _canvasCache.remove(_canvasCache.keys.first);
    }
    final ttl = result.failed ? _failureTtl : _cacheTtl;
    _canvasCache[song.id] = (result.value, DateTime.now().add(ttl));
    return result.value;
  }

  Future<_Lookup> _resolve(Song song) async {
    if (song.canvasUrl != null && song.canvasUrl!.isNotEmpty) {
      return (value: song.canvasUrl, failed: false);
    }

    final track = await _spotifyTrackId(song);
    var failed = track.failed;

    // 1. The track's own Canvas.
    if (track.value != null) {
      final own = await _fetchCanvas(track.value!);
      if (own.value != null) {
        PlaybackLogService.instance
            .log('CANVAS', 'canvas ufficiale per "${song.title}"');
        return own;
      }
      failed = failed || own.failed;
    }

    // 2. The most compatible Canvas of the same artist.
    final compatible = await _compatibleCanvas(song, track.value);
    if (compatible.value != null) return compatible;

    PlaybackLogService.instance
        .log('CANVAS', 'nessun canvas per "${song.title}"');
    return (value: null, failed: failed || compatible.failed);
  }

  // ── Which Spotify track is this song ──────────────────────────────────────

  Future<_Lookup> _spotifyTrackId(Song song) async {
    if (song.id.startsWith('spotify_')) {
      return (value: song.id.replaceFirst('spotify_', ''), failed: false);
    }
    if (song.spotifyTrackId != null && song.spotifyTrackId!.isNotEmpty) {
      return (value: song.spotifyTrackId, failed: false);
    }

    final stored = StorageService.instance.getCachedSpotifyId(song.id);
    if (stored != null) return (value: stored, failed: false);

    // Matching another catalog's song to Spotify uses Spotify's search,
    // which only answers a logged-in account.
    if (!SpotifyInternalAuthService.instance.hasSpDcCookie) {
      return (value: null, failed: true);
    }

    var match = await _byIsrc(song);
    if (match.value == null) {
      final byName = await _byTitleAndArtist(song);
      match = (value: byName.value, failed: match.failed || byName.failed);
    }
    if (match.value != null) {
      await StorageService.instance.cacheSpotifyId(song.id, match.value!);
      return (value: match.value, failed: false);
    }
    return match;
  }

  /// Deezer id of [song]: its own, or the catalog match for other sources.
  Future<String?> _deezerTrackId(Song song) async {
    if (song.id.startsWith(DeezerService.idPrefix)) {
      return song.id.substring(DeezerService.idPrefix.length);
    }
    return (await DeezerService.instance.matchTrack(song))?.trackId;
  }

  /// Exact match: the ISRC identifies one recording across every catalog.
  /// Deezer supplies it, Spotify finds the track that carries it.
  Future<_Lookup> _byIsrc(Song song) async {
    final deezerId = await _deezerTrackId(song);
    if (deezerId == null) return (value: null, failed: false);

    final isrc = (await DeezerService.instance.trackDetails(deezerId))?.isrc;
    if (isrc == null) return (value: null, failed: false);

    final data = await _spotifyGet('/search?q=isrc:$isrc&type=track&limit=1');
    if (data == null) return (value: null, failed: true);
    final items = data['tracks']?['items'] as List<dynamic>? ?? const [];
    return (
      value: items.isEmpty ? null : items.first['id'] as String?,
      failed: false,
    );
  }

  /// For songs Deezer does not know. The first hit is not trusted blindly:
  /// another song's canvas is worse than none, so title and artist (or
  /// duration) must agree.
  Future<_Lookup> _byTitleAndArtist(Song song) async {
    final title = DeezerService.normalize(song.title);
    final artist = DeezerService.normalize(DeezerService.primaryArtist(song.artist));
    if (title.isEmpty) return (value: null, failed: false);

    final data = await _spotifyGet(
      '/search?q=${Uri.encodeComponent('$title $artist'.trim())}&type=track&limit=5',
    );
    if (data == null) return (value: null, failed: true);
    final items = data['tracks']?['items'] as List<dynamic>? ?? const [];

    for (final item in items) {
      final candTitle = DeezerService.normalize(item['name'] as String? ?? '');
      if (candTitle.isEmpty) continue;
      final titleOk = candTitle == title ||
          (title.length >= 4 && candTitle.contains(title)) ||
          (candTitle.length >= 4 && title.contains(candTitle));
      if (!titleOk) continue;

      final artists = (item['artists'] as List<dynamic>? ?? const [])
          .map((a) => DeezerService.normalize(a['name'] as String? ?? ''))
          .where((name) => name.isNotEmpty);
      final artistOk = artist.isNotEmpty &&
          artists.any((name) => name == artist || name.contains(artist) || artist.contains(name));
      final durationMs = (item['duration_ms'] as num?)?.toInt() ?? 0;
      final durationOk = song.duration > Duration.zero &&
          durationMs > 0 &&
          (song.duration.inMilliseconds - durationMs).abs() <= 4000;

      if (artistOk || durationOk) {
        return (value: item['id'] as String?, failed: false);
      }
    }
    return (value: null, failed: false);
  }

  /// Authenticated Spotify Web API call. Returns null without a login or on
  /// any failure.
  Future<Map<String, dynamic>?> _spotifyGet(String path) async {
    try {
      final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
      if (token == null) return null;
      final response = await http.get(
        Uri.parse('$_spotifyApi$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CanvasService._spotifyGet $path: $e');
      return null;
    }
  }

  // ── The track's own Canvas ────────────────────────────────────────────────

  Future<_Lookup> _fetchCanvas(String trackId) async {
    final direct = await _fromSpotify(trackId);
    if (direct != null) return (value: direct, failed: false);
    // No login, or Spotify gave nothing: the public mirror has the same
    // per-track data and needs no account.
    return _fromCanvasDownloader(trackId);
  }

  /// Spotify's own canvas endpoint, the one its app calls. It only returns
  /// canvases to a logged-in account.
  Future<String?> _fromSpotify(String trackId) async {
    if (!SpotifyInternalAuthService.instance.hasSpDcCookie) return null;
    try {
      final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
      if (token == null) return null;
      final response = await http.post(
        Uri.parse(_spotifyCanvasEndpoint),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/x-protobuf',
          'Accept': 'application/protobuf',
        },
        body: encodeCanvazRequest(trackId),
      ).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      return decodeCanvazVideoUrl(response.bodyBytes);
    } catch (e) {
      debugPrint('CanvasService._fromSpotify: $e');
      return null;
    }
  }

  Future<_Lookup> _fromCanvasDownloader(String trackId) async {
    try {
      final response = await http.get(
        Uri.parse('$_provider/canvas?link=https://open.spotify.com/track/$trackId'),
        headers: _browserHeaders,
      ).timeout(const Duration(seconds: 8));

      // The site answers 200 for "no canvas" too: only a page with a video
      // source is a hit. Anything else than 200 is a failure worth retrying.
      if (response.statusCode != 200) return (value: null, failed: true);
      final match = _sourceTag.firstMatch(response.body);
      if (match == null) return (value: null, failed: false);
      // The page appends a media fragment that AVPlayer rejects.
      return (value: match.group(1)!.split('#').first, failed: false);
    } catch (e) {
      debugPrint('CanvasService._fromCanvasDownloader: $e');
      return (value: null, failed: true);
    }
  }

  // ── The most compatible Canvas of the same artist ─────────────────────────

  /// Canvas for a track that has none of its own: among the canvases the
  /// same artist uploaded for other tracks, the one released closest in
  /// time. [trackId] is the song's Spotify track when known.
  Future<_Lookup> _compatibleCanvas(Song song, String? trackId) async {
    final info = trackId == null ? null : await _trackInfo(trackId);
    final artistName = info?.artistName ?? DeezerService.primaryArtist(song.artist);
    if (artistName.trim().isEmpty) return (value: null, failed: false);

    final canvases = await _artistCanvases(artistName, info?.artistId);
    if (canvases == null) return (value: null, failed: true);

    final candidates = canvases.where((c) => c.trackId != trackId).toList();
    if (candidates.isEmpty) return (value: null, failed: false);

    final released = info?.released ?? await _releaseDateFromDeezer(song);
    final best = _pickClosestRelease(
      released,
      [for (final c in candidates) c.released],
    );
    final chosen = candidates[best];

    final gap = (released != null && chosen.released != null)
        ? '${chosen.released!.difference(released).inDays.abs()} giorni di distanza'
        : 'data di uscita non nota';
    PlaybackLogService.instance.log(
      'CANVAS',
      'canvas compatibile per "${song.title}": stesso artista, $gap',
    );
    return (value: chosen.url, failed: false);
  }

  /// Index of the release date in [candidates] closest to [target]. Unknown
  /// dates rank last; with no [target], or nothing dated, the first
  /// candidate wins (the provider lists the most looked-up canvases first).
  static int _pickClosestRelease(DateTime? target, List<DateTime?> candidates) {
    if (target == null) return 0;
    var best = 0;
    Duration? bestGap;
    for (var i = 0; i < candidates.length; i++) {
      final date = candidates[i];
      if (date == null) continue;
      final gap = date.difference(target).abs();
      if (bestGap == null || gap < bestGap) {
        bestGap = gap;
        best = i;
      }
    }
    return best;
  }

  Future<DateTime?> _releaseDateFromDeezer(Song song) async {
    final deezerId = await _deezerTrackId(song);
    if (deezerId == null) return null;
    return (await DeezerService.instance.trackDetails(deezerId))?.released;
  }

  /// Artist and release date of a Spotify track, read from its public embed
  /// page (no login). Null on failure.
  Future<_TrackInfo?> _trackInfo(String trackId) async {
    final cached = _trackInfoCache[trackId];
    if (cached != null) return cached;

    try {
      final response = await http
          .get(Uri.parse('$_spotifyEmbed/$trackId'), headers: _browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = _embedData.firstMatch(response.body)?.group(1);
      if (data == null) return null;

      final entity = json.decode(data)['props']?['pageProps']?['state']?['data']?['entity'];
      final artists = entity?['artists'] as List<dynamic>? ?? const [];
      if (artists.isEmpty) return null;

      final info = (
        artistId: (artists.first['uri'] as String?)?.split(':').last,
        artistName: artists.first['name'] as String? ?? '',
        released: DateTime.tryParse(entity['releaseDate']?['isoString'] as String? ?? ''),
      );
      if (_trackInfoCache.length >= _maxTrackInfoCached) {
        _trackInfoCache.remove(_trackInfoCache.keys.first);
      }
      _trackInfoCache[trackId] = info;
      return info;
    } catch (e) {
      debugPrint('CanvasService._trackInfo: $e');
      return null;
    }
  }

  /// Every Canvas the provider knows for an artist, each with the release
  /// date of its track. Empty when the artist has none; null on failure.
  /// [artistId] (Spotify) identifies the artist exactly; without it the name
  /// must match.
  Future<List<_ArtistCanvas>?> _artistCanvases(String artistName, String? artistId) {
    final key = artistId ?? 'name:${DeezerService.normalize(artistName)}';
    final cached = _artistCanvasCache[key];
    if (cached != null) return Future.value(cached);
    final pending = _artistCanvasInFlight[key];
    if (pending != null) return pending;

    final future = _loadArtistCanvases(artistName, artistId).then((canvases) {
      // Failures are not kept, so the next track of the artist retries.
      if (canvases != null) {
        if (_artistCanvasCache.length >= _maxArtistsCached) {
          _artistCanvasCache.remove(_artistCanvasCache.keys.first);
        }
        _artistCanvasCache[key] = canvases;
      }
      return canvases;
    });
    _artistCanvasInFlight[key] = future;
    // Block body on purpose: returning the removed future from here would
    // make this future wait on itself.
    return future.whenComplete(() {
      _artistCanvasInFlight.remove(key);
    });
  }

  Future<List<_ArtistCanvas>?> _loadArtistCanvases(String artistName, String? artistId) async {
    try {
      final slug = await _providerArtistSlug(artistName, artistId);
      if (slug.failed) return null;
      if (slug.value == null) return const [];

      // url -> track id, in the provider's order and without duplicates:
      // artists often reuse one canvas for a whole release.
      final found = <String, String>{};
      for (var page = 1; page <= _maxArtistPages; page++) {
        final response = await http
            .get(
              Uri.parse('$_provider/artists/${slug.value}?page=$page'),
              headers: _browserHeaders,
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) {
          if (page == 1) return null;
          break;
        }
        final entries = _artistCanvasEntry.allMatches(response.body).toList();
        for (final entry in entries) {
          found.putIfAbsent(entry.group(1)!, () => entry.group(2)!);
        }
        if (entries.isEmpty || found.length >= _maxArtistCandidates) break;
      }

      final picked = found.entries.take(_maxArtistCandidates).toList();
      final dates = List<DateTime?>.filled(picked.length, null);
      var next = 0;
      Future<void> worker() async {
        while (next < picked.length) {
          final i = next++;
          dates[i] = (await _trackInfo(picked[i].value))?.released;
        }
      }

      await Future.wait(List.generate(_maxParallelRequests, (_) => worker()));

      return [
        for (var i = 0; i < picked.length; i++)
          _ArtistCanvas(picked[i].value, picked[i].key, dates[i]),
      ];
    } catch (e) {
      debugPrint('CanvasService._loadArtistCanvases: $e');
      return null;
    }
  }

  /// The provider's page id for an artist, from its search. Null value when
  /// the provider does not list the artist.
  Future<_Lookup> _providerArtistSlug(String artistName, String? artistId) async {
    final response = await http
        .get(
          Uri.parse('$_provider/api/search?q=${Uri.encodeQueryComponent(artistName)}'),
          headers: const {..._browserHeaders, 'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return (value: null, failed: true);

    final artists = json.decode(response.body)['artists'] as List<dynamic>? ?? const [];
    final wantedName = DeezerService.normalize(artistName);
    for (final artist in artists) {
      final uri = artist['uri'] as String? ?? '';
      final sameArtist = artistId != null
          ? uri == 'spotify:artist:$artistId'
          : DeezerService.normalize(artist['name'] as String? ?? '') == wantedName;
      if (sameArtist) return (value: artist['slug'] as String?, failed: false);
    }
    return (value: null, failed: false);
  }
}
