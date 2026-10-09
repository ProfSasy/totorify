import 'dart:async';
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

/// What is known about a Spotify track from its public embed page.
class _TrackInfo {
  final String title;
  final String? artistId;
  final String artistName;

  /// Every credited artist, normalized.
  final Set<String> artists;
  final DateTime? released;

  const _TrackInfo({
    required this.title,
    required this.artistId,
    required this.artistName,
    required this.artists,
    required this.released,
  });
}

/// A Canvas an artist uploaded for one of their tracks.
class _ArtistCanvas {
  final String trackId;
  final String url;
  final _TrackInfo? info;

  const _ArtistCanvas(this.trackId, this.url, this.info);
}

/// Resolves the looping video shown behind the player ("Canvas").
///
/// 1. The track's own Canvas, exactly as Spotify assigns it: uploaded by the
///    artist for that track and looked up by track id.
/// 2. For tracks without one, the most compatible Canvas of the same artist:
///    for a collaboration, one from a track with at least two of the same
///    artists; otherwise the one released closest in time. A track is left
///    without a Canvas only when its artist has none at all.
///
/// Finding the track's own Canvas needs its Spotify id. A logged-in account
/// gets it from Spotify by ISRC. Without a login it comes from MusicBrainz
/// (by ISRC), from the artist's public top tracks, or from the list of the
/// artist's known canvases.
///
/// Sources: Spotify's own canvas endpoint when logged in, and
/// canvasdownloader.com (same per-track data, plus every Canvas of an
/// artist) without a login.
class CanvasService {
  static final CanvasService instance = CanvasService._internal();
  CanvasService._internal();

  static const int _maxCacheSize = 50;
  // Canvas files on Spotify's CDN do not expire, and "no canvas" is a stable
  // answer too: both are kept for the session's working span.
  static const Duration _cacheTtl = Duration(hours: 4);
  // A failure is retried soon: it must not hide the canvas for hours.
  static const Duration _failureTtl = Duration(minutes: 2);

  // How many of an artist's canvases are compared. Each one costs a request
  // for its track details, once per session.
  static const int _maxArtistCandidates = 30;
  static const int _maxArtistPages = 3;
  static const int _maxParallelRequests = 4;
  static const int _maxArtistsCached = 40;
  static const int _maxTrackInfoCached = 600;
  // Other artists of a collaboration whose canvases are looked at as well.
  static const int _maxCollaborators = 2;

  static const _spotifyCanvasEndpoint =
      'https://spclient.wg.spotify.com/canvaz-cache/v0/canvases';
  static const _spotifyApi = 'https://api.spotify.com/v1';
  static const _spotifyEmbed = 'https://open.spotify.com/embed';
  static const _provider = 'https://www.canvasdownloader.com';
  static const _musicBrainz = 'https://musicbrainz.org/ws/2';
  static const _browserHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  };
  // MusicBrainz asks every client to identify itself and to stay under one
  // request per second.
  static const _musicBrainzHeaders = {
    'User-Agent': 'Totorify/1.0 (https://github.com/ProfSasy/totorify)',
  };
  static const Duration _musicBrainzInterval = Duration(milliseconds: 1100);

  static final RegExp _sourceTag = RegExp(r'<source\s+src="([^"]+)"');
  // One entry of the provider's artist page: the video, then its track.
  static final RegExp _artistCanvasEntry = RegExp(
    r'<source\s+src="([^"#]+)[^"]*"[\s\S]*?spotify:track:([A-Za-z0-9]+)',
  );
  static final RegExp _embedData = RegExp(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
    dotAll: true,
  );
  static final RegExp _spotifyTrackUrl =
      RegExp(r'open\.spotify\.com/track/([A-Za-z0-9]+)');
  // "(feat. X)", "[con X & Y]", "(with X)" in a title.
  static final RegExp _featuredInTitle = RegExp(
    r'[\(\[]\s*(?:feat\.?|ft\.?|featuring|con|with)\s+([^\)\]]+)[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _artistSeparators = RegExp(
    r'\s*[,;&/]\s*|\s+(?:x|e|and|feat\.?|ft\.?|featuring|con|with)\s+',
    caseSensitive: false,
  );

  final Map<String, (String?, DateTime)> _canvasCache = {};
  final Map<String, Future<String?>> _inFlight = {};
  final Map<String, _TrackInfo> _trackInfoCache = {};
  final Map<String, List<_ArtistCanvas>> _artistCanvasCache = {};
  final Map<String, Future<List<_ArtistCanvas>?>> _artistCanvasInFlight = {};
  Future<void> _musicBrainzQueue = Future.value();
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
    } catch (e, stack) {
      PlaybackLogService.instance
          .error('CANVAS', 'ricerca fallita per "${song.title}": $e', stack);
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
    final log = PlaybackLogService.instance;

    final track = await _spotifyTrackIds(song);
    var failed = track.failed;

    // 1. The track's own Canvas. One recording can exist as several Spotify
    // tracks (single, album version) and only some carry the Canvas.
    for (final trackId in track.ids) {
      final own = await _fetchCanvas(trackId);
      if (own.value != null) {
        log.log('CANVAS', '"${song.title}": canvas proprio del brano (Spotify $trackId)');
        return own;
      }
      failed = failed || own.failed;
    }
    if (track.ids.isNotEmpty) {
      log.log(
        'CANVAS',
        '"${song.title}": nessun canvas proprio su Spotify '
        '(${track.ids.join(', ')}), cerco il più compatibile',
      );
    } else {
      log.log('CANVAS', '"${song.title}": brano Spotify non identificato, cerco tra i canvas dell\'artista');
    }

    // 2. The most compatible Canvas of the same artist.
    final compatible = await _compatibleCanvas(
      song,
      track.ids.isEmpty ? null : track.ids.first,
    );
    if (compatible.value != null) return compatible;

    log.log('CANVAS', '"${song.title}": nessun canvas disponibile');
    return (value: null, failed: failed || compatible.failed);
  }

  // ── Which Spotify track is this song ──────────────────────────────────────

  /// Spotify tracks that are this song, most trusted first. Empty when it
  /// cannot be identified; [failed] then tells a passing problem from
  /// "nobody knows this song".
  Future<({List<String> ids, bool failed})> _spotifyTrackIds(Song song) async {
    if (song.id.startsWith('spotify_')) {
      return (ids: [song.id.replaceFirst('spotify_', '')], failed: false);
    }
    if (song.spotifyTrackId != null && song.spotifyTrackId!.isNotEmpty) {
      return (ids: [song.spotifyTrackId!], failed: false);
    }

    final stored = StorageService.instance.getCachedSpotifyId(song.id);
    if (stored != null) return (ids: [stored], failed: false);

    var failed = false;
    final isrc = await _isrcOf(song);

    // Logged in: Spotify itself, by ISRC and then by name.
    if (SpotifyInternalAuthService.instance.hasSpDcCookie) {
      if (isrc != null) {
        final data = await _spotifyGet('/search?q=isrc:$isrc&type=track&limit=10');
        if (data == null) {
          failed = true;
        } else {
          final items = data['tracks']?['items'] as List<dynamic>? ?? const [];
          final ids = [
            for (final item in items)
              if (item['id'] case final String id) id,
          ];
          if (ids.isNotEmpty) {
            await StorageService.instance.cacheSpotifyId(song.id, ids.first);
            return (ids: ids, failed: false);
          }
        }
      }
      final byName = await _byTitleAndArtist(song);
      failed = failed || byName.failed;
      if (byName.value != null) {
        await StorageService.instance.cacheSpotifyId(song.id, byName.value!);
        return (ids: [byName.value!], failed: false);
      }
    }

    // No login needed: MusicBrainz links recordings to Spotify by ISRC.
    if (isrc != null) {
      final linked = await _spotifyIdFromMusicBrainz(isrc);
      failed = failed || linked.failed;
      if (linked.value != null) {
        await StorageService.instance.cacheSpotifyId(song.id, linked.value!);
        return (ids: [linked.value!], failed: false);
      }
    }

    // No login needed: the artist's public top tracks, by title.
    final popular = await _fromArtistTopTracks(song);
    failed = failed || popular.failed;
    if (popular.value != null) {
      await StorageService.instance.cacheSpotifyId(song.id, popular.value!);
      return (ids: [popular.value!], failed: false);
    }

    return (ids: const <String>[], failed: failed);
  }

  /// Deezer id of [song]: its own, or the catalog match for other sources.
  Future<String?> _deezerTrackId(Song song) async {
    if (song.id.startsWith(DeezerService.idPrefix)) {
      return song.id.substring(DeezerService.idPrefix.length);
    }
    return (await DeezerService.instance.matchTrack(song))?.trackId;
  }

  /// The ISRC identifies one recording across every catalog.
  Future<String?> _isrcOf(Song song) async {
    final deezerId = await _deezerTrackId(song);
    if (deezerId == null) return null;
    return (await DeezerService.instance.trackDetails(deezerId))?.isrc;
  }

  Future<_Lookup> _spotifyIdFromMusicBrainz(String isrc) {
    // One request at a time, spaced out, whatever the number of songs being
    // resolved around the current one.
    final result = _musicBrainzQueue.then<_Lookup>((_) async {
      try {
        final response = await http
            .get(
              Uri.parse('$_musicBrainz/isrc/$isrc?inc=url-rels&fmt=json'),
              headers: _musicBrainzHeaders,
            )
            .timeout(const Duration(seconds: 8));
        // 404: MusicBrainz does not know this recording.
        if (response.statusCode == 404) return (value: null, failed: false);
        if (response.statusCode != 200) {
          debugPrint('CanvasService MusicBrainz $isrc: HTTP ${response.statusCode}');
          return (value: null, failed: true);
        }
        final recordings = json.decode(response.body)['recordings'] as List<dynamic>? ?? const [];
        for (final recording in recordings) {
          for (final relation in recording['relations'] as List<dynamic>? ?? const []) {
            final url = relation['url']?['resource'] as String? ?? '';
            final match = _spotifyTrackUrl.firstMatch(url);
            if (match != null) return (value: match.group(1), failed: false);
          }
        }
        return (value: null, failed: false);
      } catch (e) {
        debugPrint('CanvasService MusicBrainz $isrc: $e');
        return (value: null, failed: true);
      }
    });
    _musicBrainzQueue = result.then((_) => Future<void>.delayed(_musicBrainzInterval));
    return result;
  }

  /// Looks for the song among the ten tracks Spotify shows publicly for its
  /// artist. Title and artist must both agree.
  Future<_Lookup> _fromArtistTopTracks(Song song) async {
    final artistName = DeezerService.primaryArtist(song.artist);
    final slug = await _providerArtist(artistName, null);
    if (slug.failed) return (value: null, failed: true);
    final artistId = slug.artistId;
    if (artistId == null) return (value: null, failed: false);

    final entity = await _embedEntity('artist', artistId);
    if (entity == null) return (value: null, failed: true);

    final wanted = DeezerService.normalize(song.title);
    if (wanted.isEmpty) return (value: null, failed: false);
    for (final track in entity['trackList'] as List<dynamic>? ?? const []) {
      final title = DeezerService.normalize(track['title'] as String? ?? '');
      final uri = track['uri'] as String? ?? '';
      if (title == wanted && uri.startsWith('spotify:track:')) {
        return (value: uri.split(':').last, failed: false);
      }
    }
    return (value: null, failed: false);
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
      if (response.statusCode != 200) {
        debugPrint('CanvasService._spotifyGet $path: HTTP ${response.statusCode}');
        return null;
      }
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
      if (response.statusCode != 200) {
        debugPrint('CanvasService._fromSpotify $trackId: HTTP ${response.statusCode}');
        return null;
      }
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
      if (response.statusCode != 200) {
        debugPrint('CanvasService._fromCanvasDownloader $trackId: HTTP ${response.statusCode}');
        return (value: null, failed: true);
      }
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

  /// Canvas for a track that has none of its own, chosen among the canvases
  /// its artists uploaded for other tracks. [trackId] is the song's Spotify
  /// track when known.
  ///
  /// The list is also where a track's own Canvas is found when the track
  /// could not be identified any other way: an entry with the same title by
  /// the same artist is that Canvas.
  Future<_Lookup> _compatibleCanvas(Song song, String? trackId) async {
    final log = PlaybackLogService.instance;
    final info = trackId == null ? null : await _trackInfo(trackId);
    final mainArtist = info?.artistName ?? DeezerService.primaryArtist(song.artist);
    if (mainArtist.trim().isEmpty) return (value: null, failed: false);
    final mainKey = DeezerService.normalize(mainArtist);
    final songArtists = _artistsOf(song, info);
    final songTitle = DeezerService.normalize(info?.title ?? song.title);

    final own = await _artistCanvases(mainArtist, info?.artistId);
    if (own == null) return (value: null, failed: true);
    final candidates = own.where((c) => c.trackId != trackId).toList();

    // The same title by the same artist: it is this track's Canvas.
    for (final candidate in candidates) {
      final candInfo = candidate.info;
      if (candInfo == null || songTitle.isEmpty) continue;
      if (DeezerService.normalize(candInfo.title) == songTitle &&
          candInfo.artists.contains(mainKey)) {
        log.log('CANVAS', '"${song.title}": canvas proprio del brano, trovato tra quelli di $mainArtist');
        return (value: candidate.url, failed: false);
      }
    }

    final released = info?.released ?? await _releaseDateFromDeezer(song);

    // A collaboration: prefer a Canvas from a track with at least two of the
    // same artists, looking at the other artists' canvases too.
    if (songArtists.length >= 2) {
      final pool = <String, _ArtistCanvas>{
        for (final candidate in candidates) candidate.url: candidate,
      };
      final others = songArtists.where((name) => name != mainKey).take(_maxCollaborators);
      for (final other in others) {
        final theirs = await _artistCanvases(other, null);
        for (final candidate in theirs ?? const <_ArtistCanvas>[]) {
          if (candidate.trackId != trackId) pool.putIfAbsent(candidate.url, () => candidate);
        }
      }
      // More artists in common is better; so is having the main artist.
      int affinity(_ArtistCanvas c) {
        final common = c.info?.artists.intersection(songArtists) ?? const <String>{};
        return common.length * 2 + (common.contains(mainKey) ? 1 : 0);
      }

      final related = pool.values
          .where((c) => (c.info?.artists.intersection(songArtists).length ?? 0) >= 2)
          .toList();
      final top = related.fold<int>(0, (best, c) => affinity(c) > best ? affinity(c) : best);
      final shared = related.where((c) => affinity(c) == top).toList();
      if (shared.isNotEmpty) {
        final chosen = shared[_pickClosestRelease(
          released,
          [for (final c in shared) c.info?.released],
        )];
        log.log(
          'CANVAS',
          '"${song.title}": canvas di "${chosen.info?.title}" '
          '(stessi artisti: ${chosen.info!.artists.intersection(songArtists).join(', ')})',
        );
        return (value: chosen.url, failed: false);
      }
    }

    if (candidates.isEmpty) return (value: null, failed: false);

    // Otherwise the main artist's Canvas released closest in time.
    final chosen = candidates[_pickClosestRelease(
      released,
      [for (final c in candidates) c.info?.released],
    )];
    final chosenDate = chosen.info?.released;
    final gap = (released != null && chosenDate != null)
        ? '${chosenDate.difference(released).inDays.abs()} giorni di distanza'
        : 'data di uscita non nota';
    log.log(
      'CANVAS',
      '"${song.title}": canvas di "${chosen.info?.title ?? chosen.trackId}" '
      '(stesso artista, $gap)',
    );
    return (value: chosen.url, failed: false);
  }

  /// Every artist credited on the song, normalized: from Spotify when the
  /// track is known, otherwise from the artist field and from a "(feat. X)"
  /// in the title.
  Set<String> _artistsOf(Song song, _TrackInfo? info) {
    if (info != null && info.artists.isNotEmpty) return info.artists;
    final names = <String>[
      ...song.artist.split(_artistSeparators),
      for (final match in _featuredInTitle.allMatches(song.title))
        ...match.group(1)!.split(_artistSeparators),
    ];
    return {
      for (final name in names)
        if (DeezerService.normalize(DeezerService.primaryArtist(name)).isNotEmpty)
          DeezerService.normalize(DeezerService.primaryArtist(name)),
    };
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

  /// Data Spotify embeds in its public player page for a track or artist
  /// (no login). Null on failure.
  Future<Map<String, dynamic>?> _embedEntity(String kind, String id) async {
    try {
      final response = await http
          .get(Uri.parse('$_spotifyEmbed/$kind/$id'), headers: _browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService embed/$kind/$id: HTTP ${response.statusCode}');
        return null;
      }
      final data = _embedData.firstMatch(response.body)?.group(1);
      if (data == null) return null;
      final entity = json.decode(data)['props']?['pageProps']?['state']?['data']?['entity'];
      return entity is Map<String, dynamic> ? entity : null;
    } catch (e) {
      debugPrint('CanvasService embed/$kind/$id: $e');
      return null;
    }
  }

  /// Title, artists and release date of a Spotify track.
  Future<_TrackInfo?> _trackInfo(String trackId) async {
    final cached = _trackInfoCache[trackId];
    if (cached != null) return cached;

    final entity = await _embedEntity('track', trackId);
    final artists = entity?['artists'] as List<dynamic>? ?? const [];
    if (entity == null || artists.isEmpty) return null;

    final info = _TrackInfo(
      title: (entity['name'] ?? entity['title'] ?? '') as String,
      artistId: (artists.first['uri'] as String?)?.split(':').last,
      artistName: artists.first['name'] as String? ?? '',
      artists: {
        for (final artist in artists)
          if (DeezerService.normalize(artist['name'] as String? ?? '').isNotEmpty)
            DeezerService.normalize(artist['name'] as String),
      },
      released: DateTime.tryParse(entity['releaseDate']?['isoString'] as String? ?? ''),
    );
    if (_trackInfoCache.length >= _maxTrackInfoCached) {
      _trackInfoCache.remove(_trackInfoCache.keys.first);
    }
    _trackInfoCache[trackId] = info;
    return info;
  }

  /// Every Canvas the provider knows for an artist, each with the details
  /// of its track. Empty when the artist has none; null on failure.
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
      final artist = await _providerArtist(artistName, artistId);
      if (artist.failed) return null;
      if (artist.slug == null) return const [];

      // url -> track id, in the provider's order and without duplicates:
      // artists often reuse one canvas for a whole release.
      final found = <String, String>{};
      for (var page = 1; page <= _maxArtistPages; page++) {
        final response = await http
            .get(
              Uri.parse('$_provider/artists/${artist.slug}?page=$page'),
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
      final details = List<_TrackInfo?>.filled(picked.length, null);
      var next = 0;
      Future<void> worker() async {
        while (next < picked.length) {
          final i = next++;
          details[i] = await _trackInfo(picked[i].value);
        }
      }

      await Future.wait(List.generate(_maxParallelRequests, (_) => worker()));

      return [
        for (var i = 0; i < picked.length; i++)
          _ArtistCanvas(picked[i].value, picked[i].key, details[i]),
      ];
    } catch (e) {
      debugPrint('CanvasService._loadArtistCanvases $artistName: $e');
      return null;
    }
  }

  /// The provider's page for an artist and the artist's Spotify id, from the
  /// provider's search. Both null when the provider does not list the
  /// artist.
  Future<({String? slug, String? artistId, bool failed})> _providerArtist(
    String artistName,
    String? artistId,
  ) async {
    final wantedName = DeezerService.normalize(artistName);
    try {
      final response = await http
          .get(
            Uri.parse('$_provider/api/search?q=${Uri.encodeQueryComponent(artistName)}'),
            headers: const {..._browserHeaders, 'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService provider search "$artistName": HTTP ${response.statusCode}');
        return (slug: null, artistId: null, failed: true);
      }

      final artists = json.decode(response.body)['artists'] as List<dynamic>? ?? const [];
      for (final artist in artists) {
        final uri = artist['uri'] as String? ?? '';
        final sameArtist = artistId != null
            ? uri == 'spotify:artist:$artistId'
            : DeezerService.normalize(artist['name'] as String? ?? '') == wantedName;
        if (sameArtist) {
          return (
            slug: artist['slug'] as String?,
            artistId: uri.startsWith('spotify:artist:') ? uri.split(':').last : null,
            failed: false,
          );
        }
      }
      return (slug: null, artistId: null, failed: false);
    } catch (e) {
      debugPrint('CanvasService provider search "$artistName": $e');
      return (slug: null, artistId: null, failed: true);
    }
  }
}
