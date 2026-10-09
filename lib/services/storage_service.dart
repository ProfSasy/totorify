import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../models/playlist.dart';

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

  late Box _favoritesBox;
  late Box _playlistsBox;
  late Box _historyBox;
  late Box _settingsBox;
  late Box _downloadsBox;
  late Box _ytMappingBox;
  late Box _coversBox;
  late Box _artistsBox;

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
      ValueNotifier<Color>(const Color(0xFFFF2A54));

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
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

    await _forgetSourceChoicesOnce();
    _loadInitialData();
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
    // 1. Favorites
    _cachedFavorites.clear();
    _favoriteIds.clear();
    for (final raw in _favoritesBox.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          final song = Song.fromMap(map);
          _cachedFavorites.add(song);
          _favoriteIds.add(song.id);
        } catch (e) {
          debugPrint('StorageService._loadFavorites: $e');
        }
      }
    }
    final reversedFavs = _cachedFavorites.reversed.toList();
    _cachedFavorites
      ..clear()
      ..addAll(reversedFavs);

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
      await _favoritesBox.put(song.id, song.toMap());
    }
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
  }

  Future<void> deletePlaylist(String playlistId) async {
    _cachedPlaylists.removeWhere((p) => p.id == playlistId);
    playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
    await _playlistsBox.delete(playlistId);
  }

  Future<void> addSongToPlaylist(String playlistId, Song song) async {
    final idx = _cachedPlaylists.indexWhere((p) => p.id == playlistId);
    if (idx != -1) {
      final playlist = _cachedPlaylists[idx];
      if (!playlist.songs.any((s) => s.id == song.id)) {
        final updatedSongs = List<Song>.from(playlist.songs)..add(song);
        final updated = playlist.copyWith(songs: updatedSongs);
        _cachedPlaylists[idx] = updated;
        playlistsNotifier.value = List.unmodifiable(_cachedPlaylists);
        await _playlistsBox.put(playlistId, updated.toMap());
      }
    }
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

  Future<String> getLocalAudioPath(String songId) async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/downloads/$songId.m4a';
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
    _cachedDownloads.clear();
    downloadsNotifier.value = [];
    await _downloadsBox.clear();
  }

  static const int defaultAccentColor = 0xFFFF2A54;

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

  bool get hasSeenLogin => _settingsBox.get('has_seen_login', defaultValue: false) as bool;
  Future<void> setHasSeenLogin(bool value) async => _settingsBox.put('has_seen_login', value);

  bool get isCanvasEnabled =>
      _settingsBox.get('canvas_enabled', defaultValue: true) as bool? ?? true;
  Future<void> setCanvasEnabled(bool value) async =>
      _settingsBox.put('canvas_enabled', value);

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
