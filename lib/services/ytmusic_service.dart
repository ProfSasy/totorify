import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Playlist;
import '../models/song.dart';
import '../models/playlist.dart';
import 'auth_service.dart';
import 'storage_service.dart';
import 'app_http.dart';

/// Where the audio of a YouTube video can be streamed from, and its length.
typedef _VideoStreams = ({String? audioUrl, String? hlsManifestUrl, Duration? duration});

/// YouTube Music service using authenticated & Apple VisionOS InnerTube APIs
/// for rock-solid stream extraction on iOS devices.
class YTMusicService {
  static final YTMusicService instance = YTMusicService._internal();
  YTMusicService._internal();

  final YoutubeExplode _yt = YoutubeExplode();
  // ── InnerTube API constants ───────────────────────────────────────────────

  static const _innerTubeApiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-NKNELL6OA';
  static const _baseUrl = 'https://music.youtube.com/youtubei/v1';

  static const _visionOsUa =
      'com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; IT)';

  // What AVPlayer itself sends when it fetches a stream.
  static const _appleMediaUa =
      'AppleCoreMedia/1.0.0.23G93 (iPhone; U; CPU OS 26_6 like Mac OS X; it_it)';

  static const _visionOsHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': _visionOsUa,
    'X-Goog-Api-Format-Version': '2',
  };

  String? _cachedVisitorData;
  DateTime? _visitorDataExpiry;

  // ── Shared short-TTL caches ─────────────────────────────────────────────
  // Signed googlevideo URLs stay valid for hours: paying the InnerTube round
  // trip twice for the same video in one session is pure latency. Playback,
  // downloads, canvas and the matcher all share these caches, and parallel
  // requests for the same id are collapsed into one.

  static const Duration _urlCacheTtl = Duration(hours: 3);
  static const Duration _searchCacheTtl = Duration(minutes: 10);
  static const int _cacheMaxEntries = 80;

  final Map<String, (String, DateTime)> _audioUrlCache = {};
  final Map<String, Future<String?>> _audioUrlInFlight = {};
  final Map<String, (_VideoStreams, DateTime)> _streamsCache = {};
  final Map<String, Future<_VideoStreams?>> _streamsInFlight = {};
  final Map<String, (String, DateTime)> _hlsAudioCache = {};
  final Map<String, (List<Song>, DateTime)> _searchCache = {};
  final Map<String, Future<List<Song>>> _searchInFlight = {};

  void _pruneCache(Map<dynamic, dynamic> cache) {
    while (cache.length > _cacheMaxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  String _randomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// Obtains and caches a valid visitorData token from YouTube
  Future<String?> _getVisitorData({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedVisitorData != null &&
        _visitorDataExpiry != null &&
        DateTime.now().isBefore(_visitorDataExpiry!)) {
      return _cachedVisitorData;
    }

    try {
      final body = {
        'context': {
          'client': {
            'clientName': 'VISIONOS',
            'clientVersion': '1.04',
            'clientScreen': 'WATCH',
            'platform': 'MOBILE',
            'deviceMake': 'Apple',
            'deviceModel': 'RealityDevice17,1',
            'osName': 'visionOS',
            'osVersion': '26.6.0.23O770',
            'hl': 'it',
            'gl': 'IT',
          }
        }
      };

      final resp = await appHttp.post(
        Uri.parse(
            'https://youtubei.googleapis.com/youtubei/v1/visitor_id?prettyPrint=false'),
        headers: _visionOsHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final visitor =
            data['responseContext']?['visitorData'] as String?;
        if (visitor != null && visitor.isNotEmpty) {
          _cachedVisitorData = visitor;
          _visitorDataExpiry = DateTime.now().add(const Duration(hours: 12));
          return visitor;
        }
      }
    } catch (e) { debugPrint('YTMusic.getVisitorData: $e'); }
    return null;
  }

  /// ANDROID_MUSIC client payload — matches YouTube Music Android app.
  Map<String, dynamic> _androidMusicContext() => {
        'context': {
          'client': {
            'clientName': 'ANDROID_MUSIC',
            'clientVersion': '7.27.52',
            'androidSdkVersion': 34,
            'userAgent':
                'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14; en_US) gzip',
            'hl': 'it',
            'gl': 'IT',
            'utcOffsetMinutes': 60,
          },
        },
      };

  // ── Stream Extraction (MULTI-ENGINE ARCHITECTURE) ──────────────────────────

  /// Get a playable audio stream URL for [videoId]. Resolutions are cached
  /// (and in-flight deduped), so replaying a song, downloading what just
  /// played or resolving the queue ahead never pays the round trip twice.
  ///
  /// 1. VisionOS InnerTube engine (100% reliable, zero bot block, direct unthrottled streams)
  /// 2. Authenticated InnerTube engine (if user signed into Google)
  /// 3. youtube_explode_dart engine
  Future<String?> getAudioStreamUrl(String videoId, {bool force = false}) {
    if (videoId.isEmpty) return Future.value(null);
    if (force) {
      _forget(videoId);
    } else {
      final cached = _audioUrlCache[videoId];
      if (cached != null && DateTime.now().isBefore(cached.$2)) {
        return Future.value(cached.$1);
      }
    }
    final pending = _audioUrlInFlight[videoId];
    if (pending != null) return pending;

    final future = _resolveAudioStreamUrl(videoId);
    _audioUrlInFlight[videoId] = future;
    return future.whenComplete(() => _audioUrlInFlight.remove(videoId));
  }

  /// Forgets every remembered stream URL. They are picked by the audio
  /// quality setting, so a change of it must not keep serving the old ones.
  void clearStreamCaches() {
    _audioUrlCache.clear();
    _streamsCache.clear();
    _hlsAudioCache.clear();
  }

  /// Drops everything remembered about the streams of [videoId].
  void _forget(String videoId) {
    _audioUrlCache.remove(videoId);
    _streamsCache.remove(videoId);
    _hlsAudioCache.remove(videoId);
  }

  Future<String?> _resolveAudioStreamUrl(String videoId) async {
    final url = await _getAudioStreamUrlUncached(videoId);
    if (url != null && url.isNotEmpty) {
      _audioUrlCache[videoId] = (url, DateTime.now().add(_urlCacheTtl));
      _pruneCache(_audioUrlCache);
    }
    return url;
  }

  Future<String?> _getAudioStreamUrlUncached(String videoId) async {
    // 1. Primary engine: VisionOS InnerTube
    final visionUrl = (await _visionOsStreams(videoId))?.audioUrl;
    if (visionUrl != null) return visionUrl;

    // 2. Secondary engine: Authenticated InnerTube with OAuth token
    final token = await AuthService.instance.getValidAccessToken();
    if (token != null) {
      final authUrl = await _innerTubeStreamUrl(videoId, token: token);
      if (authUrl != null) return authUrl;
    }

    // 3. Last resort: youtube_explode_dart
    return _explodeStreamUrl(videoId);
  }

  /// VisionOS InnerTube player response. Shared by the audio and canvas
  /// extraction engines: the VISIONOS client is never bot-blocked and serves
  /// direct (unsigned) stream URLs, which is what AVPlayer needs on iOS.
  Future<Map<String, dynamic>?> _visionOsPlayerResponse(String videoId) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final visitorData = await _getVisitorData(forceRefresh: attempt > 0);
        if (visitorData == null) continue;

        final t = _randomString(12);
        final cpn = _randomString(16);
        final url =
            'https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=$t&id=$videoId';

        final body = {
          'context': {
            'client': {
              'clientName': 'VISIONOS',
              'clientVersion': '1.04',
              'clientScreen': 'WATCH',
              'platform': 'MOBILE',
              'deviceMake': 'Apple',
              'deviceModel': 'RealityDevice17,1',
              'osName': 'visionOS',
              'osVersion': '26.6.0.23O770',
              'hl': 'it',
              'gl': 'IT',
              'visitorData': visitorData,
            }
          },
          'videoId': videoId,
          'cpn': cpn,
          'contentCheckOk': true,
          'racyCheckOk': true,
        };

        final resp = await appHttp.post(
          Uri.parse(url),
          headers: _visionOsHeaders,
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 12));

        if (resp.statusCode != 200) {
          debugPrint('YTMusic.visionOS $videoId: HTTP ${resp.statusCode}');
          continue;
        }

        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final status = data['playabilityStatus']?['status'] as String?;
        if (status != 'OK') {
          // The reason tells a removed video from a region or bot block.
          debugPrint('YTMusic.visionOS $videoId: stato $status '
              '(${data['playabilityStatus']?['reason'] ?? 'nessun motivo'})');
          continue;
        }
        return data;
      } catch (e) { debugPrint('YTMusic.visionOS: $e'); }
    }
    return null;
  }

  /// True when a still-valid stream URL is remembered for [videoId].
  bool hasCachedAudioUrl(String videoId) {
    final cached = _audioUrlCache[videoId];
    return cached != null && DateTime.now().isBefore(cached.$2);
  }

  /// What YouTube says about the streams of [videoId]: one request serves
  /// the direct stream, the HLS manifest and the length. [force] asks again
  /// and forgets every URL remembered for the video.
  Future<_VideoStreams?> _visionOsStreams(String videoId, {bool force = false}) {
    if (force) {
      _forget(videoId);
    } else {
      final cached = _streamsCache[videoId];
      if (cached != null && DateTime.now().isBefore(cached.$2)) {
        return Future.value(cached.$1);
      }
    }
    final pending = _streamsInFlight[videoId];
    if (pending != null) return pending;

    final future = _loadVisionOsStreams(videoId);
    _streamsInFlight[videoId] = future;
    // Block body on purpose: returning the removed future from here would
    // make this future wait on itself.
    return future.whenComplete(() {
      _streamsInFlight.remove(videoId);
    });
  }

  Future<_VideoStreams?> _loadVisionOsStreams(String videoId) async {
    final data = await _visionOsPlayerResponse(videoId);
    if (data == null) return null;
    final streaming = data['streamingData'] as Map<String, dynamic>?;
    final formats = streaming?['adaptiveFormats'] as List<dynamic>? ?? [];

    // The audio formats give the length to the millisecond; the video
    // details only in whole seconds.
    var millis = 0;
    for (final format in formats) {
      if (!((format['mimeType'] as String?)?.startsWith('audio/') ?? false)) continue;
      final value = int.tryParse('${format['approxDurationMs'] ?? ''}') ?? 0;
      if (value > millis) millis = value;
    }
    if (millis == 0) {
      millis = (int.tryParse('${data['videoDetails']?['lengthSeconds'] ?? ''}') ?? 0) * 1000;
    }

    final audioUrl = _pickBestAppleCompatibleAudioUrl(formats);
    final hls = streaming?['hlsManifestUrl'] as String?;
    final streams = (
      audioUrl: (audioUrl == null || audioUrl.isEmpty) ? null : audioUrl,
      hlsManifestUrl: (hls == null || hls.isEmpty) ? null : hls,
      duration: millis > 0 ? Duration(milliseconds: millis) : null,
    );
    final expires = DateTime.now().add(_urlCacheTtl);
    _streamsCache[videoId] = (streams, expires);
    _pruneCache(_streamsCache);
    if (streams.audioUrl != null) {
      _audioUrlCache[videoId] = (streams.audioUrl!, expires);
      _pruneCache(_audioUrlCache);
    }
    return streams;
  }

  /// Real length of [videoId], known once its streams have been looked up.
  Duration? streamDuration(String videoId) => _streamsCache[videoId]?.$1.duration;

  /// HLS manifest of [videoId] with every rendition, video included: the
  /// last resort, since playing it downloads the video as well.
  Future<String?> getHlsUrl(String videoId) async =>
      (await _visionOsStreams(videoId))?.hlsManifestUrl;

  /// Audio-only HLS playlist of [videoId]: the format AVPlayer handles best.
  /// Unlike the direct stream, its length is reported correctly and seeking
  /// fetches only the segment needed. Null when the video has none.
  Future<String?> getHlsAudioUrl(String videoId, {bool force = false}) async {
    if (videoId.isEmpty) return null;
    if (!force) {
      final cached = _hlsAudioCache[videoId];
      if (cached != null && DateTime.now().isBefore(cached.$2)) return cached.$1;
    }
    final manifest = (await _visionOsStreams(videoId, force: force))?.hlsManifestUrl;
    if (manifest == null) return null;

    try {
      final response = await appHttp
          .get(Uri.parse(manifest), headers: const {'User-Agent': _appleMediaUa})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('YTMusic.hlsAudio $videoId: HTTP ${response.statusCode}');
        return null;
      }
      final url = pickHlsAudioRendition(
        response.body,
        Uri.parse(manifest),
        highQuality: StorageService.instance.isHighQuality,
      );
      if (url == null) {
        debugPrint('YTMusic.hlsAudio $videoId: nessuna traccia solo audio nel manifest');
        return null;
      }
      _hlsAudioCache[videoId] = (url, DateTime.now().add(_urlCacheTtl));
      _pruneCache(_hlsAudioCache);
      return url;
    } catch (e) {
      debugPrint('YTMusic.hlsAudio $videoId: $e');
      return null;
    }
  }

  static final RegExp _hlsAttribute = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

  static Map<String, String> _hlsAttributes(String line) => {
        for (final match in _hlsAttribute.allMatches(line.substring(line.indexOf(':') + 1)))
          match.group(1)!: match.group(2)!.replaceAll('"', ''),
      };

  /// Picks the audio-only playlist out of an HLS master manifest: the
  /// default track (not a dubbed one), AAC-LC for high quality and the
  /// lighter HE-AAC otherwise.
  static String? pickHlsAudioRendition(String manifest, Uri base, {required bool highQuality}) {
    final lines = manifest.split('\n').map((line) => line.trim()).toList();

    // Which codec each audio group carries, from the variants that use it.
    final groupCodec = <String, String>{};
    for (final line in lines) {
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final attributes = _hlsAttributes(line);
      final group = attributes['AUDIO'];
      if (group == null) continue;
      final codec = (attributes['CODECS'] ?? '')
          .split(',')
          .map((c) => c.trim())
          .firstWhere((c) => c.startsWith('mp4a'), orElse: () => '');
      if (codec.isNotEmpty) groupCodec.putIfAbsent(group, () => codec);
    }

    final renditions = <({String uri, String group, bool isDefault})>[];
    for (final line in lines) {
      if (!line.startsWith('#EXT-X-MEDIA')) continue;
      final attributes = _hlsAttributes(line);
      final uri = attributes['URI'];
      if (attributes['TYPE'] != 'AUDIO' || uri == null || uri.isEmpty) continue;
      renditions.add((
        uri: uri,
        group: attributes['GROUP-ID'] ?? '',
        isDefault: attributes['DEFAULT'] == 'YES',
      ));
    }
    if (renditions.isEmpty) return null;

    final originals = renditions.where((r) => r.isDefault).toList();
    final pool = originals.isNotEmpty ? originals : renditions;
    // mp4a.40.2 is AAC-LC (about 128 kbps), mp4a.40.5 is HE-AAC (about 48).
    bool isFull(({String uri, String group, bool isDefault}) r) =>
        groupCodec[r.group] == 'mp4a.40.2';
    final chosen = pool.firstWhere(
      (r) => isFull(r) == highQuality,
      orElse: () => pool.first,
    );
    return base.resolve(chosen.uri).toString();
  }

  /// Selects the best audio stream natively compatible with Apple iOS AVPlayer.
  /// Priority:
  ///   1. audio/mp4 (AAC itag 140 @ 128kbps or itag 139 @ 48kbps) - natively supported by AVFoundation
  ///   2. Any available audio stream as fallback
  String? _pickBestAppleCompatibleAudioUrl(List<dynamic> formats) {
    final audioFormats = formats.where((f) {
      final mime = f['mimeType'] as String? ?? '';
      return mime.startsWith('audio/') && f['url'] != null;
    }).toList();

    if (audioFormats.isEmpty) return null;

    // Filter for audio/mp4 (AAC) first - essential for iOS AVPlayer
    final mp4Formats = audioFormats.where((f) {
      final mime = (f['mimeType'] as String? ?? '').toLowerCase();
      return mime.contains('mp4') || mime.contains('m4a') || mime.contains('mp4a');
    }).toList();

    final targetList = mp4Formats.isNotEmpty ? mp4Formats : audioFormats;

    targetList.sort((a, b) {
      final bBit = (b['bitrate'] ?? b['averageBitrate'] as int?) ?? 0;
      final aBit = (a['bitrate'] ?? a['averageBitrate'] as int?) ?? 0;
      return bBit.compareTo(aBit);
    });

    // "Alta qualità" picks the highest bitrate; otherwise prefer the lightest
    // stream to save data on the go.
    final hq = StorageService.instance.isHighQuality;
    final chosen = hq ? targetList.first : targetList.last;
    return chosen['url'] as String?;
  }

  Future<String?> _innerTubeStreamUrl(String videoId, {String? token}) async {
    try {
      final body = _androidMusicContext();
      body['videoId'] = videoId;
      body['params'] = 'gAIB';
      body['playbackContext'] = {
        'contentPlaybackContext': {
          'signatureTimestamp': 20248,
          'html5Preference': 'HTML5_PREF_WANTS',
        },
      };

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Goog-Api-Format-Version': '1',
        'User-Agent':
            'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip',
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
      };

      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
        headers['X-Goog-AuthUser'] = '0';
      }

      final response = await appHttp.post(
        Uri.parse('$_baseUrl/player?key=$_innerTubeApiKey'),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['playabilityStatus']?['status'] as String?;
      if (status != 'OK') return null;

      final adaptiveFormats =
          data['streamingData']?['adaptiveFormats'] as List<dynamic>? ?? [];

      return _pickBestAppleCompatibleAudioUrl(adaptiveFormats);
    } catch (e) {
      debugPrint('YTMusic.innerTubeStream: $e');
      return null;
    }
  }

  Future<String?> _explodeStreamUrl(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      final audioStreams = manifest.audioOnly;
      if (audioStreams.isEmpty) return null;

      // Prefer native MP4 container (AAC) for iOS
      final mp4Streams = audioStreams.where((s) => s.container == StreamContainer.mp4).toList();
      if (mp4Streams.isNotEmpty) {
        return mp4Streams.withHighestBitrate().url.toString();
      }
      return audioStreams.withHighestBitrate().url.toString();
    } catch (e) {
      debugPrint('YTMusic.explodeStream: $e');
      return null;
    }
  }

  // ── Search ───────────────────────────────────────────────────────────────

  Future<List<Song>> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    // Short-TTL cache + in-flight dedupe: repeated queries (recent searches,
    // matcher fallbacks, canvas searches, the alternative-sources sheet)
    // come back instantly.
    final cached = _searchCache[clean];
    if (cached != null && DateTime.now().isBefore(cached.$2)) {
      return cached.$1;
    }
    final pending = _searchInFlight[clean];
    if (pending != null) return pending;

    final future = _searchUncached(clean);
    _searchInFlight[clean] = future;
    return future.whenComplete(() => _searchInFlight.remove(clean));
  }

  Future<List<Song>> _searchUncached(String query) async {
    // 1. Primary: YouTube Music InnerTube (official studio tracks, accurate durations, HD square covers)
    final out = await _innerTubeSearch(query);
    
    if (out.isNotEmpty) {
      _searchCache[query] = (
        List.unmodifiable(out),
        DateTime.now().add(_searchCacheTtl),
      );
      _pruneCache(_searchCache);
    }
    return out;
  }

  Future<List<Song>> _innerTubeSearch(String query) async {
    try {
      final body = _androidMusicContext();
      body['query'] = query;
      // Filter for songs (Brani) to get official studio audio tracks rather than videos
      body['params'] = 'EgWKAQIIAWoQEAMQChAJEBEQBBAFEA8QEQ%3D%3D';

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Goog-Api-Format-Version': '1',
      };

      final response = await appHttp.post(
        Uri.parse('$_baseUrl/search?key=$_innerTubeApiKey'),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('YTMusic.innerTubeSearch "$query": HTTP ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseMusicSearchResults(data);
    } catch (e) {
      debugPrint('YTMusic.innerTubeSearch: $e');
      return [];
    }
  }

  List<Song> _parseMusicSearchResults(Map<String, dynamic> data) {
    final songs = <Song>[];
    try {
      final contents = data['contents']?['tabbedSearchResultsRenderer']
              ?['tabs']?[0]?['tabRenderer']?['content']
              ?['sectionListRenderer']?['contents'] as List<dynamic>?;

      if (contents == null) return songs;

      for (final section in contents) {
        // 1. Check musicCardShelfRenderer (Top Result card)
        final cardShelf = section['musicCardShelfRenderer'] as Map<String, dynamic>?;
        if (cardShelf != null) {
          final topSong = _parseCardShelf(cardShelf);
          if (topSong != null && !songs.any((s) => s.id == topSong.id)) {
            songs.add(topSong);
          }
        }

        // 2. Check musicShelfRenderer (List of results)
        final shelf = section['musicShelfRenderer'] as Map<String, dynamic>?;
        if (shelf == null) continue;

        final items = shelf['contents'] as List<dynamic>? ?? [];
        for (final item in items) {
          if (item is! Map<String, dynamic>) continue;
          final song = _parseAnyMusicItem(item);
          if (song != null && !songs.any((s) => s.id == song.id)) {
            songs.add(song);
          }
        }
      }
    } catch (e) { debugPrint('YTMusic.parseSearch: $e'); }
    return songs;
  }

  Song? _parseCardShelf(Map<String, dynamic> card) {
    try {
      final titleRuns = card['title']?['runs'] as List<dynamic>?;
      final title = titleRuns?.map((r) => r['text'] ?? '').join('') ?? '';
      if (title.isEmpty) return null;

      final videoId = card['onTap']?['watchEndpoint']?['videoId'] as String? ??
          card['buttons']?[0]?['buttonRenderer']?['navigationEndpoint']
              ?['watchEndpoint']?['videoId'] as String?;
      if (videoId == null || videoId.isEmpty) return null;

      final subtitleRuns = card['subtitle']?['runs'] as List<dynamic>?;
      String artist = '';
      String durationStr = '';
      if (subtitleRuns != null) {
        for (final r in subtitleRuns) {
          final t = (r['text'] as String? ?? '').trim();
          if (t == '•' || t.isEmpty) continue;
          if (RegExp(r'^\d+:\d+(:\d+)?$').hasMatch(t)) {
            durationStr = t;
          } else if (artist.isEmpty && !t.contains('brano') && !t.contains('song')) {
            artist = t;
          }
        }
      }

      final thumbnails = card['thumbnail']?['musicThumbnailRenderer']
          ?['thumbnail']?['thumbnails'] as List<dynamic>?;
      final thumbUrlRaw = thumbnails?.isNotEmpty == true ? (thumbnails!.last['url'] as String? ?? '') : '';
      final thumbUrl = thumbUrlRaw.replaceAll(RegExp(r'=w\d+-h\d+'), '=w544-h544');

      return Song(
        id: videoId,
        title: title,
        artist: artist.isEmpty ? 'Artista' : artist,
        duration: _parseDuration(durationStr),
        thumbnailUrl: thumbUrl,
      );
    } catch (e) {
      debugPrint('YTMusic.parseCardShelf: $e');
      return null;
    }
  }

  Song? _parseAnyMusicItem(Map<String, dynamic> item) {
    if (item.containsKey('musicTwoColumnItemRenderer')) {
      return _parseTwoColumnItem(item['musicTwoColumnItemRenderer'] as Map<String, dynamic>);
    }
    if (item.containsKey('musicResponsiveListItemRenderer')) {
      return _parseMusicListItem(item['musicResponsiveListItemRenderer'] as Map<String, dynamic>);
    }
    return null;
  }

  Song? _parseTwoColumnItem(Map<String, dynamic> renderer) {
    try {
      final videoId = renderer['navigationEndpoint']?['watchEndpoint']?['videoId'] as String?;
      if (videoId == null || videoId.isEmpty) return null;

      final titleRuns = renderer['title']?['runs'] as List<dynamic>?;
      final title = titleRuns?.map((r) => r['text'] ?? '').join('') ?? '';
      if (title.isEmpty) return null;

      final subtitleRuns = renderer['subtitle']?['runs'] as List<dynamic>?;
      String artist = '';
      String durationStr = '';
      if (subtitleRuns != null) {
        for (final r in subtitleRuns) {
          final t = (r['text'] as String? ?? '').trim();
          if (t == '•' || t.isEmpty) continue;
          if (RegExp(r'^\d+:\d+(:\d+)?$').hasMatch(t)) {
            durationStr = t;
          } else if (artist.isEmpty && !t.toLowerCase().contains('riproduzion') && !t.toLowerCase().contains('view')) {
            artist = t;
          }
        }
      }

      final thumbnails = renderer['thumbnail']?['musicThumbnailRenderer']
          ?['thumbnail']?['thumbnails'] as List<dynamic>?;
      final thumbUrlRaw = thumbnails?.isNotEmpty == true ? (thumbnails!.last['url'] as String? ?? '') : '';
      final thumbUrl = thumbUrlRaw.replaceAll(RegExp(r'=w\d+-h\d+'), '=w544-h544');

      return Song(
        id: videoId,
        title: title,
        artist: artist.isEmpty ? 'Artista' : artist,
        duration: _parseDuration(durationStr),
        thumbnailUrl: thumbUrl,
      );
    } catch (e) {
      debugPrint('YTMusic.parseTwoColumnItem: $e');
      return null;
    }
  }

  Duration _parseDuration(String durationStr) {
    if (durationStr.isEmpty) return Duration.zero;
    final parts = durationStr.split(':');
    if (parts.length == 2) {
      return Duration(
        minutes: int.tryParse(parts[0]) ?? 0,
        seconds: int.tryParse(parts[1]) ?? 0,
      );
    } else if (parts.length == 3) {
      return Duration(
        hours: int.tryParse(parts[0]) ?? 0,
        minutes: int.tryParse(parts[1]) ?? 0,
        seconds: int.tryParse(parts[2]) ?? 0,
      );
    }
    return Duration.zero;
  }

  Song? _parseMusicListItem(Map<String, dynamic> renderer) {
    try {
      final overlay = renderer['overlay'];
      final videoId = overlay?['musicItemThumbnailOverlayRenderer']
              ?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']
              ?['watchEndpoint']?['videoId'] as String? ??
          _extractVideoId(renderer);
      if (videoId == null || videoId.isEmpty) return null;

      final flexColumns =
          renderer['flexColumns'] as List<dynamic>? ?? [];
      String title = '';
      String artist = '';
      String durationStr = '';

      if (flexColumns.isNotEmpty) {
        final col0 = flexColumns[0]['musicResponsiveListItemFlexColumnRenderer']
            ?['text']?['runs'] as List<dynamic>?;
        title = col0?.map((r) => r['text'] ?? '').join('') ?? '';
      }
      if (flexColumns.length > 1) {
        final col1 = flexColumns[1]['musicResponsiveListItemFlexColumnRenderer']
            ?['text']?['runs'] as List<dynamic>? ??
            [];
        for (final run in col1) {
          final text = run['text'] as String? ?? '';
          final navigationEndpoint = run['navigationEndpoint'];
          if (navigationEndpoint != null && artist.isEmpty) {
            artist = text;
          } else if (RegExp(r'^\d+:\d+(:\d+)?$').hasMatch(text.trim())) {
            durationStr = text.trim();
          }
        }
        if (artist.isEmpty && col1.isNotEmpty) {
          artist = col1.first['text'] as String? ?? '';
        }
      }

      // Check fixedColumns for exact duration
      final fixedColumns = renderer['fixedColumns'] as List<dynamic>? ?? [];
      if (fixedColumns.isNotEmpty && durationStr.isEmpty) {
        final fixedRuns = fixedColumns[0]['musicResponsiveListItemFixedColumnRenderer']
            ?['text']?['runs'] as List<dynamic>?;
        if (fixedRuns != null && fixedRuns.isNotEmpty) {
          final t = (fixedRuns.first['text'] as String? ?? '').trim();
          if (RegExp(r'^\d+:\d+(:\d+)?$').hasMatch(t)) {
            durationStr = t;
          }
        }
      }

      final thumbnails =
          renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
              ?['thumbnails'] as List<dynamic>?;
      final thumbUrlRaw = thumbnails?.isNotEmpty == true ? (thumbnails!.last['url'] as String? ?? '') : '';
      final thumbUrl = thumbUrlRaw.replaceAll(RegExp(r'=w\d+-h\d+'), '=w544-h544');

      if (title.isEmpty) return null;

      return Song(
        id: videoId,
        title: title,
        artist: artist.isEmpty ? 'Artista' : artist,
        duration: _parseDuration(durationStr),
        thumbnailUrl: thumbUrl,
      );
    } catch (e) {
      debugPrint('YTMusic.parseMusicListItem: $e');
      return null;
    }
  }

  String? _extractVideoId(Map<String, dynamic> renderer) {
    try {
      final endpoint = renderer['overlay']?['musicItemThumbnailOverlayRenderer']
          ?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']
          ?['watchEndpoint']?['videoId'] as String?;
      if (endpoint != null) return endpoint;

      final playlistItemDataId = renderer['playlistItemData']?['videoId'] as String?;
      if (playlistItemDataId != null) return playlistItemDataId;

      final cols = renderer['flexColumns'] as List<dynamic>? ?? [];
      for (final col in cols) {
        final runs = col['musicResponsiveListItemFlexColumnRenderer']?['text']
            ?['runs'] as List<dynamic>? ?? [];
        for (final run in runs) {
          final id = run['navigationEndpoint']?['watchEndpoint']?['videoId'];
          if (id != null) return id as String;
        }
      }
    } catch (e) { debugPrint('YTMusic.extractVideoId: $e'); }
    return null;
  }

  Future<List<Song>> explodeSearch(String query) async {
    try {
      final searchList = await _yt.search.search(query);
      final songs = <Song>[];
      for (final video in searchList) {
        // Skip videos without duration or with clearly non-music length
        if (video.duration == null || video.duration == Duration.zero) continue;
        if (video.duration!.inMinutes > 20) continue;
        songs.add(Song(
          id: video.id.value,
          title: video.title,
          artist: video.author,
          duration: video.duration!,
          thumbnailUrl: video.thumbnails.mediumResUrl,
        ));
      }
      return songs;
    } catch (e) {
      debugPrint('YTMusic.explodeSearch: $e');
      return [];
    }
  }

  // ── Related / Radio ───────────────────────────────────────────────────────

  Future<List<Song>> getRelatedSongs(String videoId) async {
    try {
      final related = await _innerTubeNext(videoId);
      if (related.isNotEmpty) return related;

      final video = await _yt.videos.get(videoId);
      final relatedVideos = await _yt.videos.getRelatedVideos(video);
      if (relatedVideos == null) return [];
      return relatedVideos.take(15).where((v) {
        return v.duration == null || v.duration!.inMinutes <= 15;
      }).map((v) => Song(
            id: v.id.value,
            title: v.title,
            artist: v.author,
            duration: v.duration ?? Duration.zero,
            thumbnailUrl: v.thumbnails.mediumResUrl,
          )).toList();
    } catch (e) {
      debugPrint('YTMusic.getRelatedSongs: $e');
      return [];
    }
  }

  Future<List<Song>> _innerTubeNext(String videoId) async {
    try {
      final body = _androidMusicContext();
      body['videoId'] = videoId;
      body['isAudioOnly'] = true;

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      final response = await appHttp.post(
        Uri.parse('$_baseUrl/next?key=$_innerTubeApiKey'),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('YTMusic.innerTubeNext $videoId: HTTP ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseNextResults(data);
    } catch (e) {
      debugPrint('YTMusic.innerTubeNext: $e');
      return [];
    }
  }

  List<Song> _parseNextResults(Map<String, dynamic> data) {
    final songs = <Song>[];
    try {
      final tabs = data['contents']?['singleColumnMusicWatchNextResultsRenderer']
          ?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs'] as List?;
      if (tabs == null) return songs;

      for (final tab in tabs) {
        final items = tab['tabRenderer']?['content']?['musicQueueRenderer']
            ?['content']?['playlistPanelRenderer']?['contents'] as List? ?? [];
        for (final item in items) {
          final renderer = item['playlistPanelVideoRenderer'];
          if (renderer == null) continue;
          final videoId = renderer['videoId'] as String?;
          if (videoId == null) continue;
          final title = (renderer['title']?['runs'] as List?)?.first?['text'] as String? ?? '';
          final artist = (renderer['longBylineText']?['runs'] as List?)?.first?['text'] as String? ?? '';
          final thumbs = renderer['thumbnail']?['thumbnails'] as List?;
          final thumb = thumbs?.isNotEmpty == true ? thumbs!.last['url'] as String? ?? '' : '';
          final lengthRuns = renderer['lengthText']?['runs'] as List?;
          final durStr = lengthRuns?.isNotEmpty == true ? (lengthRuns!.first?['text'] as String? ?? '') : '';
          final duration = _parseDuration(durStr);
          if (title.isNotEmpty) {
            songs.add(Song(id: videoId, title: title, artist: artist, duration: duration, thumbnailUrl: thumb));
          }
        }
        if (songs.isNotEmpty) break;
      }
    } catch (e) { debugPrint('YTMusic.parseNextResults: $e'); }
    return songs;
  }

  // ── Playlist Import ───────────────────────────────────────────────────────

  String _cleanTrackTitle(String rawTitle) {
    return rawTitle
        .replaceAll(
          RegExp(
            r'\s*[\(\[](official\s*(music\s*)?video|video\s*ufficiale|videoclip|official\s*audio|visualizer|testo|lyric\s*video|4k|hd|hq)[\)\]]',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  Future<Playlist?> getPlaylist(String urlOrId) async {
    try {
      final id = PlaylistId.fromString(urlOrId);
      final ytPlaylist = await _yt.playlists.get(id);
      final videoStream = _yt.playlists.getVideos(id);
      final songs = <Song>[];

      await for (final video in videoStream.take(100)) {
        final dur = video.duration ?? Duration.zero;
        // Skip videos with unknown duration to avoid showing 0:00
        if (dur == Duration.zero) continue;
        songs.add(Song(
          id: video.id.value,
          title: _cleanTrackTitle(video.title),
          artist: video.author,
          duration: dur,
          thumbnailUrl: video.thumbnails.mediumResUrl,
        ));
      }

      return Playlist(
        id: ytPlaylist.id.value,
        title: ytPlaylist.title,
        description: ytPlaylist.description,
        thumbnailUrl: ytPlaylist.thumbnails.mediumResUrl,
        songs: songs,
      );
    } catch (e) {
      debugPrint('YTMusic.getPlaylist: $e');
      return null;
    }
  }

  void dispose() {
    _yt.close();
  }
}


