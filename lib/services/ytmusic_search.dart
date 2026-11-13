part of 'ytmusic_service.dart';

extension YTMusicSearch on YTMusicService {
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
        DateTime.now().add(YTMusicService._searchCacheTtl),
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
        Uri.parse('${YTMusicService._baseUrl}/search?key=${YTMusicService._innerTubeApiKey}'),
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

  /// The YouTube video [videoId] as a song: title, channel, length, frame.
  Future<Song?> songOfVideo(String videoId) async {
    try {
      final video = await _yt.videos.get(videoId);
      final artist = video.author.replaceAll(RegExp(r'\s*-\s*Topic$|VEVO$'), '').trim();
      return Song(
        id: video.id.value,
        title: video.title,
        artist: artist,
        duration: video.duration ?? Duration.zero,
        thumbnailUrl: video.thumbnails.highResUrl,
        youtubeVideoId: video.id.value,
      );
    } catch (e) {
      debugPrint('YTMusic.songOfVideo $videoId: $e');
      return null;
    }
  }
}
