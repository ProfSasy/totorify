part of 'canvas_service.dart';

extension CanvasOfArtist on CanvasService {
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
      final others = songArtists.where((name) => name != mainKey).take(CanvasService._maxCollaborators);
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
      final found = await _firstAlive(CanvasService._byClosestRelease(released, shared));
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
    var found = await _firstAlive(CanvasService._byClosestRelease(released, candidates));
    if (found == null) {
      ofMainArtist = false;
      found = await _firstAlive(
        CanvasService._byClosestRelease(released, fromOthers.values.toList()),
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
          .head(Uri.parse(url), headers: CanvasService._browserHeaders)
          .timeout(const Duration(seconds: 5));
      final gone = response.statusCode == 404 ||
          response.statusCode == 403 ||
          response.statusCode == 410;
      if (gone || response.statusCode == 200) {
        if (_aliveUrls.length >= CanvasService._maxTrackInfoCached) _aliveUrls.remove(_aliveUrls.keys.first);
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
    for (final candidate in ordered.take(CanvasService._maxAliveChecks)) {
      final url = await _currentUrlOf(candidate);
      if (url != null) return (canvas: candidate, url: url);
    }
    return null;
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
        if (_albumCanvasCache.length >= CanvasService._maxAlbumsCached) {
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
          .get(Uri.parse('https://open.spotify.com/track/$trackId'), headers: CanvasService._browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService._albumOf $trackId: HTTP ${response.statusCode}');
        return null;
      }
      final albumId = CanvasService._albumMeta.firstMatch(response.body)?.group(1);
      if (albumId == null) {
        debugPrint('CanvasService._albumOf $trackId: album non indicato nella pagina');
        return null;
      }
      if (_albumOfTrack.length >= CanvasService._maxTrackInfoCached) {
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
    for (final track in (entity['trackList'] as List<dynamic>? ?? const []).take(CanvasService._maxAlbumTracks)) {
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

      await Future.wait(List.generate(CanvasService._maxParallelRequests, (_) => worker()));
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
      ...song.artist.split(CanvasService._artistSeparators),
      for (final match in CanvasService._featuredInTitle.allMatches(song.title))
        ...match.group(1)!.split(CanvasService._artistSeparators),
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
          .get(Uri.parse('${CanvasService._spotifyEmbed}/$kind/$id'), headers: CanvasService._browserHeaders)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('CanvasService embed/$kind/$id: HTTP ${response.statusCode}');
        return null;
      }
      final data = CanvasService._embedData.firstMatch(response.body)?.group(1);
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
    if (_trackInfoCache.length >= CanvasService._maxTrackInfoCached) {
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
        if (_artistCanvasCache.length >= CanvasService._maxArtistsCached) {
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
      for (var page = 1; page <= CanvasService._maxArtistPages; page++) {
        final response = await appHttp
            .get(
              Uri.parse('${CanvasService._provider}/artists/${artist.slug}?page=$page'),
              headers: CanvasService._browserHeaders,
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) {
          if (page == 1) return null;
          break;
        }
        final entries = CanvasService._artistCanvasEntry.allMatches(response.body).toList();
        for (final entry in entries) {
          found.putIfAbsent(entry.group(1)!, () => entry.group(2)!);
        }
        if (entries.isEmpty || found.length >= CanvasService._maxArtistCandidates) break;
      }

      final picked = found.entries.take(CanvasService._maxArtistCandidates).toList();
      final details = List<_TrackInfo?>.filled(picked.length, null);
      var next = 0;
      Future<void> worker() async {
        while (next < picked.length) {
          final i = next++;
          details[i] = await _trackInfo(picked[i].value);
        }
      }

      await Future.wait(List.generate(CanvasService._maxParallelRequests, (_) => worker()));

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
            Uri.parse('${CanvasService._provider}/api/search?q=${Uri.encodeQueryComponent(artistName)}'),
            headers: const {...CanvasService._browserHeaders, 'Accept': 'application/json'},
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
