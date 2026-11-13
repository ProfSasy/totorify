part of 'ytmusic_service.dart';

extension YTMusicPlaylists on YTMusicService {
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
        Uri.parse('${YTMusicService._baseUrl}/next?key=${YTMusicService._innerTubeApiKey}'),
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

  /// The whole playlist, however long: YouTube hands it over a page at a
  /// time, and [onCount] hears how many songs have been read so far.
  Future<Playlist?> getPlaylist(String urlOrId, {void Function(int count)? onCount}) async {
    try {
      final id = PlaylistId.fromString(urlOrId);
      final ytPlaylist = await _yt.playlists.get(id);
      // The tracks come from YouTube Music's pages: the video list of
      // youtube_explode has come back empty since YouTube changed it (2026).
      var songs = await YTMusicCatalogService.instance.allPlaylistTracks(id.value, onCount: onCount) ??
          const <Song>[];
      if (songs.isEmpty) songs = await _videosOf(id, onCount: onCount);
      PlaybackLogService.instance.log('YT', 'playlist ${id.value}: ${songs.length} brani');

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

  /// The playlist read as YouTube videos, for when YouTube Music has no page
  /// for it.
  Future<List<Song>> _videosOf(PlaylistId id, {void Function(int count)? onCount}) async {
    final songs = <Song>[];
    try {
      await for (final video in _yt.playlists.getVideos(id)) {
        final dur = video.duration ?? Duration.zero;
        // Skip videos with unknown duration to avoid showing 0:00
        if (dur == Duration.zero) continue;
        if (songs.length % 50 == 0) onCount?.call(songs.length);
        songs.add(Song(
          id: video.id.value,
          title: _cleanTrackTitle(video.title),
          artist: video.author,
          duration: dur,
          thumbnailUrl: video.thumbnails.mediumResUrl,
        ));
      }
    } catch (e) {
      debugPrint('YTMusic._videosOf: $e');
    }
    return songs;
  }

  void dispose() {
    _yt.close();
  }
}
