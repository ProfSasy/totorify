part of 'ytmusic_service.dart';

extension YTMusicStreams on YTMusicService {
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
    _details.clear();
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
      _audioUrlCache[videoId] = (url, DateTime.now().add(YTMusicService._urlCacheTtl));
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
          headers: YTMusicService._visionOsHeaders,
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

    final chosen = _pickBestAppleCompatibleAudio(formats);
    final audioUrl = chosen?['url'] as String?;
    final hls = streaming?['hlsManifestUrl'] as String?;
    final audioConfig = data['playerConfig']?['audioConfig'];
    _details[videoId] = StreamDetails(
      loudnessDb: YTMusicService._loudnessOf(chosen, audioConfig),
      mimeType: chosen?['mimeType'] as String?,
      bitrate: int.tryParse('${chosen?['averageBitrate'] ?? chosen?['bitrate'] ?? ''}'),
      sampleRate: int.tryParse('${chosen?['audioSampleRate'] ?? ''}'),
      channels: int.tryParse('${chosen?['audioChannels'] ?? ''}'),
      contentLength: int.tryParse('${chosen?['contentLength'] ?? ''}'),
      itag: int.tryParse('${chosen?['itag'] ?? ''}'),
    );
    _pruneCache(_details);
    final streams = (
      audioUrl: (audioUrl == null || audioUrl.isEmpty) ? null : audioUrl,
      hlsManifestUrl: (hls == null || hls.isEmpty) ? null : hls,
      duration: millis > 0 ? Duration(milliseconds: millis) : null,
    );
    final expires = DateTime.now().add(YTMusicService._urlCacheTtl);
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

  /// What is known of the audio of [videoId], once its streams have been
  /// looked up.
  StreamDetails? streamDetails(String videoId) => _details[videoId];

  /// How loud [videoId] is (see [StreamDetails.loudnessDb]). Asks YouTube
  /// when it is not known yet; null when it does not say.
  Future<double?> loudnessOf(String videoId) async {
    final known = _details[videoId];
    if (known != null) return known.loudnessDb;
    await _visionOsStreams(videoId);
    return _details[videoId]?.loudnessDb;
  }

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
          .get(Uri.parse(manifest), headers: const {'User-Agent': YTMusicService._appleMediaUa})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('YTMusic.hlsAudio $videoId: HTTP ${response.statusCode}');
        return null;
      }
      final url = YTMusicService.pickHlsAudioRendition(
        response.body,
        Uri.parse(manifest),
        highQuality: StorageService.instance.isHighQuality && !YTMusicService.lowDataNow,
      );
      if (url == null) {
        debugPrint('YTMusic.hlsAudio $videoId: nessuna traccia solo audio nel manifest');
        return null;
      }
      _hlsAudioCache[videoId] = (url, DateTime.now().add(YTMusicService._urlCacheTtl));
      _pruneCache(_hlsAudioCache);
      return url;
    } catch (e) {
      debugPrint('YTMusic.hlsAudio $videoId: $e');
      return null;
    }
  }

  /// The audio stream to play, out of the formats YouTube offers:
  ///   - the original track only: not a dubbed language, not the
  ///     compressed-dynamics copy (DRC) some videos have;
  ///   - Opus where the player can decode it (about 130 kbps at 48 kHz, the
  ///     best YouTube gives for free), AAC otherwise (itag 140, 128 kbps);
  ///   - the highest bitrate for "Alta qualità", the lightest otherwise.
  String? _pickBestAppleCompatibleAudioUrl(List<dynamic> formats) =>
      _pickBestAppleCompatibleAudio(formats)?['url'] as String?;

  Map<String, dynamic>? _pickBestAppleCompatibleAudio(List<dynamic> formats) {
    final audioFormats = formats.where((f) {
      final mime = f['mimeType'] as String? ?? '';
      return mime.startsWith('audio/') && f['url'] != null;
    }).toList();

    if (audioFormats.isEmpty) return null;

    bool original(dynamic f) {
      if (f['isDrc'] == true || '${f['xtags'] ?? ''}'.contains('drc')) return false;
      final track = f['audioTrack'];
      return track is! Map || track['audioIsDefault'] != false;
    }

    final originals = audioFormats.where(original).toList();
    final pool = originals.isNotEmpty ? originals : audioFormats;

    bool isMp4(dynamic f) {
      final mime = (f['mimeType'] as String? ?? '').toLowerCase();
      return mime.contains('mp4') || mime.contains('m4a') || mime.contains('mp4a');
    }

    bool isOpus(dynamic f) => (f['mimeType'] as String? ?? '').toLowerCase().contains('opus');

    final opus = YTMusicService.opusPlayable ? pool.where(isOpus).toList() : const [];
    final mp4 = pool.where(isMp4).toList();
    final targetList = opus.isNotEmpty ? opus : (mp4.isNotEmpty ? mp4 : pool);

    targetList.sort((a, b) => YTMusicService._averageBitrate(b).compareTo(YTMusicService._averageBitrate(a)));

    // "Alta qualità" picks the highest bitrate; otherwise prefer the lightest
    // stream to save data on the go.
    final hq = StorageService.instance.isHighQuality && !YTMusicService.lowDataNow;
    final chosen = hq ? targetList.first : targetList.last;
    return Map<String, dynamic>.from(chosen as Map);
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
        Uri.parse('${YTMusicService._baseUrl}/player?key=${YTMusicService._innerTubeApiKey}'),
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
}
