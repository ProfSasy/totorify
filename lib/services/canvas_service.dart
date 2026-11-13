import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'canvaz_proto.dart';
import 'deezer_service.dart';
import 'playback_log_service.dart';
import 'spotify_internal_auth_service.dart';
import 'storage_service.dart';
import 'app_http.dart';
import 'canvas_file_cache.dart';

part 'canvas_track_lookup.dart';
part 'canvas_of_track.dart';
part 'canvas_of_artist.dart';

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

/// What Spotify's public page of an artist lists: the releases (albums,
/// singles, appearances) and the most played tracks.
class _Discography {
  final List<({String id, String name, int? year})> releases;

  /// Normalized title → track id.
  final Map<String, String> topTracks;

  const _Discography(this.releases, this.topTracks);
}

/// A Canvas an artist uploaded for one of their tracks.
class _ArtistCanvas {
  final String trackId;
  final String url;
  final _TrackInfo? info;

  /// Place of the track in its album, when the Canvas was found through it.
  final int? position;

  const _ArtistCanvas(this.trackId, this.url, this.info, {this.position});
}

/// The canvases found on the tracks of one album.
class _AlbumCanvases {
  final String title;

  /// Track ids in album order.
  final List<String> trackIds;
  final List<_ArtistCanvas> canvases;

  const _AlbumCanvases(this.title, this.trackIds, this.canvases);
}

/// Resolves the looping video shown behind the player ("Canvas").
///
/// 1. The track's own Canvas, exactly as Spotify assigns it: uploaded by the
///    artist for that track and looked up by track id.
/// 2. For tracks without one, the most compatible Canvas of the same artist:
///    one from another track of the same album; then, for a collaboration,
///    one from a track with at least two of the same artists; otherwise the
///    one released closest in time. A track is left without a Canvas only
///    when its artist has none at all.
///
/// Finding the track's own Canvas needs its Spotify id. A logged-in account
/// asks Spotify by ISRC (a search Spotify often refuses). Otherwise it is
/// read from the artist's public page: the release the song is on, then the
/// track with its title. Failing that, from MusicBrainz (by ISRC), from the
/// artist's public top tracks, or from the list of the artist's known
/// canvases.
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
  // Answers are also kept on disk, so a restart does not look every song up
  // again. A Canvas found is served for two weeks (and renewed behind the
  // scenes once older than that); "none" is asked again after three days,
  // since artists add them after the release.
  static const Duration _storedTtl = Duration(days: 14);
  static const Duration _storedMissTtl = Duration(days: 3);
  // Bump when the rules that pick a Canvas change: stored answers made by
  // the old rules are then ignored.
  static const int _rulesVersion = 4;
  // How many candidates are checked for a Canvas that still exists.
  static const int _maxAliveChecks = 6;

  // How many of an artist's canvases are compared. Each one costs a request
  // for its track details, once per session.
  static const int _maxArtistCandidates = 30;
  static const int _maxArtistPages = 3;
  static const int _maxParallelRequests = 4;
  static const int _maxArtistsCached = 40;
  static const int _maxTrackInfoCached = 600;
  // Other artists of a collaboration whose canvases are looked at as well.
  static const int _maxCollaborators = 2;
  static const int _maxAlbumTracks = 40;
  // Releases of an artist opened to find the one a song is on.
  static const int _maxReleasesOpened = 4;
  static const int _maxAlbumsCached = 40;
  // Spotify answers 429 to searches for long stretches: not worth asking
  // again at every song.
  static const Duration _searchBlockMin = Duration(minutes: 10);
  static const Duration _searchBlockMax = Duration(hours: 1);

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
  // The state Spotify's web page of an artist carries, as base64 JSON.
  static final RegExp _pageState =
      RegExp(r'<script id="initialState"[^>]*>([^<]+)</script>');
  static final RegExp _spotifyTrackUrl =
      RegExp(r'open\.spotify\.com/track/([A-Za-z0-9]+)');
  // The album of a track, in the metadata of its public page.
  static final RegExp _albumMeta =
      RegExp(r'music:album"\s+content="[^"]*/album/([A-Za-z0-9]+)');
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
  final Map<String, _AlbumCanvases> _albumCanvasCache = {};
  final Map<String, Future<_AlbumCanvases?>> _albumCanvasInFlight = {};
  final Map<String, String> _albumOfTrack = {};
  final Map<String, _Discography> _discographyCache = {};
  DateTime? _searchBlockedUntil;
  // Canvas files checked this session: true when the file is still there.
  final Map<String, bool> _aliveUrls = {};
  Future<void> _musicBrainzQueue = Future.value();
  final ValueNotifier<bool> isCanvasEnabledNotifier = ValueNotifier<bool>(true);

  bool get isEnabled => isCanvasEnabledNotifier.value;

  /// What is known about the Canvas of [songId] without asking anyone: the
  /// video saved with its download, this session's answer, or the answer
  /// stored by an earlier one. Null when nothing is known.
  ({String? url})? _knownAnswer(String songId) {
    final local = _savedCanvas(songId);
    if (local != null) return (url: local);

    final cached = _canvasCache[songId];
    if (cached != null && DateTime.now().isBefore(cached.$2)) {
      return (url: _playable(cached.$1));
    }

    final stored = StorageService.instance.getCanvasAnswer(songId, _rulesVersion);
    if (stored == null) return null;
    // An old Canvas is still shown (it is renewed when it is next asked
    // for); an old "none" is not trusted.
    if (stored.url != null) return (url: _playable(stored.url));
    final fresh = DateTime.now().difference(stored.savedAt) < _storedMissTtl;
    return fresh ? (url: null) : null;
  }

  /// The Canvas video saved with the download of [songId], as a file URL.
  String? _savedCanvas(String songId) {
    final storage = StorageService.instance;
    if (!storage.hasLocalCanvas(songId)) return null;
    return Uri.file(storage.localCanvasPath(songId)).toString();
  }

  /// What to play for the Canvas at [url]: the file kept from the last time
  /// it was shown, when there is one, otherwise the address itself.
  String? _playable(String? url) =>
      url == null ? null : (CanvasFileCache.instance.fileUrlFor(url) ?? url);

  String? getCachedCanvasUrlSync(String songId) {
    if (!isEnabled) return null;
    return _knownAnswer(songId)?.url;
  }

  /// True when the answer for [songId] is known, including "no canvas".
  bool hasCachedResult(String songId) => _knownAnswer(songId) != null;

  void setCanvasEnabled(bool enabled) {
    isCanvasEnabledNotifier.value = enabled;
    StorageService.instance.setCanvasEnabled(enabled);
    // Switched off: the videos kept for replays give their space back.
    if (!enabled) unawaited(CanvasFileCache.instance.clear());
  }

  /// Keeps the Canvas of [song] as a file, so that the next time the song
  /// plays its video starts at once. Songs that are downloaded have theirs
  /// saved with the download instead.
  Future<void> keepForReplay(Song song) async {
    if (!isEnabled || StorageService.instance.isDownloaded(song.id)) return;
    try {
      final url = await remoteCanvasUrl(song);
      if (url != null && url.isNotEmpty) await CanvasFileCache.instance.keep(url);
    } catch (e) {
      debugPrint('CanvasService.keepForReplay: $e');
    }
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
    final storage = StorageService.instance;
    // The file kept for replays is the first suspect.
    final remote =
        _canvasCache[songId]?.$1 ?? storage.getCanvasAnswer(songId, _rulesVersion)?.url;
    if (remote != null) CanvasFileCache.instance.drop(remote);
    _canvasCache.remove(songId);
    unawaited(storage.removeCanvasAnswer(songId));
    // A saved video that does not play is a broken file: drop it, the next
    // pass over the downloads saves it again.
    if (storage.hasLocalCanvas(songId)) {
      storage.setLocalCanvas(songId, saved: false);
      unawaited(() async {
        try {
          await File(storage.localCanvasPath(songId)).delete();
        } catch (_) {
          // Already gone.
        }
      }());
    }
  }

  /// The Canvas of [songId] could not be played, twice: no Canvas for a
  /// while, so the player shows the cover instead of trying again.
  void giveUp(String songId) {
    _canvasCache[songId] = (null, DateTime.now().add(_failureTtl));
    unawaited(StorageService.instance.removeCanvasAnswer(songId));
  }

  /// Forgets every answer. Logging in or out of Spotify changes what can be
  /// found, including for songs already answered "no canvas". Videos saved
  /// with the downloads are kept.
  void clearCache() {
    _canvasCache.clear();
    _albumCanvasCache.clear();
    _searchBlockedUntil = null;
    unawaited(StorageService.instance.clearCanvasAnswers());
  }

  /// Canvas video URL for [song], or null when it has none: the video saved
  /// with its download when there is one (a file URL, nothing to fetch),
  /// otherwise [remoteCanvasUrl].
  Future<String?> getCanvasUrl(Song song) {
    if (!isEnabled) return Future.value(null);
    final saved = _savedCanvas(song.id);
    if (saved != null) return Future.value(saved);
    return remoteCanvasUrl(song).then(_playable);
  }

  /// Canvas video of [song] on Spotify's servers, or null when it has none.
  /// Answered from this session's cache, then from the answer stored on
  /// disk, and only then by looking it up. Concurrent requests for the same
  /// song (background prefetch and the player) share one lookup.
  Future<String?> remoteCanvasUrl(Song song) {
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

    final stored = StorageService.instance.getCanvasAnswer(song.id, _rulesVersion);
    if (stored != null) {
      final age = DateTime.now().difference(stored.savedAt);
      final fresh = age < (stored.url == null ? _storedMissTtl : _storedTtl);
      if (fresh || stored.url != null) {
        _canvasCache[song.id] = (stored.url, DateTime.now().add(_cacheTtl));
        // Old but usable: shown now, looked up again behind the scenes.
        if (!fresh) unawaited(_lookUp(song));
        return Future.value(stored.url);
      }
    }

    return _lookUp(song);
  }

  Future<String?> _lookUp(Song song) {
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
    // A lookup that failed (no network) is not an answer worth keeping.
    if (!result.failed) {
      unawaited(StorageService.instance
          .saveCanvasAnswer(song.id, result.value, _rulesVersion));
    }
    return result.value;
  }

  Future<_Lookup> _resolve(Song song) async {
    final log = PlaybackLogService.instance;

    final track = await _spotifyTrackIds(song);
    var failed = track.failed;

    // 1. The track's own Canvas. One recording can exist as several Spotify
    // tracks (single, album version) and only some carry the Canvas.
    for (final trackId in track.ids) {
      final own = await _fetchCanvas(trackId);
      if (own.value != null && await _isAlive(own.value!)) {
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

  /// [candidates] from the one released closest to [target] to the farthest.
  /// Unknown dates go last; with no [target] the order is kept (the provider
  /// lists the most looked-up canvases first).
  static List<_ArtistCanvas> _byClosestRelease(DateTime? target, List<_ArtistCanvas> candidates) {
    if (target == null) return candidates;
    Duration gapOf(_ArtistCanvas c) {
      final date = c.info?.released;
      return date == null ? const Duration(days: 365000) : date.difference(target).abs();
    }

    final ordered = [for (final (i, c) in candidates.indexed) (i, c)]
      ..sort((a, b) {
        final byGap = gapOf(a.$2).compareTo(gapOf(b.$2));
        return byGap != 0 ? byGap : a.$1.compareTo(b.$1);
      });
    return [for (final entry in ordered) entry.$2];
  }
}
