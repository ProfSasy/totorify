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
    if (SpotifyInternalAuthService.instance.hasSpDcCookie && !_searchBlocked) {
      if (isrc != null) {
        final data = await _spotifyGet('/search?q=isrc:$isrc&type=track&limit=10');
        if (data == null) {
          // A search Spotify is refusing for now is not a passing failure.
          failed = !_searchBlocked;
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
      failed = failed || (byName.failed && !_searchBlocked);
      if (byName.value != null) {
        await StorageService.instance.cacheSpotifyId(song.id, byName.value!);
        return (ids: [byName.value!], failed: false);
      }
    }

    // No login needed: the artist's public page lists the releases; the one
    // the song is on has the track.
    final listed = await _fromArtistDiscography(song);
    failed = failed || listed.failed;
    if (listed.value != null) {
      await StorageService.instance.cacheSpotifyId(song.id, listed.value!);
      return (ids: [listed.value!], failed: false);
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
        final response = await appHttp
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

  /// Finds the song among its artist's releases, as Spotify's public page
  /// lists them: the release with the name of the song's album (or of the
  /// song itself, for a single), opened to read the id of the track with
  /// the song's title.
  Future<_Lookup> _fromArtistDiscography(Song song) async {
    final wanted = DeezerService.normalize(song.title);
    if (wanted.isEmpty) return (value: null, failed: false);

    final artist = await _providerArtist(DeezerService.primaryArtist(song.artist), null);
    if (artist.failed) return (value: null, failed: true);
    final artistId = artist.artistId;
    if (artistId == null) return (value: null, failed: false);

    final discography = await _discography(artistId);
    if (discography == null) return (value: null, failed: true);

    final popular = discography.topTracks[wanted];
    if (popular != null) return (value: popular, failed: false);

    // What is known about the release: the album the catalog names, and
    // what Deezer says of the matched track.
    final deezerId = await _deezerTrackId(song);
    final details = deezerId == null ? null : await DeezerService.instance.trackDetails(deezerId);
    final albums = {
      for (final name in [song.album, details?.album])
        if (DeezerService.normalize(name ?? '').isNotEmpty) DeezerService.normalize(name!),
    };
    final year = details?.released?.year;

    // Most likely first: the album by name, a single named like the song,
    // then whatever came out the same year.
    int rank(({String id, String name, int? year}) release) {
      final name = DeezerService.normalize(release.name);
      if (albums.contains(name)) return 0;
      if (name == wanted) return 1;
      if (year != null && release.year == year) return 2;
      return 3;
    }

    final likely = [
      for (final (i, release) in discography.releases.indexed)
        if (rank(release) < 3) (rank(release), i, release),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));

    var failed = false;
    for (final (_, _, release) in likely.take(_maxReleasesOpened)) {
      final entity = await _embedEntity('album', release.id);
      if (entity == null) {
        failed = true;
        continue;
      }
      for (final track in entity['trackList'] as List<dynamic>? ?? const []) {
        final uri = track['uri'] as String? ?? '';
        if (DeezerService.normalize(track['title'] as String? ?? '') != wanted ||
            !uri.startsWith('spotify:track:')) {
          continue;
        }
        final trackId = uri.split(':').last;
        // Its album is known already: no need to ask for it again.
        _albumOfTrack[trackId] = release.id;
        PlaybackLogService.instance.log(
          'CANVAS',
          '"${song.title}": è il brano Spotify $trackId (da "${release.name}")',
        );
        return (value: trackId, failed: false);
      }
    }
    return (value: null, failed: failed);
  }

  /// Releases and top tracks of an artist, from the state Spotify embeds in
  /// the artist's public web page (no login). Null on failure.
  Future<_Discography?> _discography(String artistId) async {
    final cached = _discographyCache[artistId];
    if (cached != null) return cached;
    try {
      final response = await appHttp
          .get(Uri.parse('https://open.spotify.com/artist/$artistId'), headers: _browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService._discography $artistId: HTTP ${response.statusCode}');
        return null;
      }
      final encoded = _pageState.firstMatch(response.body)?.group(1)?.trim();
      if (encoded == null) {
        debugPrint('CanvasService._discography $artistId: pagina senza dati');
        return null;
      }
      final state = json.decode(utf8.decode(base64.decode(base64.normalize(encoded))));
      final artist = state['entities']?['items']?['spotify:artist:$artistId'];
      if (artist is! Map) return null;

      final releases = <String, ({String id, String name, int? year})>{};
      void add(dynamic section) {
        for (final item in section?['items'] as List<dynamic>? ?? const []) {
          // A section lists releases directly, or groups of them.
          final entries = item is Map && item['releases'] is Map
              ? item['releases']['items'] as List<dynamic>? ?? const []
              : [item];
          for (final entry in entries) {
            if (entry is! Map) continue;
            final uri = entry['uri'] as String? ?? '';
            final name = entry['name'] as String? ?? '';
            if (!uri.startsWith('spotify:album:') || name.isEmpty) continue;
            final id = uri.split(':').last;
            releases.putIfAbsent(
              id,
              () => (id: id, name: name, year: (entry['date']?['year'] as num?)?.toInt()),
            );
          }
        }
      }

      final discography = artist['discography'];
      for (final section in const ['albums', 'singles', 'compilations', 'popularReleasesAlbums']) {
        add(discography?[section]);
      }
      add(artist['relatedContent']?['appearsOn']);

      final topTracks = <String, String>{};
      for (final item in discography?['topTracks']?['items'] as List<dynamic>? ?? const []) {
        final track = item is Map ? item['track'] : null;
        final uri = track is Map ? track['uri'] as String? ?? '' : '';
        final title = DeezerService.normalize(track is Map ? track['name'] as String? ?? '' : '');
        if (title.isNotEmpty && uri.startsWith('spotify:track:')) {
          topTracks.putIfAbsent(title, () => uri.split(':').last);
        }
      }

      final result = _Discography(releases.values.toList(), topTracks);
      if (_discographyCache.length >= _maxArtistsCached) {
        _discographyCache.remove(_discographyCache.keys.first);
      }
      return _discographyCache[artistId] = result;
    } catch (e) {
      debugPrint('CanvasService._discography $artistId: $e');
      return null;
    }
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

  bool get _searchBlocked {
    final until = _searchBlockedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Authenticated Spotify Web API call. Returns null without a login or on
  /// any failure.
  Future<Map<String, dynamic>?> _spotifyGet(String path) async {
    if (_searchBlocked) return null;
    try {
      final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
      if (token == null) return null;
      final response = await appHttp.get(
        Uri.parse('$_spotifyApi$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode == 429) {
        if (!_searchBlocked) {
          final asked = Duration(seconds: int.tryParse(response.headers['retry-after'] ?? '') ?? 0);
          final pause = asked < _searchBlockMin
              ? _searchBlockMin
              : (asked > _searchBlockMax ? _searchBlockMax : asked);
          _searchBlockedUntil = DateTime.now().add(pause);
          PlaybackLogService.instance.log(
            'CANVAS',
            'Spotify rifiuta le ricerche (429): le salto per ${pause.inMinutes} minuti',
          );
        }
        return null;
      }
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
    final direct = await _fromSpotify([trackId]);
    final url = direct?[trackId] ?? direct?[''];
    if (url != null) return (value: url, failed: false);
    // No login, or Spotify gave nothing: the public mirror has the same
    // per-track data and needs no account.
    return _fromCanvasDownloader(trackId);
  }

  /// Spotify's own canvas endpoint, the one its app calls, for several
  /// tracks at once: the canvases found, by track id. It only answers a
  /// logged-in account; null without one or on failure.
  Future<Map<String, String>?> _fromSpotify(List<String> trackIds) async {
    if (trackIds.isEmpty || !SpotifyInternalAuthService.instance.hasSpDcCookie) return null;
    try {
      final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
      if (token == null) {
        debugPrint('CanvasService._fromSpotify: accesso a Spotify non valido, nessun token');
        return null;
      }
      final response = await appHttp.post(
        Uri.parse(_spotifyCanvasEndpoint),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/x-protobuf',
          'Accept': 'application/protobuf',
        },
        body: encodeCanvazRequest(trackIds),
      ).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        debugPrint('CanvasService._fromSpotify: HTTP ${response.statusCode}');
        return null;
      }
      final found = decodeCanvazVideoUrls(response.bodyBytes);
      debugPrint(
        'CanvasService._fromSpotify: ${found.length} canvas su ${trackIds.length} '
        'brani chiesti (${response.bodyBytes.length} byte)',
      );
      return found;
    } catch (e) {
      debugPrint('CanvasService._fromSpotify: $e');
      return null;
    }
  }

  Future<_Lookup> _fromCanvasDownloader(String trackId) async {
    try {
      final response = await appHttp.get(
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
        final url = await _currentUrlOf(candidate);
        if (url == null) continue;
        log.log('CANVAS', '"${song.title}": canvas proprio del brano, trovato tra quelli di $mainArtist');
        return (value: url, failed: false);
      }
    }

    // More artists in common is better; so is having the main artist.
    int affinity(_ArtistCanvas c) {
      final common = c.info?.artists.intersection(songArtists) ?? const <String>{};
      return common.length * 2 + (common.contains(mainKey) ? 1 : 0);
    }

    // A Canvas from another track of the same album: the look the artist
    // gave that release.
    if (trackId != null) {
      final album = await _albumCanvases(trackId);
      final others = album?.canvases.where((c) => c.trackId != trackId).toList() ?? const [];
      if (album != null && others.isNotEmpty) {
        final place = album.trackIds.indexOf(trackId);
        final chosen = _pickFromAlbum(
          others,
          affinity,
          position: place < 0 ? null : place,
          collaboration: songArtists.length >= 2,
        );
        final url = await _currentUrlOf(chosen);
        if (url != null) {
          log.log(
            'CANVAS',
            '"${song.title}": canvas di "${chosen.info?.title}" (stesso album, "${album.title}")',
          );
          return (value: url, failed: false);
        }
      }
    }

    final released = info?.released ?? await _releaseDateFromDeezer(song);

    // The album is not known, or none of its tracks has a Canvas the album
    // lookup could find: a Canvas of the main artist released the same day
    // belongs to the same release.
    if (released != null) {
      final sameRelease = candidates.where((c) {
        final date = c.info?.released;
        return date != null &&
            c.info!.artists.contains(mainKey) &&
            date.difference(released).inHours.abs() < 24;
      }).toList();
      // Most artists in common first; the sort keeps the provider's order
      // among equals.
      final ordered = [
        for (final (i, c) in sameRelease.indexed) (i, c),
      ]..sort((a, b) {
          final byAffinity = affinity(b.$2).compareTo(affinity(a.$2));
          return byAffinity != 0 ? byAffinity : a.$1.compareTo(b.$1);
        });
      final found = await _firstAlive([for (final entry in ordered) entry.$2]);
      if (found != null) {
        log.log('CANVAS',
            '"${song.title}": canvas di "${found.canvas.info?.title}" (stessa uscita)');
        return (value: found.url, failed: false);
      }
    }

    // A collaboration: prefer a Canvas from a track with at least two of the
    // same artists, looking at the other artists' canvases too.
    final fromOthers = <String, _ArtistCanvas>{};
    if (songArtists.length >= 2) {
      final others = songArtists.where((name) => name != mainKey).take(_maxCollaborators);
      for (final other in others) {
        final theirs = await _artistCanvases(other, null);
        for (final candidate in theirs ?? const <_ArtistCanvas>[]) {
          if (candidate.trackId != trackId) {
            fromOthers.putIfAbsent(candidate.url, () => candidate);
          }
        }
      }
      final pool = <String, _ArtistCanvas>{
        for (final candidate in candidates) candidate.url: candidate,
        ...fromOthers,
      };
      final related = pool.values
          .where((c) => (c.info?.artists.intersection(songArtists).length ?? 0) >= 2)
          .toList();
      final top = related.fold<int>(0, (best, c) => affinity(c) > best ? affinity(c) : best);
      final shared = related.where((c) => affinity(c) == top).toList();
      final found = await _firstAlive(_byClosestRelease(released, shared));
      if (found != null) {
        final chosen = found.canvas;
        log.log(
          'CANVAS',
          '"${song.title}": canvas di "${chosen.info?.title}" '
          '(stessi artisti: ${chosen.info!.artists.intersection(songArtists).join(', ')})',
        );
        return (value: found.url, failed: false);
      }
    }

    // Otherwise the main artist's Canvas released closest in time. When the
    // main artist has none at all (a producer, a newcomer), the other
    // artists credited on the track are its authors too.
    var ofMainArtist = true;
    var found = await _firstAlive(_byClosestRelease(released, candidates));
    if (found == null) {
      ofMainArtist = false;
      found = await _firstAlive(
        _byClosestRelease(released, fromOthers.values.toList()),
      );
    }
    if (found == null) return (value: null, failed: false);

    final chosen = found.canvas;
    final chosenDate = chosen.info?.released;
    final gap = (released != null && chosenDate != null)
        ? '${chosenDate.difference(released).inDays.abs()} giorni di distanza'
        : 'data di uscita non nota';
    log.log(
      'CANVAS',
      '"${song.title}": canvas di "${chosen.info?.title ?? chosen.trackId}" '
      '(${ofMainArtist ? 'stesso artista' : 'di un altro artista del brano'}, $gap)',
    );
    return (value: found.url, failed: false);
  }

  // ── Canvas files that are no longer there ─────────────────────────────────
  //
  // When an artist replaces or removes a Canvas, Spotify deletes the old
  // file, but the public archive keeps listing it for a long time. A Canvas
  // picked from a list is therefore checked before it is shown.

  /// False when the file at [url] is gone. A check that cannot be made (no
  /// network) counts as alive: the player will find out.
  Future<bool> _isAlive(String url) async {
    final known = _aliveUrls[url];
    if (known != null) return known;
    try {
      final response = await appHttp
          .head(Uri.parse(url), headers: _browserHeaders)
          .timeout(const Duration(seconds: 5));
      final gone = response.statusCode == 404 ||
          response.statusCode == 403 ||
          response.statusCode == 410;
      if (gone || response.statusCode == 200) {
        if (_aliveUrls.length >= _maxTrackInfoCached) _aliveUrls.remove(_aliveUrls.keys.first);
        _aliveUrls[url] = !gone;
      }
      return !gone;
    } catch (e) {
      debugPrint('CanvasService._isAlive: $e');
      return true;
    }
  }

  /// The Canvas of [candidate] as it is today: the listed file when it is
  /// still there, otherwise the one its track has now. Null when the track
  /// no longer has a Canvas.
  Future<String?> _currentUrlOf(_ArtistCanvas candidate) async {
    if (await _isAlive(candidate.url)) return candidate.url;
    final fresh = (await _fetchCanvas(candidate.trackId)).value;
    if (fresh != null && fresh != candidate.url && await _isAlive(fresh)) return fresh;
    PlaybackLogService.instance.log(
      'CANVAS',
      'canvas di "${candidate.info?.title ?? candidate.trackId}" rimosso da Spotify, lo salto',
    );
    return null;
  }

  /// First of [ordered] whose Canvas still exists.
  Future<({_ArtistCanvas canvas, String url})?> _firstAlive(List<_ArtistCanvas> ordered) async {
    for (final candidate in ordered.take(_maxAliveChecks)) {
      final url = await _currentUrlOf(candidate);
      if (url != null) return (canvas: candidate, url: url);
    }
    return null;
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

  /// The Canvas of an album that suits a track best: for a collaboration one
  /// with the same artists, otherwise the one the album uses most (artists
  /// often give a whole release one Canvas), nearest in the track list.
  _ArtistCanvas _pickFromAlbum(
    List<_ArtistCanvas> canvases,
    int Function(_ArtistCanvas) affinity, {
    required int? position,
    required bool collaboration,
  }) {
    var pool = canvases;
    if (collaboration) {
      final best = pool.map(affinity).reduce(max);
      final shared = pool.where((c) => affinity(c) == best && best >= 4).toList();
      if (shared.isNotEmpty) pool = shared;
    }

    final uses = <String, int>{};
    for (final canvas in pool) {
      uses[canvas.url] = (uses[canvas.url] ?? 0) + 1;
    }
    final mostUsed = uses.values.reduce(max);
    final favourites = pool.where((c) => uses[c.url] == mostUsed).toList();

    if (position == null) return favourites.first;
    var chosen = favourites.first;
    for (final canvas in favourites) {
      final gap = ((canvas.position ?? 1 << 20) - position).abs();
      if (gap < ((chosen.position ?? 1 << 20) - position).abs()) chosen = canvas;
    }
    return chosen;
  }

  /// Canvases of the tracks of the album [trackId] is on. Null when the
  /// album could not be looked up. Tracks of one album resolved together
  /// (a queue playing it) share a single lookup.
  Future<_AlbumCanvases?> _albumCanvases(String trackId) async {
    final albumId = await _albumOf(trackId);
    if (albumId == null) return null;

    final cached = _albumCanvasCache[albumId];
    if (cached != null) return cached;
    final pending = _albumCanvasInFlight[albumId];
    if (pending != null) return pending;

    final future = _loadAlbumCanvases(albumId).then((album) {
      // Failures are not kept, so the next track of the album retries.
      if (album != null) {
        if (_albumCanvasCache.length >= _maxAlbumsCached) {
          _albumCanvasCache.remove(_albumCanvasCache.keys.first);
        }
        _albumCanvasCache[albumId] = album;
      }
      return album;
    });
    _albumCanvasInFlight[albumId] = future;
    // Block body on purpose: returning the removed future from here would
    // make this future wait on itself.
    return future.whenComplete(() {
      _albumCanvasInFlight.remove(albumId);
    });
  }

  /// Spotify album of a track, from the metadata of its public page.
  Future<String?> _albumOf(String trackId) async {
    final known = _albumOfTrack[trackId];
    if (known != null) return known;
    try {
      final response = await appHttp
          .get(Uri.parse('https://open.spotify.com/track/$trackId'), headers: _browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService._albumOf $trackId: HTTP ${response.statusCode}');
        return null;
      }
      final albumId = _albumMeta.firstMatch(response.body)?.group(1);
      if (albumId == null) {
        debugPrint('CanvasService._albumOf $trackId: album non indicato nella pagina');
        return null;
      }
      if (_albumOfTrack.length >= _maxTrackInfoCached) {
        _albumOfTrack.remove(_albumOfTrack.keys.first);
      }
      return _albumOfTrack[trackId] = albumId;
    } catch (e) {
      debugPrint('CanvasService._albumOf $trackId: $e');
      return null;
    }
  }

  Future<_AlbumCanvases?> _loadAlbumCanvases(String albumId) async {
    final entity = await _embedEntity('album', albumId);
    if (entity == null) return null;
    final title = (entity['name'] ?? entity['title'] ?? '') as String;
    final released = DateTime.tryParse(entity['releaseDate']?['isoString'] as String? ?? '');

    // (track id, title, artists) in album order.
    final tracks = <(String, String, List<String>)>[];
    for (final track in (entity['trackList'] as List<dynamic>? ?? const []).take(_maxAlbumTracks)) {
      final uri = track['uri'] as String? ?? '';
      if (!uri.startsWith('spotify:track:')) continue;
      tracks.add((
        uri.split(':').last,
        track['title'] as String? ?? '',
        (track['subtitle'] as String? ?? '').split(',').map((name) => name.trim()).toList(),
      ));
    }
    final ids = [for (final t in tracks) t.$1];

    // Canvases Spotify returned without saying which track they are for
    // (filed under an empty id) cannot be used here.
    var urls = {...?await _fromSpotify(ids)}..remove('');
    var source = 'Spotify';
    if (urls.isEmpty) {
      // No login, or nothing from Spotify: ask the public mirror track by
      // track.
      source = 'archivio pubblico';
      var failures = 0;
      var next = 0;
      Future<void> worker() async {
        while (next < ids.length) {
          final id = ids[next++];
          final canvas = await _fromCanvasDownloader(id);
          if (canvas.value != null) urls[id] = canvas.value!;
          if (canvas.failed) failures++;
        }
      }

      await Future.wait(List.generate(_maxParallelRequests, (_) => worker()));
      // Mostly errors: not an answer worth keeping.
      if (urls.isEmpty && failures > ids.length ~/ 2) return null;
    }

    final found = [
      for (var i = 0; i < tracks.length; i++)
        if (urls[tracks[i].$1] case final String url)
          _ArtistCanvas(
            tracks[i].$1,
            url,
            _TrackInfo(
              title: tracks[i].$2,
              artistId: null,
              artistName: tracks[i].$3.isEmpty ? '' : tracks[i].$3.first,
              artists: {
                for (final name in tracks[i].$3)
                  if (DeezerService.normalize(name).isNotEmpty) DeezerService.normalize(name),
              },
              released: released,
            ),
            position: i,
          ),
    ];
    PlaybackLogService.instance.log(
      'CANVAS',
      'album "$title": ${found.length} canvas su ${tracks.length} brani ($source)',
    );
    return _AlbumCanvases(title, ids, found);
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


  Future<DateTime?> _releaseDateFromDeezer(Song song) async {
    final deezerId = await _deezerTrackId(song);
    if (deezerId == null) return null;
    return (await DeezerService.instance.trackDetails(deezerId))?.released;
  }

  /// Data Spotify embeds in its public player page for a track or artist
  /// (no login). Null on failure.
  Future<Map<String, dynamic>?> _embedEntity(String kind, String id) async {
    try {
      final response = await appHttp
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
        final response = await appHttp
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
      final response = await appHttp
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
