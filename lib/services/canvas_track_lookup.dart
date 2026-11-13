part of 'canvas_service.dart';

extension CanvasTrackLookup on CanvasService {
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
              Uri.parse('${CanvasService._musicBrainz}/isrc/$isrc?inc=url-rels&fmt=json'),
              headers: CanvasService._musicBrainzHeaders,
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
            final match = CanvasService._spotifyTrackUrl.firstMatch(url);
            if (match != null) return (value: match.group(1), failed: false);
          }
        }
        return (value: null, failed: false);
      } catch (e) {
        debugPrint('CanvasService MusicBrainz $isrc: $e');
        return (value: null, failed: true);
      }
    });
    _musicBrainzQueue = result.then((_) => Future<void>.delayed(CanvasService._musicBrainzInterval));
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
    for (final (_, _, release) in likely.take(CanvasService._maxReleasesOpened)) {
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
          .get(Uri.parse('https://open.spotify.com/artist/$artistId'), headers: CanvasService._browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService._discography $artistId: HTTP ${response.statusCode}');
        return null;
      }
      final encoded = CanvasService._pageState.firstMatch(response.body)?.group(1)?.trim();
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
      if (_discographyCache.length >= CanvasService._maxArtistsCached) {
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
        Uri.parse('${CanvasService._spotifyApi}$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode == 429) {
        if (!_searchBlocked) {
          final asked = Duration(seconds: int.tryParse(response.headers['retry-after'] ?? '') ?? 0);
          final pause = asked < CanvasService._searchBlockMin
              ? CanvasService._searchBlockMin
              : (asked > CanvasService._searchBlockMax ? CanvasService._searchBlockMax : asked);
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
}
