import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import 'playback_log_service.dart';

class StorageService {
  static final StorageService instance = StorageService._internal();
  StorageService._internal();

  static const String _favoritesBoxName = 'kreate_favorites';
  static const String _playlistsBoxName = 'kreate_playlists';
  static const String _historyBoxName = 'kreate_history';
  static const String _settingsBoxName = 'kreate_settings';
  static const String _downloadsBoxName = 'kreate_downloads';
  static const String _ytMappingBoxName = 'kreate_yt_mappings';
  static const String _coversBoxName = 'kreate_covers';
  static const String _artistsBoxName = 'kreate_artists';
  static const String _canvasBoxName = 'kreate_canvas';
  static const String _lyricsBoxName = 'kreate_lyrics';

  late Box _favoritesBox;
  late Box _playlistsBox;
  late Box _historyBox;
  late Box _settingsBox;
  late Box _downloadsBox;
  late Box _ytMappingBox;
  late Box _coversBox;
  late Box _artistsBox;
  late Box _canvasBox;
  late Box _lyricsBox;

  // The Documents folder moves when iOS reinstalls the app: paths are built
  // from it at every start and never stored.
  late String _documentsPath;
  // Songs whose Canvas video is saved next to their audio.
  final Set<String> _localCanvasIds = {};

  // In-memory caches to eliminate repeated Hive disk deserializations
  final List<Song> _cachedFavorites = [];
  final Set<String> _favoriteIds = {};

  final List<Playlist> _cachedPlaylists = [];

  final List<Song> _cachedHistory = [];

  final List<Song> _cachedDownloads = [];
  final Set<String> _downloadedIds = {};
  final Map<String, String> _cachedYtMappings = {};
  final List<Artist> _cachedArtists = [];

  final ValueNotifier<List<Song>> favoritesNotifier = ValueNotifier<List<Song>>([]);
  final ValueNotifier<List<Playlist>> playlistsNotifier = ValueNotifier<List<Playlist>>([]);
  final ValueNotifier<List<Song>> historyNotifier = ValueNotifier<List<Song>>([]);
  final ValueNotifier<List<Song>> downloadsNotifier = ValueNotifier<List<Song>>([]);
  final ValueNotifier<List<Artist>> followedArtistsNotifier = ValueNotifier<List<Artist>>([]);
  final ValueNotifier<Color> accentColorNotifier =
      ValueNotifier<Color>(const Color(defaultAccentColor));

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _documentsPath = appDir.path;
    await Hive.initFlutter(appDir.path);

    // A corrupted box must never prevent the app from starting: recreate it.
    _favoritesBox = await _openBoxSafe(_favoritesBoxName);
    _playlistsBox = await _openBoxSafe(_playlistsBoxName);
    _historyBox = await _openBoxSafe(_historyBoxName);
    _settingsBox = await _openBoxSafe(_settingsBoxName);
    _downloadsBox = await _openBoxSafe(_downloadsBoxName);
    _ytMappingBox = await _openBoxSafe(_ytMappingBoxName);
    _coversBox = await _openBoxSafe(_coversBoxName);
    _artistsBox = await _openBoxSafe(_artistsBoxName);
    _canvasBox = await _openBoxSafe(_canvasBoxName);
    _lyricsBox = await _openBoxSafe(_lyricsBoxName);

    await _forgetSourceChoicesOnce();
    _removeLockScreenExperiment();
    _loadInitialData();
    libraryOwnerNotifier.value = libraryOwner;
    _findSavedCanvases();
  }

  /// The removed "keep the lock screen player" experiment left a setting
  /// and a file of silence behind.
  void _removeLockScreenExperiment() {
    try {
      _settingsBox.delete('keep_lock_screen_player');
      final silence = File('$_documentsPath/silenzio.wav');
      if (silence.existsSync()) silence.deleteSync();
    } catch (e) {
      debugPrint('StorageService._removeLockScreenExperiment: $e');
    }
  }

  void _findSavedCanvases() {
    _localCanvasIds.clear();
    try {
      final dir = Directory(downloadsPath);
      if (!dir.existsSync()) return;
      for (final entry in dir.listSync(followLinks: false)) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && name.endsWith(_canvasSuffix)) {
          _localCanvasIds.add(name.substring(0, name.length - _canvasSuffix.length));
        }
      }
    } catch (e) {
      debugPrint('StorageService._findSavedCanvases: $e');
    }
  }

  /// One-off cleanup. While YouTube refused every video in its embedded
  /// player, the recovery logic replaced the source of the songs played with
  /// a worse upload and remembered it. Those choices, and the matches made
  /// by the old scoring, are forgotten once so every song is matched again.
  /// Start offsets and Spotify ids are kept.
  Future<void> _forgetSourceChoicesOnce() async {
    const flag = 'source_choices_reset_v1';
    if (_settingsBox.get(flag) == true) return;
    try {
      await _ytMappingBox.deleteAll([
        for (final key in _ytMappingBox.keys)
          if (key is String && !key.startsWith('offset_') && !key.startsWith('spotify_id_')) key,
      ]);

      // Saved songs can carry the replaced source with them.
      Map<String, dynamic>? withoutSource(dynamic raw) {
        if (raw is! Map || raw['youtubeVideoId'] == null) return null;
        return Map<String, dynamic>.from(raw)..['youtubeVideoId'] = null;
      }

      for (final key in _favoritesBox.keys.toList()) {
        final cleaned = withoutSource(_favoritesBox.get(key));
        if (cleaned != null) await _favoritesBox.put(key, cleaned);
      }
      final history = _historyBox.get('recent_songs');
      if (history is List) {
        await _historyBox.put('recent_songs', [
          for (final raw in history) withoutSource(raw) ?? raw,
        ]);
      }
      for (final key in _playlistsBox.keys.toList()) {
        final raw = _playlistsBox.get(key);
        if (raw is! Map || raw['songs'] is! List) continue;
        final songs = raw['songs'] as List;
        if (!songs.any((song) => withoutSource(song) != null)) continue;
        await _playlistsBox.put(
          key,
          Map<String, dynamic>.from(raw)
            ..['songs'] = [for (final song in songs) withoutSource(song) ?? song],
        );
      }
      await _settingsBox.put(flag, true);
    } catch (e) {
      debugPrint('StorageService._forgetSourceChoicesOnce: $e');
    }
  }

  Future<Box> _openBoxSafe(String name) async {
    try {
      return await Hive.openBox(name);
    } catch (e) {
      debugPrint('StorageService: box "$name" non leggibile, ricreo ($e)');
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (deleteError) {
        debugPrint('StorageService: deleteBoxFromDisk "$name": $deleteError');
      }
      return await Hive.openBox(name);
    }
  }

  void _loadInitialData() {
    // 1. Favorites, most recently added first. A box gives its values in
    // the order of their keys, not of their arrival: the moment each one
    // was added is stored with it. Those saved before it was (no moment)
    // keep the order they always had, after the others.
    _cachedFavorites.clear();
    _favoriteIds.clear();
    final favorites = <(int, int, Song)>[];
    for (final raw in _favoritesBox.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          final song = Song.fromMap(map);
          favorites.add((map[_favoritedAtKey] as int? ?? 0, favorites.length, song));
          _favoriteIds.add(song.id);
        } catch (e) {
          debugPrint('StorageService._loadFavorites: $e');
        }
      }
    }
    favorites.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$2.compareTo(a.$2));
    _cachedFavorites.addAll(favorites.map((entry) => entry.$3));

    // 2. Playlists
    _cachedPlaylists.clear();
    for (final raw in _playlistsBox.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          _cachedPlaylists.add(Playlist.fromMap(map));
        } catch (e) {
          debugPrint('StorageService._loadPlaylists: $e');
        }
      }
    }

    // 3. History
    _cachedHistory.clear();
    final rawHistory =
        _historyBox.get('recent_songs', defaultValue: <dynamic>[]);
    final rawList = rawHistory is List ? rawHistory : const <dynamic>[];
    for (final raw in rawList) {
      try {
        final map = Map<String, dynamic>.from(raw as Map);
        _cachedHistory.add(Song.fromMap(map));
      } catch (e) {
        debugPrint('StorageService._loadHistory: $e');
      }
    }

    // 4. Downloads
    _cachedDownloads.clear();
    _downloadedIds.clear();
    for (final raw in _downloadsBox.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          final song = Song.fromMap(map);
          _cachedDownloads.add(song);
          _downloadedIds.add(song.id);
        } catch (e) {
          debugPrint('StorageService._loadDownloads: $e');
        }
      }
    }

    // 5. YouTube Mappings
    _cachedYtMappings.clear();
    for (final key in _ytMappingBox.keys) {
      final val = _ytMappingBox.get(key);
      if (val is String && val.isNotEmpty) {
        _cachedYtMappings[key.toString()] = val;
      }
    }

    // 6. Followed artists (most recently followed first)
    _cachedArtists.clear();
    final followed = <(int, Artist)>[];
    for (final raw in _artistsBox.values) {
      if (raw == null) continue;
      try {
        final map = Map<String, dynamic>.from(raw as Map);
        followed.add((map['followedAt'] as int? ?? 0, Artist.fromMap(map)));
      } catch (e) {
        debugPrint('StorageService._loadArtists: $e');
      }
    }
    followed.sort((a, b) => b.$1.compareTo(a.$1));
    _cachedArtists.addAll(followed.map((entry) => entry.$2));

    _syncNotifiers();
  }

  void _syncNotifiers() {
    favoritesNotifier.value = List.unmodifiable(_cachedFavorites);
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    historyNotifier.value = List.unmodifiable(_cachedHistory);
    downloadsNotifier.value = List.unmodifiable(_cachedDownloads);
    followedArtistsNotifier.value = List.unmodifiable(_cachedArtists);
    accentColorNotifier.value = accentColor;
  }

  // --- FAVORITES ---
  static const String _favoritedAtKey = 'favoritedAt';

  List<Song> getFavorites() => List.unmodifiable(_cachedFavorites);

  bool isFavorite(String songId) => _favoriteIds.contains(songId);

  Future<void> toggleFavorite(Song song) async {
    if (_favoriteIds.contains(song.id)) {
      _favoriteIds.remove(song.id);
      _cachedFavorites.removeWhere((s) => s.id == song.id);
      favoritesNotifier.value = List.unmodifiable(_cachedFavorites);
      await _favoritesBox.delete(song.id);
    } else {
      _favoriteIds.add(song.id);
      _cachedFavorites.insert(0, song);
      favoritesNotifier.value = List.unmodifiable(_cachedFavorites);
      await _favoritesBox.put(song.id, {
        ...song.toMap(),
        _favoritedAtKey: DateTime.now().millisecondsSinceEpoch,
      });
    }
    _recordLibraryOp(opFavorite, song.id, {
      'on': _favoriteIds.contains(song.id),
      'song': song.toMap(),
    });
  }

  // --- HISTORY ---
  List<Song> getHistory() => List.unmodifiable(_cachedHistory);

  Future<void> addToHistory(Song song) async {
    _cachedHistory.removeWhere((s) => s.id == song.id);
    _cachedHistory.insert(0, song);
    if (_cachedHistory.length > 100) {
      _cachedHistory.removeRange(100, _cachedHistory.length);
    }
    historyNotifier.value = List.unmodifiable(_cachedHistory);
    await _historyBox.put('recent_songs', _cachedHistory.map((s) => s.toMap()).toList());
    _recordLibraryOp(opPlayed, song.id, {'song': song.toMap()});
  }

  Future<void> clearHistory() async {
    _cachedHistory.clear();
    historyNotifier.value = [];
    await _historyBox.delete('recent_songs');
  }

  // --- PLAYLISTS ---
  List<Playlist> getPlaylists() => List.unmodifiable(_cachedPlaylists);

  Future<Playlist> createPlaylist(String title, {String? description, String? thumbnailUrl}) async {
    final id = 'playlist_${DateTime.now().millisecondsSinceEpoch}';
    final playlist = Playlist(
      id: id,
      title: title,
      description: description,
      thumbnailUrl: thumbnailUrl,
      songs: [],
    );
    _cachedPlaylists.add(playlist);
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    await _playlistsBox.put(id, playlist.toMap());
    PlaybackLogService.instance.log('PLAYLIST', 'creata "$title"');
    _recordPlaylistOp(playlist);
    return playlist;
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final idx = _cachedPlaylists.indexWhere((p) => p.id == playlist.id);
    if (idx != -1) {
      _cachedPlaylists[idx] = playlist;
    } else {
      _cachedPlaylists.add(playlist);
    }
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    await _playlistsBox.put(playlist.id, playlist.toMap());
    PlaybackLogService.instance.log(
      'PLAYLIST',
      'salvata "${playlist.title}" (${playlist.songs.length} brani)',
    );
    _recordPlaylistOp(playlist, withSongs: true);
  }

  /// Gives a playlist another name; its songs are not touched.
  Future<void> renamePlaylist(String playlistId, String title) async {
    final idx = _cachedPlaylists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final previous = _cachedPlaylists[idx];
    final renamed = previous.copyWith(title: title);
    _cachedPlaylists[idx] = renamed;
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    await _playlistsBox.put(playlistId, renamed.toMap());
    PlaybackLogService.instance.log('PLAYLIST', '"${previous.title}" ora si chiama "$title"');
    _recordPlaylistOp(renamed);
  }

  Future<void> deletePlaylist(String playlistId) async {
    final removed = _cachedPlaylists.where((p) => p.id == playlistId).firstOrNull;
    _cachedPlaylists.removeWhere((p) => p.id == playlistId);
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    await _playlistsBox.delete(playlistId);
    PlaybackLogService.instance.log(
      'PLAYLIST',
      'eliminata "${removed?.title ?? playlistId}"',
    );
    if (removed != null) _recordLibraryOp(opPlaylist, playlistId, {'on': false});
  }

  /// Adds [song] to a playlist. Returns false when it was already there (or
  /// the playlist no longer exists) and nothing changed.
  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    final idx = _cachedPlaylists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return false;
    final playlist = _cachedPlaylists[idx];
    if (playlist.songs.any((s) => s.id == song.id)) return false;

    final updatedSongs = List<Song>.from(playlist.songs)..add(song);
    final updated = playlist.copyWith(songs: updatedSongs);
    _cachedPlaylists[idx] = updated;
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    await _playlistsBox.put(playlistId, updated.toMap());
    PlaybackLogService.instance.log(
      'PLAYLIST',
      '"${song.title}" aggiunto a "${playlist.title}" (${updatedSongs.length} brani)',
    );
    _recordLibraryOp(opPlaylistSong, '$playlistId/${song.id}', {
      'on': true,
      'playlist': playlistId,
      'song': song.toMap(),
    });
    return true;
  }

  /// Batch update for playlist songs to prevent race conditions during parallel processing.
  Future<void> batchUpdateSongsInPlaylist(String playlistId, Map<String, Song> songUpdates) async {
    final idx = _cachedPlaylists.indexWhere((p) => p.id == playlistId);
    if (idx != -1) {
      final playlist = _cachedPlaylists[idx];
      final updatedSongs = playlist.songs.map((s) {
        return songUpdates[s.id] ?? s;
      }).toList();
      final updated = playlist.copyWith(songs: updatedSongs);
      _cachedPlaylists[idx] = updated;
      playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
      await _playlistsBox.put(playlistId, updated.toMap());
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final idx = _cachedPlaylists.indexWhere((p) => p.id == playlistId);
    if (idx != -1) {
      final playlist = _cachedPlaylists[idx];
      final updatedSongs = List<Song>.from(playlist.songs)..removeWhere((s) => s.id == songId);
      final updated = playlist.copyWith(songs: updatedSongs);
      _cachedPlaylists[idx] = updated;
      playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
      await _playlistsBox.put(playlistId, updated.toMap());
      PlaybackLogService.instance.log(
        'PLAYLIST',
        'brano $songId rimosso da "${playlist.title}" (${updatedSongs.length} brani)',
      );
      _recordLibraryOp(opPlaylistSong, '$playlistId/$songId', {
        'on': false,
        'playlist': playlistId,
        'song': {'id': songId},
      });
    }
  }

  // --- YOUTUBE ID MAPPING CACHE ---
  String? getCachedYouTubeMapping(String spotifyId) {
    if (_cachedYtMappings.containsKey(spotifyId)) {
      return _cachedYtMappings[spotifyId];
    }
    try {
      final val = _ytMappingBox.get(spotifyId) as String?;
      if (val != null && val.isNotEmpty) {
        _cachedYtMappings[spotifyId] = val;
      }
      return val;
    } catch (_) {
      return null;
    }
  }

  Future<void> cacheYouTubeMapping(String spotifyId, String youtubeVideoId) async {
    _cachedYtMappings[spotifyId] = youtubeVideoId;
    try {
      await _ytMappingBox.put(spotifyId, youtubeVideoId);
    } catch (e) {
      debugPrint('StorageService.cacheYouTubeMapping: $e');
    }
  }

  /// Manual start offset for songs whose source is a music video with an
  /// intro: the clip begins at this offset instead of 0.
  int? getStartOffsetMs(String songId) {
    final value = _ytMappingBox.get('offset_$songId');
    return value is int ? value : null;
  }

  Future<void> cacheStartOffset(String songId, int offsetMs) async {
    try {
      await _ytMappingBox.put('offset_$songId', offsetMs);
    } catch (e) {
      debugPrint('StorageService.cacheStartOffset: $e');
    }
  }

  /// Spotify track matched to a song from another catalog, so its Canvas
  /// is looked up without searching again.
  String? getCachedSpotifyId(String songId) {
    final value = _ytMappingBox.get('spotify_id_$songId');
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> cacheSpotifyId(String songId, String spotifyTrackId) async {
    try {
      await _ytMappingBox.put('spotify_id_$songId', spotifyTrackId);
    } catch (e) {
      debugPrint('StorageService.cacheSpotifyId: $e');
    }
  }

  // --- DOWNLOADS & OFFLINE ---
  bool isDownloaded(String songId) => _downloadedIds.contains(songId);

  static const String _canvasSuffix = '.canvas.mp4';

  String get downloadsPath => '$_documentsPath/downloads';

  Future<String> getLocalAudioPath(String songId) async =>
      '$downloadsPath/$songId.m4a';

  /// Where the Canvas video of a downloaded song is kept.
  String localCanvasPath(String songId) => '$downloadsPath/$songId$_canvasSuffix';

  bool hasLocalCanvas(String songId) => _localCanvasIds.contains(songId);

  void setLocalCanvas(String songId, {required bool saved}) {
    if (saved) {
      _localCanvasIds.add(songId);
    } else {
      _localCanvasIds.remove(songId);
    }
  }

  List<String> get localCanvasIds => List.unmodifiable(_localCanvasIds);

  /// Exact length of a downloaded song, measured when it was downloaded.
  Duration? getDownloadDuration(String songId) {
    final value = _ytMappingBox.get('duration_$songId');
    return value is int && value > 0 ? Duration(milliseconds: value) : null;
  }

  Future<void> saveDownloadDuration(String songId, Duration duration) async {
    try {
      await _ytMappingBox.put('duration_$songId', duration.inMilliseconds);
    } catch (e) {
      debugPrint('StorageService.saveDownloadDuration: $e');
    }
  }

  // --- CANVAS ANSWERS ---
  // The Canvas found for a song (or the fact that it has none) survives a
  // restart, so it is not looked up again at every session.
  static const int _maxCanvasAnswers = 1500;

  /// The stored answer for [songId], or null when there is none or it was
  /// made by other rules ([version]).
  ({String? url, DateTime savedAt})? getCanvasAnswer(String songId, int version) {
    final raw = _canvasBox.get(songId);
    if (raw is! Map || raw['v'] != version || raw['at'] is! int) return null;
    final url = raw['url'];
    return (
      url: url is String && url.isNotEmpty ? url : null,
      savedAt: DateTime.fromMillisecondsSinceEpoch(raw['at'] as int),
    );
  }

  Future<void> saveCanvasAnswer(String songId, String? url, int version) async {
    try {
      if (_canvasBox.length >= _maxCanvasAnswers) {
        await _canvasBox.deleteAll(_canvasBox.keys.take(_maxCanvasAnswers ~/ 5).toList());
      }
      await _canvasBox.put(songId, {
        'url': url,
        'v': version,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('StorageService.saveCanvasAnswer: $e');
    }
  }

  Future<void> removeCanvasAnswer(String songId) async => _canvasBox.delete(songId);

  Future<void> clearCanvasAnswers() async => _canvasBox.clear();

  // --- LYRICS ---
  static const int _maxStoredLyrics = 1000;

  Map<String, dynamic>? getStoredLyrics(String songId) {
    final raw = _lyricsBox.get(songId);
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  Future<void> saveLyrics(String songId, Map<String, dynamic> data) async {
    try {
      if (_lyricsBox.length >= _maxStoredLyrics) {
        // The oldest go first, but never those of a downloaded song.
        final evict = _lyricsBox.keys
            .where((key) => !_downloadedIds.contains(key))
            .take(_maxStoredLyrics ~/ 5)
            .toList();
        await _lyricsBox.deleteAll(evict);
      }
      await _lyricsBox.put(songId, data);
    } catch (e) {
      debugPrint('StorageService.saveLyrics: $e');
    }
  }

  Future<bool> hasLocalAudioFile(String songId) async {
    try {
      if (!isDownloaded(songId)) return false;
      final path = await getLocalAudioPath(songId);
      final file = File(path);
      if (await file.exists()) {
        final len = await file.length();
        // Reject only clearly broken files: short tracks are legitimate.
        if (len < 8 * 1024) {
          try {
            await file.delete();
          } catch (e) {
            debugPrint('StorageService.hasLocalAudioFile delete corrupted: $e');
          }
          await removeDownloadedSong(songId);
          return false;
        }
        return true;
      } else {
        await removeDownloadedSong(songId);
        return false;
      }
    } catch (e) {
      debugPrint('StorageService.hasLocalAudioFile: $e');
    }
    return false;
  }

  Future<void> saveDownloadedSong(Song song) async {
    _downloadedIds.add(song.id);
    _cachedDownloads.removeWhere((s) => s.id == song.id);
    // Newest first keeps the "Recenti" library ordering meaningful.
    _cachedDownloads.insert(0, song);
    downloadsNotifier.value = List.unmodifiable(_cachedDownloads);
    await _downloadsBox.put(song.id, song.toMap());
  }

  Future<void> removeDownloadedSong(String songId) async {
    _downloadedIds.remove(songId);
    _cachedDownloads.removeWhere((s) => s.id == songId);
    downloadsNotifier.value = List.unmodifiable(_cachedDownloads);
    await _downloadsBox.delete(songId);
  }

  Future<void> clearAllDownloadsBox() async {
    _downloadedIds.clear();
    _localCanvasIds.clear();
    _cachedDownloads.clear();
    downloadsNotifier.value = [];
    await _downloadsBox.clear();
  }

  static const int defaultAccentColor = 0xFF1ED760;

  Color get accentColor {
    final val = _settingsBox.get('accent_color', defaultValue: defaultAccentColor);
    if (val is! int) return const Color(defaultAccentColor);
    return Color(val);
  }

  Future<void> setAccentColor(Color color) async {
    await _settingsBox.put('accent_color', color.toARGB32());
    accentColorNotifier.value = color;
  }

  bool get isHighQuality => _settingsBox.get('high_quality', defaultValue: true) as bool;
  Future<void> setHighQuality(bool value) async => _settingsBox.put('high_quality', value);

  bool get isAmoledTheme => _settingsBox.get('amoled_theme', defaultValue: false) as bool;
  Future<void> setAmoledTheme(bool value) async => _settingsBox.put('amoled_theme', value);

  /// Devices this one has handed its playback to, most recent first, as
  /// maps (see `ConnectDevice`): tried first the next time, before looking
  /// around the network.
  List<Map<String, dynamic>> get connectDevices => [
        for (final raw in _settingsBox.get('connect_devices', defaultValue: <dynamic>[]) as List)
          if (raw is Map) Map<String, dynamic>.from(raw),
      ];
  Future<void> setConnectDevices(List<Map<String, dynamic>> devices) async =>
      _settingsBox.put('connect_devices', devices);

  /// Identity and name of this device for the others on the network. The id
  /// is made once and kept.
  String get connectId {
    final known = _settingsBox.get('connect_id') as String?;
    if (known != null && known.isNotEmpty) return known;
    final id = 'totorify-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    _settingsBox.put('connect_id', id);
    return id;
  }

  /// The name the user gave this device for the others; null when none was
  /// given and the kind of device stands in ("iPhone").
  String? get connectName {
    final name = (_settingsBox.get('connect_name') as String?)?.trim() ?? '';
    return name.isEmpty ? null : name;
  }

  Future<void> setConnectName(String name) async => _settingsBox.put('connect_name', name.trim());

  /// Whether this device can be found and asked to play by the others (a
  /// phone; a TV always can). Off until the user turns it on.
  bool get receivesPlayback => _settingsBox.get('connect_receive', defaultValue: false) as bool;
  Future<void> setReceivesPlayback(bool value) async => _settingsBox.put('connect_receive', value);

  /// The devices the user allowed for good to play on this one, by id, with
  /// the name they had.
  Map<String, String> get connectTrusted {
    final raw = _settingsBox.get('connect_trusted');
    return {
      if (raw is Map)
        for (final entry in raw.entries) entry.key.toString(): entry.value.toString(),
    };
  }

  Future<void> trustConnectDevice(String id, String name) async =>
      _settingsBox.put('connect_trusted', {...connectTrusted, id: name});

  Future<void> clearConnectTrusted() async => _settingsBox.delete('connect_trusted');

  /// How loud the app plays for the devices that control it, from 0 to 1.
  double get outputVolume =>
      (_settingsBox.get('output_volume', defaultValue: 1.0) as num?)?.toDouble() ?? 1.0;
  Future<void> setOutputVolume(double value) async => _settingsBox.put('output_volume', value);

  /// Whether the Library shows covers in a grid instead of rows.
  bool get libraryGrid => _settingsBox.get('library_grid', defaultValue: false) as bool? ?? false;
  Future<void> setLibraryGrid(bool value) async => _settingsBox.put('library_grid', value);

  bool get hasSeenLogin => _settingsBox.get('has_seen_login', defaultValue: false) as bool;
  Future<void> setHasSeenLogin(bool value) async => _settingsBox.put('has_seen_login', value);

  bool get isCanvasEnabled =>
      _settingsBox.get('canvas_enabled', defaultValue: true) as bool? ?? true;
  Future<void> setCanvasEnabled(bool value) async =>
      _settingsBox.put('canvas_enabled', value);

  /// Whether the Canvas video of a song is saved when the song is downloaded.
  bool get savesCanvasWithDownloads =>
      _settingsBox.get('save_canvas_with_downloads', defaultValue: true) as bool? ?? true;
  Future<void> setSavesCanvasWithDownloads(bool value) async =>
      _settingsBox.put('save_canvas_with_downloads', value);

  String? get spDcCookie => _settingsBox.get('sp_dc_cookie') as String?;
  Future<void> setSpDcCookie(String? value) async { if (value == null || value.isEmpty) { await _settingsBox.delete('sp_dc_cookie'); } else { await _settingsBox.put('sp_dc_cookie', value); } }

  // --- ORIGINAL COVERS ---
  /// Official album cover resolved for a song whose own artwork was a
  /// YouTube video thumbnail.
  String? getCachedCover(String songId) {
    final raw = _coversBox.get(songId);
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  Future<void> cacheCover(String songId, String url) async {
    await _coversBox.put(songId, url);
  }

  bool isFollowingArtist(String artistId) =>
      _cachedArtists.any((a) => a.id == artistId);

  /// Replaces the followed artist [oldId] with [artist], keeping its place
  /// in the list. Does nothing when [oldId] is not followed. Used when an
  /// artist followed with an older version is found in the current catalog,
  /// and to refresh the picture of one already followed.
  Future<void> replaceFollowedArtist(String oldId, Artist artist) async {
    final index = _cachedArtists.indexWhere((a) => a.id == oldId);
    if (index == -1) return;
    final stored = _artistsBox.get(oldId);
    final followedAt = stored is Map ? stored['followedAt'] : null;
    _cachedArtists[index] = artist;
    _cachedArtists.removeWhere((a) => a.id == artist.id && !identical(a, artist));
    followedArtistsNotifier.value = List.unmodifiable(_cachedArtists);
    if (oldId != artist.id) await _artistsBox.delete(oldId);
    await _artistsBox.put(artist.id, {
      ...artist.toMap(),
      'followedAt': followedAt ?? DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> toggleFollowArtist(Artist artist) async {
    if (isFollowingArtist(artist.id)) {
      _cachedArtists.removeWhere((a) => a.id == artist.id);
      followedArtistsNotifier.value = List.unmodifiable(_cachedArtists);
      await _artistsBox.delete(artist.id);
    } else {
      // Newest first, like favourites.
      _cachedArtists.insert(0, artist);
      followedArtistsNotifier.value = List.unmodifiable(_cachedArtists);
      await _artistsBox.put(artist.id, {
        ...artist.toMap(),
        'followedAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
    _recordLibraryOp(opFollow, artist.id, {
      'on': isFollowingArtist(artist.id),
      'artist': artist.toMap(),
    });
  }

  // --- LIBRARY COPY ---
  // A TV keeps a copy of the library of the phone it belongs to (see
  // `LibrarySync`). The library travels in sections, so that a change to
  // one does not send the others again.
  static const String sectionFavorites = 'favorites';
  static const String sectionPlaylists = 'playlists';
  static const String sectionArtists = 'artists';
  static const String sectionHistory = 'history';
  static const String sectionExtras = 'extras';
  static const List<String> librarySections = [
    sectionFavorites,
    sectionPlaylists,
    sectionArtists,
    sectionHistory,
    sectionExtras,
  ];

  /// Name and id of the device whose library is copied here, or null when
  /// the library is this device's own.
  final ValueNotifier<({String id, String name})?> libraryOwnerNotifier =
      ValueNotifier<({String id, String name})?>(null);

  ({String id, String name})? get libraryOwner {
    final raw = _settingsBox.get('library_owner');
    if (raw is! Map || raw['id'] is! String) return null;
    return (id: raw['id'] as String, name: raw['name'] as String? ?? 'Telefono');
  }

  /// Whether something was put in the library on this device: a library
  /// that is nobody's copy and has this is not replaced by another device's
  /// unless its user asks.
  bool get hasOwnLibrary =>
      _cachedFavorites.isNotEmpty || _cachedPlaylists.isNotEmpty || _cachedArtists.isNotEmpty;

  /// The library kept here stops being a copy of another device's: what is
  /// in it stays, as this device's own, and what was waiting to be sent to
  /// its owner is not sent.
  Future<void> keepLibraryAsOwn() async {
    final owner = libraryOwner;
    if (owner == null) return;
    await _settingsBox.deleteAll(['library_owner', 'library_revisions', 'library_ops']);
    libraryOwnerNotifier.value = null;
    PlaybackLogService.instance.log('LIBRARY', 'non è più la copia di quella di "${owner.name}"');
  }

  /// Which version of each section is copied here, as its owner named it.
  Map<String, String> get libraryRevisions {
    final raw = _settingsBox.get('library_revisions');
    return raw is Map
        ? {for (final entry in raw.entries) entry.key.toString(): entry.value.toString()}
        : {};
  }

  /// One section of this device's library, as plain data.
  Object exportLibrarySection(String section) {
    switch (section) {
      case sectionFavorites:
        return [for (final song in _cachedFavorites) song.toMap()];
      case sectionPlaylists:
        return [for (final playlist in _cachedPlaylists) playlist.toMap()];
      case sectionArtists:
        return [
          for (final artist in _cachedArtists)
            {
              ...artist.toMap(),
              'followedAt': switch (_artistsBox.get(artist.id)) {
                {'followedAt': final int at} => at,
                _ => 0,
              },
            },
        ];
      case sectionHistory:
        return [for (final song in _cachedHistory) song.toMap()];
      case sectionExtras:
        return {
          // What was learnt about the songs: the video matched to each, the
          // offset it starts at, its Spotify id. Not what only makes sense
          // here (the measured length of a downloaded file).
          'mappings': {
            for (final key in _ytMappingBox.keys)
              if (key is String && !key.startsWith('duration_')) key: _ytMappingBox.get(key),
          },
          'covers': {
            for (final key in _coversBox.keys)
              if (key is String) key: _coversBox.get(key),
          },
          'accent': accentColor.toARGB32(),
          'recentSearches': getRecentSearches(),
        };
    }
    return const <dynamic>[];
  }

  /// Replaces one section of the library kept here with [data], the section
  /// as [owner] has it at [revision]. What was learnt about the songs is
  /// added to what is known here, not replaced.
  Future<void> importLibrarySection(
    String section,
    dynamic data, {
    required ({String id, String name}) owner,
    required String revision,
  }) async {
    Iterable<Map<String, dynamic>> maps(dynamic raw) => [
          for (final item in raw is List ? raw : const <dynamic>[])
            if (item is Map) Map<String, dynamic>.from(item),
        ];

    switch (section) {
      case sectionFavorites:
        final songs = maps(data).toList();
        await _favoritesBox.clear();
        // The first of the list is the most recent one.
        final now = DateTime.now().millisecondsSinceEpoch;
        await _favoritesBox.putAll({
          for (var i = 0; i < songs.length; i++)
            if (songs[i]['id'] is String) songs[i]['id']: {...songs[i], _favoritedAtKey: now - i},
        });
      case sectionPlaylists:
        await _playlistsBox.clear();
        await _playlistsBox.putAll({
          for (final playlist in maps(data))
            if (playlist['id'] is String) playlist['id']: playlist,
        });
      case sectionArtists:
        await _artistsBox.clear();
        await _artistsBox.putAll({
          for (final artist in maps(data))
            if (artist['id'] != null) artist['id'].toString(): artist,
        });
      case sectionHistory:
        await _historyBox.put('recent_songs', maps(data).toList());
      case sectionExtras:
        if (data is! Map) return;
        final mappings = data['mappings'];
        if (mappings is Map) {
          await _ytMappingBox.putAll({
            for (final entry in mappings.entries)
              if (entry.key is String && entry.value != null) entry.key: entry.value,
          });
        }
        final covers = data['covers'];
        if (covers is Map) {
          await _coversBox.putAll({
            for (final entry in covers.entries)
              if (entry.key is String && entry.value is String) entry.key: entry.value,
          });
        }
        if (data['accent'] is int) await _settingsBox.put('accent_color', data['accent']);
        if (data['recentSearches'] is List) {
          await _settingsBox.put(
            'recent_searches',
            (data['recentSearches'] as List).whereType<String>().toList(),
          );
        }
      default:
        return;
    }

    // Both written before waiting for either: sections arrive one right
    // after the other, and each must see what the previous one recorded.
    final previous = libraryOwner;
    final ownerSaved = _settingsBox.put('library_owner', {'id': owner.id, 'name': owner.name});
    final revisionsSaved = _settingsBox.put('library_revisions', {
      // Another owner: nothing of what the previous one sent is current.
      if (previous?.id == owner.id) ...libraryRevisions,
      section: revision,
    });
    // Nor are the changes made here to the previous owner's library.
    if (previous != null && previous.id != owner.id) unawaited(_settingsBox.delete('library_ops'));
    await ownerSaved;
    await revisionsSaved;
    _loadInitialData();
    libraryOwnerNotifier.value = libraryOwner;

    // What was changed here and the owner has not taken yet is put back on
    // top of what it sent.
    _replayingOps++;
    try {
      for (final op in pendingLibraryOps) {
        if (_sectionOfOp[op['op']] == section) await applyLibraryOp(op);
      }
    } finally {
      _replayingOps--;
    }
  }

  // --- CHANGES MADE ON A COPY ---
  // What is changed on a device that keeps another one's library (a heart
  // given from the TV) belongs to the library only once its owner has it:
  // each change is kept as an operation, sent to the owner when it is
  // connected and dropped when the owner says it applied it.
  static const String opFavorite = 'favorite';
  static const String opFollow = 'follow';
  static const String opPlayed = 'played';
  // A playlist made, renamed or (`on` false) removed; with its songs when it
  // was saved whole (an album kept as a playlist).
  static const String opPlaylist = 'playlist';
  // A song put in a playlist or taken out of it.
  static const String opPlaylistSong = 'playlistSong';
  static const Map<String, String> _sectionOfOp = {
    opFavorite: sectionFavorites,
    opFollow: sectionArtists,
    opPlayed: sectionHistory,
    opPlaylist: sectionPlaylists,
    opPlaylistSong: sectionPlaylists,
  };

  /// The changes this version can make for another device. A device says
  /// which ones it knows, and is sent only those.
  static List<String> get libraryOpKinds => _sectionOfOp.keys.toList(growable: false);

  /// What every version that takes changes knows, said or not.
  static const Set<String> firstLibraryOpKinds = {opFavorite, opFollow, opPlayed};
  static const int _maxLibraryOps = 300;

  /// Number of the last change recorded: it moves when there is one to send.
  final ValueNotifier<int> libraryOpsNotifier = ValueNotifier<int>(0);
  int _replayingOps = 0;

  /// The changes made here that the owner of the library has not taken yet,
  /// oldest first.
  List<Map<String, dynamic>> get pendingLibraryOps {
    final raw = _settingsBox.get('library_ops');
    return [
      for (final item in raw is List ? raw : const <dynamic>[])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /// Keeps a change to [subject] (a song, an artist) for the owner of the
  /// library. Nothing is kept where the library is this device's own. A
  /// later change of the same kind to the same subject replaces the earlier.
  void _recordLibraryOp(String kind, String subject, Map<String, dynamic> data) {
    if (_replayingOps > 0 || libraryOwner == null) return;
    final ops = pendingLibraryOps
      ..removeWhere((op) => op['op'] == kind && op['subject'] == subject);
    final n = _nextLibraryOpNumber();
    ops.add({'n': n, 'op': kind, 'subject': subject, ...data});
    if (ops.length > _maxLibraryOps) ops.removeRange(0, ops.length - _maxLibraryOps);
    unawaited(_settingsBox.put('library_ops', ops));
    libraryOpsNotifier.value = n;
  }

  int _nextLibraryOpNumber() {
    final n = (_settingsBox.get('library_op_count') as int? ?? 0) + 1;
    unawaited(_settingsBox.put('library_op_count', n));
    return n;
  }

  /// A playlist was made or renamed here. With [withSongs] the change
  /// carries its songs, for an owner that does not have the playlist.
  void _recordPlaylistOp(Playlist playlist, {bool withSongs = false}) {
    if (_replayingOps > 0 || libraryOwner == null) return;
    final ops = pendingLibraryOps;
    final at = ops.indexWhere(
      (op) => op['op'] == opPlaylist && op['subject'] == playlist.id && op['on'] == true,
    );
    final data = <String, dynamic>{
      'on': true,
      'playlist': {
        'title': playlist.title,
        'description': playlist.description,
        'thumbnailUrl': playlist.thumbnailUrl,
      },
      if (withSongs)
        'songs': [for (final song in playlist.songs) song.toMap()]
      // The change the owner has not taken yet may be the one with the songs.
      else if (at != -1 && ops[at]['songs'] != null)
        'songs': ops[at]['songs'],
    };
    if (at == -1) {
      _recordLibraryOp(opPlaylist, playlist.id, data);
      return;
    }
    // Its making is still waiting for the owner, and the songs put in it
    // since come after that: the change stays where the making was, or the
    // owner would be given songs for a playlist it does not have yet. It
    // takes a new number, so that an owner that already had the old one
    // does not make this one forgotten with it.
    final n = _nextLibraryOpNumber();
    ops[at] = {'n': n, 'op': opPlaylist, 'subject': playlist.id, ...data};
    unawaited(_settingsBox.put('library_ops', ops));
    libraryOpsNotifier.value = n;
  }

  /// The owner applied the changes numbered up to [upTo], of the [kinds] it
  /// knows (all of them when null).
  Future<void> forgetLibraryOps(int upTo, {Set<String>? kinds}) async {
    final ops = pendingLibraryOps
      ..removeWhere(
        (op) => (op['n'] as int? ?? 0) <= upTo && (kinds == null || kinds.contains(op['op'])),
      );
    await _settingsBox.put('library_ops', ops);
  }

  /// Makes a change another device recorded ([pendingLibraryOps] there).
  /// Applying one twice changes nothing.
  Future<void> applyLibraryOp(Map<String, dynamic> op) async {
    Map<String, dynamic>? map(String key) =>
        op[key] is Map ? Map<String, dynamic>.from(op[key] as Map) : null;

    switch (op['op']) {
      case opFavorite:
        final song = map('song');
        if (song == null || song['id'] is! String) return;
        if (isFavorite(song['id'] as String) != (op['on'] == true)) {
          await toggleFavorite(Song.fromMap(song));
        }
      case opFollow:
        final artist = map('artist');
        if (artist == null || artist['id'] == null) return;
        if (isFollowingArtist(artist['id'].toString()) != (op['on'] == true)) {
          await toggleFollowArtist(Artist.fromMap(artist));
        }
      case opPlayed:
        final song = map('song');
        if (song == null || song['id'] is! String) return;
        await addToHistory(Song.fromMap(song));
      case opPlaylist:
        final id = op['subject'];
        if (id is! String || id.isEmpty) return;
        final existing = _cachedPlaylists.where((p) => p.id == id).firstOrNull;
        if (op['on'] != true) {
          if (existing != null) await deletePlaylist(id);
          return;
        }
        final about = map('playlist') ?? const <String, dynamic>{};
        final title = about['title'] as String? ?? existing?.title ?? 'Playlist';
        if (existing != null) {
          // Its songs are whatever they are here: only its name follows.
          if (existing.title != title) await renamePlaylist(id, title);
          return;
        }
        final songs = op['songs'];
        await savePlaylist(
          Playlist(
            id: id,
            title: title,
            description: about['description'] as String?,
            thumbnailUrl: about['thumbnailUrl'] as String?,
            songs: [
              for (final item in songs is List ? songs : const <dynamic>[])
                if (item is Map && item['id'] is String)
                  Song.fromMap(Map<String, dynamic>.from(item)),
            ],
          ),
        );
      case opPlaylistSong:
        final id = op['playlist'];
        final song = map('song');
        if (id is! String || song == null || song['id'] is! String) return;
        if (op['on'] == true) {
          await addSongToPlaylist(id, Song.fromMap(song));
        } else if (_cachedPlaylists.any(
          (p) => p.id == id && p.songs.any((s) => s.id == song['id']),
        )) {
          await removeSongFromPlaylist(id, song['id'] as String);
        }
    }
  }

  // --- RECENT SEARCHES ---
  static const int _maxRecentSearches = 10;

  List<String> getRecentSearches() {
    final raw = _settingsBox.get('recent_searches', defaultValue: <dynamic>[]);
    if (raw is! List) return const [];
    return raw.whereType<String>().toList(growable: false);
  }

  Future<void> addRecentSearch(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    final searches = getRecentSearches().toList()
      ..removeWhere((q) => q.toLowerCase() == clean.toLowerCase())
      ..insert(0, clean);
    if (searches.length > _maxRecentSearches) {
      searches.removeRange(_maxRecentSearches, searches.length);
    }
    await _settingsBox.put('recent_searches', searches);
  }

  Future<void> clearRecentSearches() async {
    await _settingsBox.delete('recent_searches');
  }
}
