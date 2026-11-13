import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app_folder.dart';
import 'app_settings.dart';
import 'library_extras.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import 'playback_log_service.dart';
import 'storage/canvas_answer_store.dart';
import 'storage/cover_store.dart';
import 'storage/device_settings_store.dart';
import 'storage/library_ops_log.dart';
import 'storage/library_stores.dart';
import 'storage/lyrics_store.dart';
import 'storage/source_mapping_store.dart';

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
  static const String _guestBoxName = 'kreate_guest_library';

  late FavoritesStore _favorites;
  Box get _favoritesBox => _favorites.box;
  late PlaylistStore _playlists;
  Box get _playlistsBox => _playlists.box;
  late HistoryStore _history;
  Box get _historyBox => _history.box;
  late DeviceSettingsStore _settings;
  Box get _settingsBox => _settings.box;
  late DownloadStore _downloads;
  Box get _downloadsBox => _downloads.box;
  late SourceMappingStore _sources;
  Box get _ytMappingBox => _sources.box;
  late CoverStore _covers;
  Box get _coversBox => _covers.box;
  late ArtistStore _artists;
  Box get _artistsBox => _artists.box;
  late CanvasAnswerStore _canvasAnswers;
  late LyricsStore _lyrics;
  Box get _lyricsBox => _lyrics.box;
  late GuestLibraryStore _guest;
  Box get _guestBox => _guest.box;
  late LibraryOpsLog _ops;

  // The Documents folder moves when iOS reinstalls the app: paths are built
  // from it at every start and never stored.
  late String _documentsPath;
  // Songs whose Canvas video is saved next to their audio.
  final Set<String> _localCanvasIds = {};

  // What the boxes hold, kept in memory by their stores.
  List<Song> get _cachedFavorites => _favorites.songs;
  Set<String> get _favoriteIds => _favorites.ids;
  List<Playlist> get _cachedPlaylists => _playlists.playlists;
  List<Song> get _cachedHistory => _history.songs;
  List<Song> get _cachedDownloads => _downloads.songs;
  Set<String> get _downloadedIds => _downloads.ids;
  List<Artist> get _cachedArtists => _artists.artists;

  // The library of a phone, shown beside this device's own (see
  // "A PHONE'S LIBRARY BESIDE THIS DEVICE'S OWN" below). Empty on a phone.
  List<Song> get _guestFavorites => _guest.favorites;
  List<Playlist> get _guestPlaylists => _guest.playlists;
  List<Song> get _guestHistory => _guest.history;
  List<Artist> get _guestArtists => _guest.artists;

  final ValueNotifier<List<Song>> favoritesNotifier = ValueNotifier<List<Song>>([]);
  final ValueNotifier<List<Playlist>> playlistsNotifier = ValueNotifier<List<Playlist>>([]);
  final ValueNotifier<List<Song>> historyNotifier = ValueNotifier<List<Song>>([]);
  final ValueNotifier<List<Song>> downloadsNotifier = ValueNotifier<List<Song>>([]);
  final ValueNotifier<List<Artist>> followedArtistsNotifier = ValueNotifier<List<Artist>>([]);
  final ValueNotifier<Color> accentColorNotifier =
      ValueNotifier<Color>(const Color(defaultAccentColor));

  Future<void> init() async {
    final appDir = await appFolder();
    _documentsPath = appDir.path;
    await Hive.initFlutter(appDir.path);

    // A corrupted box must never prevent the app from starting: recreate it.
    _favorites = FavoritesStore(await _openBoxSafe(_favoritesBoxName));
    _playlists = PlaylistStore(await _openBoxSafe(_playlistsBoxName));
    _history = HistoryStore(await _openBoxSafe(_historyBoxName));
    _settings = DeviceSettingsStore(
      await _openBoxSafe(_settingsBoxName),
      isSearchHistoryPaused: () => AppSettings.instance.pauseSearchHistory.value,
    );
    _downloads = DownloadStore(await _openBoxSafe(_downloadsBoxName));
    _sources = SourceMappingStore(await _openBoxSafe(_ytMappingBoxName));
    _covers = CoverStore(await _openBoxSafe(_coversBoxName));
    _artists = ArtistStore(await _openBoxSafe(_artistsBoxName));
    _canvasAnswers = CanvasAnswerStore(await _openBoxSafe(_canvasBoxName));
    _lyrics = LyricsStore(
      await _openBoxSafe(_lyricsBoxName),
      isDownloaded: _downloadedIds.contains,
    );
    _guest = GuestLibraryStore(await _openBoxSafe(_guestBoxName));
    _ops = LibraryOpsLog(
      box: _settingsBox,
      ownerId: () => libraryOwner?.id,
      isReplaying: () => _replayingOps > 0,
      notifier: libraryOpsNotifier,
    );
    await AppSettings.instance.init();
    await LibraryExtras.instance.init();

    await _forgetSourceChoicesOnce();
    _removeLockScreenExperiment();
    _loadInitialData();
    await _separateGuestLibraryOnce();
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
    _favorites.load();
    _playlists.load();
    _history.load();
    _downloads.load();
    _sources.reload();
    _artists.load();
    _guest.load();
    _syncNotifiers();
  }

  void _syncNotifiers() {
    _publishFavorites();
    _publishPlaylists();
    _publishHistory();
    downloadsNotifier.value = List.unmodifiable(_cachedDownloads);
    _publishArtists();
    accentColorNotifier.value = accentColor;
  }

  // What the screens see: the library of the phone shown here, when there is
  // one, then this device's own. What is in both is shown once.
  static List<T> _both<T>(List<T> guest, List<T> own, String Function(T) id) {
    if (guest.isEmpty) return List.unmodifiable(own);
    final seen = {for (final item in guest) id(item)};
    return List.unmodifiable([...guest, ...own.where((item) => !seen.contains(id(item)))]);
  }

  void _publishFavorites() =>
      favoritesNotifier.value = _both(_guestFavorites, _cachedFavorites, (s) => s.id);
  void _publishPlaylists() =>
      playlistsNotifier.value = _both(_guestPlaylists, _cachedPlaylists, (p) => p.id);
  void _publishHistory() =>
      historyNotifier.value = _both(_guestHistory, _cachedHistory, (s) => s.id);
  void _publishArtists() =>
      followedArtistsNotifier.value = _both(_guestArtists, _cachedArtists, (a) => a.id);

  // --- FAVORITES ---
  static const String _favoritedAtKey = FavoritesStore.favoritedAtKey;

  List<Song> getFavorites() => favoritesNotifier.value;

  bool isFavorite(String songId) =>
      _favoriteIds.contains(songId) || _guestFavorites.any((s) => s.id == songId);

  Future<void> toggleFavorite(Song song) async {
    final own = _favoriteIds.contains(song.id);
    final guest = _guestFavorites.any((s) => s.id == song.id);
    // Where a phone's library is shown beside this device's own, a heart is
    // given to that phone, and goes back to it.
    final toGuest = !own && !guest && libraryOwner != null;
    if (guest) _guestFavorites.removeWhere((s) => s.id == song.id);
    if (toGuest) _guestFavorites.insert(0, song);
    if (own) {
      _favoriteIds.remove(song.id);
      _cachedFavorites.removeWhere((s) => s.id == song.id);
    } else if (!guest && !toGuest) {
      _favoriteIds.add(song.id);
      _cachedFavorites.insert(0, song);
    }
    _publishFavorites();

    if (own) {
      await _favoritesBox.delete(song.id);
    } else if (!guest && !toGuest) {
      await _favoritesBox.put(song.id, {
        ...song.toMap(),
        _favoritedAtKey: DateTime.now().millisecondsSinceEpoch,
      });
    }
    if (guest || toGuest) {
      await _saveGuest(sectionFavorites);
      _recordLibraryOp(opFavorite, song.id, {'on': toGuest, 'song': song.toMap()});
    }
  }

  // --- HISTORY ---
  static const int _maxHistory = 100;

  List<Song> getHistory() => historyNotifier.value;

  static void _played(List<Song> history, Song song) {
    history
      ..removeWhere((s) => s.id == song.id)
      ..insert(0, song);
    if (history.length > _maxHistory) history.removeRange(_maxHistory, history.length);
  }

  Future<void> addToHistory(Song song) async {
    // Paused by the user: what plays here is not remembered.
    if (_replayingOps == 0 && AppSettings.instance.pauseListenHistory.value) return;
    final guest = libraryOwner != null;
    // Played on this device: it is in its own history, and in that of the
    // phone whose library is shown here, which is told. A play that phone
    // already knows, put back after it sent its history, is only its own.
    final here = _replayingOps == 0;
    if (here) _played(_cachedHistory, song);
    if (guest) _played(_guestHistory, song);
    _publishHistory();
    if (here) {
      await _historyBox.put('recent_songs', _cachedHistory.map((s) => s.toMap()).toList());
    }
    if (guest) {
      await _saveGuest(sectionHistory);
      _recordLibraryOp(opPlayed, song.id, {'song': song.toMap()});
    }
  }

  Future<void> clearHistory() async {
    _cachedHistory.clear();
    _guestHistory.clear();
    _publishHistory();
    await _historyBox.delete('recent_songs');
    await _saveGuest(sectionHistory);
  }

  /// Takes [songId] out of the recent history (here and in the library of
  /// the phone shown here).
  Future<void> removeFromHistory(String songId) async {
    _cachedHistory.removeWhere((s) => s.id == songId);
    final guest = _guestHistory.any((s) => s.id == songId);
    _guestHistory.removeWhere((s) => s.id == songId);
    _publishHistory();
    await _historyBox.put('recent_songs', _cachedHistory.map((s) => s.toMap()).toList());
    if (guest) await _saveGuest(sectionHistory);
  }

  /// Gives the song [songId] another title and artist everywhere it is
  /// kept: favourites, playlists, history, downloads.
  Future<void> renameSong(String songId, {required String title, required String artist}) async {
    Song edit(Song song) => song.id == songId ? song.copyWith(title: title, artist: artist) : song;
    bool has(List<Song> songs) => songs.any((s) => s.id == songId);

    if (_favoriteIds.contains(songId)) {
      final index = _cachedFavorites.indexWhere((s) => s.id == songId);
      if (index != -1) {
        _cachedFavorites[index] = edit(_cachedFavorites[index]);
        final raw = _favoritesBox.get(songId);
        await _favoritesBox.put(songId, {
          ...(raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{}),
          ..._cachedFavorites[index].toMap(),
        });
      }
    }
    for (final playlist in [..._cachedPlaylists, ..._guestPlaylists]) {
      if (has(playlist.songs)) {
        await savePlaylist(playlist.copyWith(songs: [for (final s in playlist.songs) edit(s)]));
      }
    }
    if (has(_cachedHistory)) {
      for (var i = 0; i < _cachedHistory.length; i++) {
        _cachedHistory[i] = edit(_cachedHistory[i]);
      }
      await _historyBox.put('recent_songs', _cachedHistory.map((s) => s.toMap()).toList());
    }
    final download = _cachedDownloads.indexWhere((s) => s.id == songId);
    if (download != -1) {
      _cachedDownloads[download] = edit(_cachedDownloads[download]);
      final raw = _downloadsBox.get(songId);
      await _downloadsBox.put(songId, {
        ...(raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{}),
        ..._cachedDownloads[download].toMap(),
      });
      downloadsNotifier.value = List.unmodifiable(_cachedDownloads);
    }
    _publishFavorites();
    _publishHistory();
  }

  // --- BACKUP ---

  /// The settings a backup carries. Logins, the devices met on the network
  /// and what belongs to them stay on this device.
  static const List<String> _backedUpSettings = [
    'accent_color',
    'amoled_theme',
    'canvas_enabled',
    'high_quality',
    'library_grid',
    'output_volume',
    'recent_searches',
    'save_canvas_with_downloads',
  ];

  /// This device's own library (not a phone's shown beside it), as it is
  /// stored, for a backup.
  Map<String, Object?> exportLibrary() {
    List<Object?> values(Box box) => [for (final value in box.values) value];
    return {
      'favorites': values(_favoritesBox),
      'playlists': values(_playlistsBox),
      'history': _historyBox.get('recent_songs', defaultValue: const <dynamic>[]),
      'artists': values(_artistsBox),
      'settings': {
        for (final key in _backedUpSettings)
          if (_settingsBox.containsKey(key)) key: _settingsBox.get(key),
      },
      'sources': {
        for (final key in _ytMappingBox.keys) '$key': _ytMappingBox.get(key),
      },
      'lyrics': {
        for (final key in _lyricsBox.keys)
          if (_isManualLyrics(key)) '$key': _lyricsBox.get(key),
      },
    };
  }

  /// Replaces this device's own library with the one of a backup.
  Future<void> importLibrary(Map<String, Object?> data) async {
    Future<void> refill(Box box, Object? raw, String Function(Map) keyOf) async {
      if (raw is! List) return;
      await box.clear();
      for (final value in raw) {
        if (value is Map) await box.put(keyOf(value), value);
      }
    }

    await refill(_favoritesBox, data['favorites'], (m) => '${m['id']}');
    await refill(_playlistsBox, data['playlists'], (m) => '${m['id']}');
    await refill(_artistsBox, data['artists'], (m) => '${m['id']}');
    if (data['history'] is List) await _historyBox.put('recent_songs', data['history']);
    final settings = data['settings'];
    if (settings is Map) {
      for (final key in _backedUpSettings) {
        if (settings.containsKey(key)) await _settingsBox.put(key, settings[key]);
      }
    }
    final sources = data['sources'];
    if (sources is Map) {
      for (final entry in sources.entries) {
        await _ytMappingBox.put('${entry.key}', entry.value);
      }
    }
    final lyrics = data['lyrics'];
    if (lyrics is Map) {
      for (final entry in lyrics.entries) {
        await _lyricsBox.put('${entry.key}', entry.value);
      }
    }
    _loadInitialData();
  }

  // --- PLAYLISTS ---
  List<Playlist> getPlaylists() => playlistsNotifier.value;

  /// Whether the playlist is of the phone whose library is shown beside
  /// this device's own, and not one made here.
  bool isGuestPlaylist(String playlistId) => _guestPlaylists.any((p) => p.id == playlistId);

  // Where a playlist is kept: among the phone's, or among this device's.
  ({List<Playlist> list, int index, bool guest})? _placeOf(String playlistId) {
    var index = _guestPlaylists.indexWhere((p) => p.id == playlistId);
    if (index != -1) return (list: _guestPlaylists, index: index, guest: true);
    index = _cachedPlaylists.indexWhere((p) => p.id == playlistId);
    return index == -1 ? null : (list: _cachedPlaylists, index: index, guest: false);
  }

  Future<void> _storePlaylist(Playlist playlist, {required bool guest}) =>
      guest ? _saveGuest(sectionPlaylists) : _playlistsBox.put(playlist.id, playlist.toMap());

  /// Makes a playlist of this device: where a phone's library is shown too,
  /// it stays here for whoever uses the device.
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
    _publishPlaylists();
    await _playlistsBox.put(id, playlist.toMap());
    PlaybackLogService.instance.log('PLAYLIST', 'creata "$title"');
    return playlist;
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final place = _placeOf(playlist.id);
    if (place != null) {
      place.list[place.index] = playlist;
    } else {
      _cachedPlaylists.add(playlist);
    }
    final guest = place?.guest ?? false;
    _publishPlaylists();
    await _storePlaylist(playlist, guest: guest);
    PlaybackLogService.instance.log(
      'PLAYLIST',
      'salvata "${playlist.title}" (${playlist.songs.length} brani)',
    );
    if (guest) _recordPlaylistOp(playlist, withSongs: true);
  }

  /// Gives a playlist another name; its songs are not touched.
  Future<void> renamePlaylist(String playlistId, String title) async {
    final place = _placeOf(playlistId);
    if (place == null) return;
    final previous = place.list[place.index];
    final renamed = previous.copyWith(title: title);
    place.list[place.index] = renamed;
    _publishPlaylists();
    await _storePlaylist(renamed, guest: place.guest);
    PlaybackLogService.instance.log('PLAYLIST', '"${previous.title}" ora si chiama "$title"');
    if (place.guest) _recordPlaylistOp(renamed);
  }

  Future<void> deletePlaylist(String playlistId) async {
    final guest = _guestPlaylists.where((p) => p.id == playlistId).firstOrNull;
    final own = _cachedPlaylists.where((p) => p.id == playlistId).firstOrNull;
    _guestPlaylists.removeWhere((p) => p.id == playlistId);
    _cachedPlaylists.removeWhere((p) => p.id == playlistId);
    _publishPlaylists();
    if (own != null) await _playlistsBox.delete(playlistId);
    if (guest != null) await _saveGuest(sectionPlaylists);
    PlaybackLogService.instance.log(
      'PLAYLIST',
      'eliminata "${(guest ?? own)?.title ?? playlistId}"',
    );
    if (guest != null) _recordLibraryOp(opPlaylist, playlistId, {'on': false});
  }

  /// Adds [song] to a playlist. Returns false when it was already there (or
  /// the playlist no longer exists) and nothing changed.
  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    final place = _placeOf(playlistId);
    if (place == null) return false;
    final playlist = place.list[place.index];
    if (playlist.songs.any((s) => s.id == song.id)) return false;

    final updatedSongs = List<Song>.from(playlist.songs)..add(song);
    final updated = playlist.copyWith(songs: updatedSongs);
    place.list[place.index] = updated;
    _publishPlaylists();
    await _storePlaylist(updated, guest: place.guest);
    PlaybackLogService.instance.log(
      'PLAYLIST',
      '"${song.title}" aggiunto a "${playlist.title}" (${updatedSongs.length} brani)',
    );
    if (place.guest) {
      _recordLibraryOp(opPlaylistSong, '$playlistId/${song.id}', {
        'on': true,
        'playlist': playlistId,
        'song': song.toMap(),
      });
    }
    return true;
  }

  /// Batch update for playlist songs to prevent race conditions during parallel processing.
  Future<void> batchUpdateSongsInPlaylist(String playlistId, Map<String, Song> songUpdates) async {
    final place = _placeOf(playlistId);
    if (place == null) return;
    final playlist = place.list[place.index];
    final updatedSongs = playlist.songs.map((s) {
      return songUpdates[s.id] ?? s;
    }).toList();
    final updated = playlist.copyWith(songs: updatedSongs);
    place.list[place.index] = updated;
    _publishPlaylists();
    await _storePlaylist(updated, guest: place.guest);
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final place = _placeOf(playlistId);
    if (place == null) return;
    final playlist = place.list[place.index];
    final updatedSongs = List<Song>.from(playlist.songs)..removeWhere((s) => s.id == songId);
    final updated = playlist.copyWith(songs: updatedSongs);
    place.list[place.index] = updated;
    _publishPlaylists();
    await _storePlaylist(updated, guest: place.guest);
    PlaybackLogService.instance.log(
      'PLAYLIST',
      'brano $songId rimosso da "${playlist.title}" (${updatedSongs.length} brani)',
    );
    if (place.guest) {
      _recordLibraryOp(opPlaylistSong, '$playlistId/$songId', {
        'on': false,
        'playlist': playlistId,
        'song': {'id': songId},
      });
    }
  }

  // --- YOUTUBE ID MAPPING CACHE --- (see [SourceMappingStore])
  String? getCachedYouTubeMapping(String spotifyId) => _sources.getMapping(spotifyId);

  Future<void> cacheYouTubeMapping(String spotifyId, String youtubeVideoId) =>
      _sources.cacheMapping(spotifyId, youtubeVideoId);

  /// Manual start offset for songs whose source is a music video with an
  /// intro: the clip begins at this offset instead of 0.
  int? getStartOffsetMs(String songId) => _sources.getStartOffsetMs(songId);

  Future<void> cacheStartOffset(String songId, int offsetMs) =>
      _sources.cacheStartOffset(songId, offsetMs);

  /// Spotify track matched to a song from another catalog, so its Canvas
  /// is looked up without searching again.
  String? getCachedSpotifyId(String songId) => _sources.getSpotifyId(songId);

  Future<void> cacheSpotifyId(String songId, String spotifyTrackId) =>
      _sources.cacheSpotifyId(songId, spotifyTrackId);

  // --- DOWNLOADS & OFFLINE ---
  /// Images chosen by the user (a playlist's cover) are kept in the app's
  /// folder and named `local:<path>`: the folder itself moves when iOS
  /// reinstalls the app, so it is put in front only when they are shown.
  static const String localImagePrefix = 'local:';

  /// The file of a `local:` image, null for any other URL.
  String? localImagePath(String? url) {
    if (url == null || !url.startsWith(localImagePrefix)) return null;
    return '$_documentsPath/${url.substring(localImagePrefix.length)}';
  }

  /// Copies [source] into the app's folder as an image of its own and
  /// gives its `local:` name.
  Future<String> keepImage(File source, String name) async {
    final dir = Directory('$_documentsPath/images');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = '$name-${DateTime.now().millisecondsSinceEpoch}.jpg';
    await source.copy('${dir.path}/$file');
    return '${localImagePrefix}images/$file';
  }

  bool isDownloaded(String songId) => _downloadedIds.contains(songId);

  static const String _canvasSuffix = '.canvas.mp4';

  String get downloadsPath => '$_documentsPath/downloads';

  Future<String> getLocalAudioPath(String songId) async {
    // Old builds saved some songs as .flac; they keep playing offline.
    final flac = '$downloadsPath/$songId.flac';
    if (await File(flac).exists()) return flac;
    return '$downloadsPath/$songId.m4a';
  }

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
  Duration? getDownloadDuration(String songId) => _sources.getDownloadDuration(songId);

  Future<void> saveDownloadDuration(String songId, Duration duration) =>
      _sources.saveDownloadDuration(songId, duration);

  // --- CANVAS ANSWERS --- (see [CanvasAnswerStore])

  /// The stored answer for [songId], or null when there is none or it was
  /// made by other rules ([version]).
  ({String? url, DateTime savedAt})? getCanvasAnswer(String songId, int version) =>
      _canvasAnswers.get(songId, version);

  Future<void> saveCanvasAnswer(String songId, String? url, int version) =>
      _canvasAnswers.save(songId, url, version);

  Future<void> removeCanvasAnswer(String songId) => _canvasAnswers.remove(songId);

  Future<void> clearCanvasAnswers() => _canvasAnswers.clear();

  // --- LYRICS --- (see [LyricsStore])

  Map<String, dynamic>? getStoredLyrics(String songId) => _lyrics.get(songId);

  bool _isManualLyrics(Object? key) => _lyrics.isManual(key);

  /// Forgets the lyrics found by the sources; those chosen or written by
  /// the user stay.
  Future<void> clearFoundLyrics() => _lyrics.clearFound();

  /// How many songs have lyrics saved.
  int get storedLyricsCount => _lyrics.count;

  Future<void> saveLyrics(String songId, Map<String, dynamic> data) => _lyrics.save(songId, data);

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

  // --- SETTINGS OF THE DEVICE --- (see [DeviceSettingsStore])
  static const int defaultAccentColor = DeviceSettingsStore.defaultAccentColor;

  Color get accentColor => _settings.accentColor;

  Future<void> setAccentColor(Color color) async {
    await _settings.setAccentColor(color);
    accentColorNotifier.value = color;
  }

  bool get isHighQuality => _settings.isHighQuality;
  Future<void> setHighQuality(bool value) => _settings.setHighQuality(value);

  bool get isAmoledTheme => _settings.isAmoledTheme;
  Future<void> setAmoledTheme(bool value) => _settings.setAmoledTheme(value);

  /// Devices this one has handed its playback to, most recent first.
  List<Map<String, dynamic>> get connectDevices => _settings.connectDevices;
  Future<void> setConnectDevices(List<Map<String, dynamic>> devices) =>
      _settings.setConnectDevices(devices);

  /// Identity of this device for the others on the network.
  String get connectId => _settings.connectId;

  /// The name the user gave this device for the others, or null.
  String? get connectName => _settings.connectName;
  Future<void> setConnectName(String name) => _settings.setConnectName(name);

  /// Whether this device can be found and asked to play by the others.
  bool get receivesPlayback => _settings.receivesPlayback;

  /// Whether the user (or the app, at its first start) has chosen either way.
  bool get receivesPlaybackWasChosen => _settings.receivesPlaybackWasChosen;
  Future<void> setReceivesPlayback(bool value) => _settings.setReceivesPlayback(value);

  /// The devices the user allowed for good to play on this one, by id.
  Map<String, String> get connectTrusted => _settings.connectTrusted;
  Future<void> trustConnectDevice(String id, String name) =>
      _settings.trustConnectDevice(id, name);
  Future<void> clearConnectTrusted() => _settings.clearConnectTrusted();

  /// How loud the app plays for the devices that control it, from 0 to 1.
  double get outputVolume => _settings.outputVolume;
  Future<void> setOutputVolume(double value) => _settings.setOutputVolume(value);

  /// Whether the Library shows covers in a grid instead of rows.
  bool get libraryGrid => _settings.libraryGrid;
  Future<void> setLibraryGrid(bool value) => _settings.setLibraryGrid(value);

  bool get hasSeenLogin => _settings.hasSeenLogin;
  Future<void> setHasSeenLogin(bool value) => _settings.setHasSeenLogin(value);

  bool get isCanvasEnabled => _settings.isCanvasEnabled;
  Future<void> setCanvasEnabled(bool value) => _settings.setCanvasEnabled(value);

  /// Whether the Canvas video of a song is saved when the song is downloaded.
  bool get savesCanvasWithDownloads => _settings.savesCanvasWithDownloads;
  Future<void> setSavesCanvasWithDownloads(bool value) =>
      _settings.setSavesCanvasWithDownloads(value);

  String? get spDcCookie => _settings.spDcCookie;
  Future<void> setSpDcCookie(String? value) => _settings.setSpDcCookie(value);

  // --- ORIGINAL COVERS ---
  /// Official album cover resolved for a song whose own artwork was a
  /// YouTube video thumbnail.
  String? getCachedCover(String songId) => _covers.get(songId);

  Future<void> cacheCover(String songId, String url) => _covers.save(songId, url);

  bool isFollowingArtist(String artistId) =>
      _cachedArtists.any((a) => a.id == artistId) || _guestArtists.any((a) => a.id == artistId);

  /// Replaces the followed artist [oldId] with [artist], keeping its place
  /// in the list. Does nothing when [oldId] is not followed. Used when an
  /// artist followed with an older version is found in the current catalog,
  /// and to refresh the picture of one already followed.
  Future<void> replaceFollowedArtist(String oldId, Artist artist) async {
    final guestIndex = _guestArtists.indexWhere((a) => a.id == oldId);
    if (guestIndex != -1) {
      _guestArtists[guestIndex] = artist;
      _guestArtists.removeWhere((a) => a.id == artist.id && !identical(a, artist));
      _publishArtists();
      await _saveGuest(sectionArtists);
    }
    final index = _cachedArtists.indexWhere((a) => a.id == oldId);
    if (index == -1) return;
    final stored = _artistsBox.get(oldId);
    final followedAt = stored is Map ? stored['followedAt'] : null;
    _cachedArtists[index] = artist;
    _cachedArtists.removeWhere((a) => a.id == artist.id && !identical(a, artist));
    _publishArtists();
    if (oldId != artist.id) await _artistsBox.delete(oldId);
    await _artistsBox.put(artist.id, {
      ...artist.toMap(),
      'followedAt': followedAt ?? DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> toggleFollowArtist(Artist artist) async {
    final own = _cachedArtists.any((a) => a.id == artist.id);
    final guest = _guestArtists.any((a) => a.id == artist.id);
    // Like a heart: where a phone's library is shown, it is that phone's.
    final toGuest = !own && !guest && libraryOwner != null;
    if (guest) _guestArtists.removeWhere((a) => a.id == artist.id);
    // Newest first, like favourites.
    if (toGuest) _guestArtists.insert(0, artist);
    if (own) {
      _cachedArtists.removeWhere((a) => a.id == artist.id);
    } else if (!guest && !toGuest) {
      _cachedArtists.insert(0, artist);
    }
    _publishArtists();

    if (own) {
      await _artistsBox.delete(artist.id);
    } else if (!guest && !toGuest) {
      await _artistsBox.put(artist.id, {
        ...artist.toMap(),
        'followedAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
    if (guest || toGuest) {
      await _saveGuest(sectionArtists);
      _recordLibraryOp(opFollow, artist.id, {'on': toGuest, 'artist': artist.toMap()});
    }
  }

  // --- A PHONE'S LIBRARY BESIDE THIS DEVICE'S OWN ---
  // A TV has a library of its own, made on it, which stays there for
  // whoever uses it. Beside it, it shows the library of the phone that
  // connected last (see `LibrarySync`): that one is kept apart, is replaced
  // when another phone connects, and never touches the TV's own. The
  // library travels in sections, so that a change to one does not send the
  // others again.
  static const String sectionFavorites = GuestLibraryStore.sectionFavorites;
  static const String sectionPlaylists = GuestLibraryStore.sectionPlaylists;
  static const String sectionArtists = GuestLibraryStore.sectionArtists;
  static const String sectionHistory = GuestLibraryStore.sectionHistory;
  static const String sectionExtras = 'extras';
  static const List<String> librarySections = [
    sectionFavorites,
    sectionPlaylists,
    sectionArtists,
    sectionHistory,
    sectionExtras,
  ];

  /// Name and id of the phone whose library is shown here beside this
  /// device's own, or null when there is none.
  final ValueNotifier<({String id, String name})?> libraryOwnerNotifier =
      ValueNotifier<({String id, String name})?>(null);

  ({String id, String name})? get libraryOwner {
    final raw = _settingsBox.get('library_owner');
    if (raw is! Map || raw['id'] is! String) return null;
    return (id: raw['id'] as String, name: raw['name'] as String? ?? 'Telefono');
  }

  /// Which version of each section is kept here, as its owner named it.
  Map<String, String> get libraryRevisions {
    final raw = _settingsBox.get('library_revisions');
    return raw is Map
        ? {for (final entry in raw.entries) entry.key.toString(): entry.value.toString()}
        : {};
  }

  Future<void> _saveGuest(String section) => _guest.save(section);

  /// The phone's library is not shown here any more; this device's own is
  /// untouched. What was changed in it and that phone has not taken yet is
  /// kept for when it connects again.
  Future<void> forgetGuestLibrary() async {
    final owner = libraryOwner;
    if (owner == null) return;
    _guestFavorites.clear();
    _guestPlaylists.clear();
    _guestArtists.clear();
    _guestHistory.clear();
    final cleared = _guestBox.clear();
    final forgotten = _settingsBox.deleteAll(['library_owner', 'library_revisions']);
    libraryOwnerNotifier.value = null;
    _syncNotifiers();
    await cleared;
    await forgotten;
    PlaybackLogService.instance.log('LIBRARY', 'tolta la libreria di "${owner.name}"');
  }

  /// Up to this version a TV kept the phone's library in the place of its
  /// own. Once, what it has is moved where the phone's library is now kept,
  /// and the device's own starts empty.
  Future<void> _separateGuestLibraryOnce() async {
    const flag = 'guest_library_v1';
    if (_settingsBox.get(flag) == true) return;
    try {
      final owner = libraryOwner;
      if (owner != null) {
        _guestFavorites.addAll(_cachedFavorites);
        _guestPlaylists.addAll(_cachedPlaylists);
        _guestArtists.addAll(_cachedArtists);
        _guestHistory.addAll(_cachedHistory);
        for (final section in [sectionFavorites, sectionPlaylists, sectionArtists, sectionHistory]) {
          await _saveGuest(section);
        }
        _cachedFavorites.clear();
        _favoriteIds.clear();
        _cachedPlaylists.clear();
        _cachedArtists.clear();
        _cachedHistory.clear();
        await _favoritesBox.clear();
        await _playlistsBox.clear();
        await _artistsBox.clear();
        await _historyBox.delete('recent_songs');
        final waiting = _settingsBox.get('library_ops');
        if (waiting is List) await _settingsBox.put('library_ops_${owner.id}', waiting);
        await _settingsBox.delete('library_ops');
        _syncNotifiers();
        PlaybackLogService.instance.log(
          'LIBRARY',
          'la libreria di "${owner.name}" ora sta accanto a quella di questo dispositivo',
        );
      }
      await _settingsBox.put(flag, true);
    } catch (e) {
      debugPrint('StorageService._separateGuestLibraryOnce: $e');
    }
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

  /// Takes one section of the library of [owner], as it has it at
  /// [revision], to show it beside this device's own, in the place of what
  /// was shown of it (or of another phone) before. What was learnt about
  /// the songs is added to what is known here.
  Future<void> importLibrarySection(
    String section,
    dynamic data, {
    required ({String id, String name}) owner,
    required String revision,
  }) async {
    List<T> made<T>(dynamic raw, T Function(Map<String, dynamic> map) make) {
      final list = <T>[];
      for (final item in raw is List ? raw : const <dynamic>[]) {
        if (item is! Map || item['id'] == null) continue;
        try {
          list.add(make(Map<String, dynamic>.from(item)));
        } catch (e) {
          debugPrint('StorageService.importLibrarySection $section: $e');
        }
      }
      return list;
    }

    // All of this before waiting for anything: sections arrive one right
    // after the other, and each must find what the previous one recorded.
    final previous = libraryOwner;
    final writes = <Future<void>>[];
    if (previous?.id != owner.id) {
      // Another phone: nothing of the previous one's is shown any more.
      _guestFavorites.clear();
      _guestPlaylists.clear();
      _guestArtists.clear();
      _guestHistory.clear();
      writes
        ..add(_guestBox.clear())
        ..add(_settingsBox.delete('library_revisions'));
    }
    writes
      ..add(_settingsBox.put('library_owner', {'id': owner.id, 'name': owner.name}))
      ..add(_settingsBox.put('library_revisions', {...libraryRevisions, section: revision}));

    switch (section) {
      case sectionFavorites:
        _guestFavorites
          ..clear()
          ..addAll(made(data, Song.fromMap));
      case sectionPlaylists:
        _guestPlaylists
          ..clear()
          ..addAll(made(data, Playlist.fromMap));
      case sectionArtists:
        _guestArtists
          ..clear()
          ..addAll(made(data, Artist.fromMap));
      case sectionHistory:
        _guestHistory
          ..clear()
          ..addAll(made(data, Song.fromMap));
      case sectionExtras:
        // The color and the searches a phone also sends are its own: this
        // device has its settings.
        if (data is Map) {
          final mappings = data['mappings'];
          if (mappings is Map) {
            writes.add(_ytMappingBox.putAll({
              for (final entry in mappings.entries)
                if (entry.key is String && entry.value != null) entry.key: entry.value,
            }));
          }
          final covers = data['covers'];
          if (covers is Map) {
            writes.add(_coversBox.putAll({
              for (final entry in covers.entries)
                if (entry.key is String && entry.value is String) entry.key: entry.value,
            }));
          }
        }
    }
    writes.add(_saveGuest(section));
    _syncNotifiers();
    libraryOwnerNotifier.value = libraryOwner;
    await Future.wait(writes);

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

  // --- CHANGES MADE TO A PHONE'S LIBRARY ---
  // What is changed here in the library of a phone (a heart given from the
  // TV, a song taken out of one of its playlists) belongs to that library
  // only once the phone has it: each change is kept as an operation for that
  // phone, sent when it is connected and dropped when it says it applied
  // it. What is changed in this device's own library is nobody else's.
  static const String opFavorite = 'favorite';
  static const String opFollow = 'follow';
  static const String opPlayed = 'played';
  // A playlist renamed or (`on` false) removed; with its songs when it is
  // one the phone does not have.
  static const String opPlaylist = LibraryOpsLog.opPlaylist;
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

  /// Number of the last change recorded: it moves when there is one to send.
  final ValueNotifier<int> libraryOpsNotifier = ValueNotifier<int>(0);
  int _replayingOps = 0;

  /// The changes made here that the phone whose library is shown has not
  /// taken yet, oldest first (see [LibraryOpsLog]).
  List<Map<String, dynamic>> get pendingLibraryOps => _ops.pending;

  void _recordLibraryOp(String kind, String subject, Map<String, dynamic> data) =>
      _ops.record(kind, subject, data);

  void _recordPlaylistOp(Playlist playlist, {bool withSongs = false}) =>
      _ops.recordPlaylist(playlist, withSongs: withSongs);

  /// The phone applied the changes numbered up to [upTo], of the [kinds] it
  /// knows (all of them when null).
  Future<void> forgetLibraryOps(int upTo, {Set<String>? kinds}) => _ops.forget(upTo, kinds: kinds);

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
        final place = _placeOf(id);
        if (op['on'] != true) {
          if (place != null) await deletePlaylist(id);
          return;
        }
        final about = map('playlist') ?? const <String, dynamic>{};
        if (place != null) {
          // Its songs are whatever they are here: only its name follows.
          final title = about['title'] as String?;
          if (title != null && place.list[place.index].title != title) {
            await renamePlaylist(id, title);
          }
          return;
        }
        // One that is not here is made only from a change that carries its
        // songs: a new name for a playlist removed meanwhile makes nothing.
        final songs = op['songs'];
        if (_replayingOps > 0 || songs is! List) return;
        await savePlaylist(
          Playlist(
            id: id,
            title: about['title'] as String? ?? 'Playlist',
            description: about['description'] as String?,
            thumbnailUrl: about['thumbnailUrl'] as String?,
            songs: [
              for (final item in songs)
                if (item is Map && item['id'] is String)
                  Song.fromMap(Map<String, dynamic>.from(item)),
            ],
          ),
        );
      case opPlaylistSong:
        final id = op['playlist'];
        final song = map('song');
        if (id is! String || song == null || song['id'] is! String) return;
        final place = _placeOf(id);
        if (place == null) return;
        final has = place.list[place.index].songs.any((s) => s.id == song['id']);
        if (op['on'] == true) {
          if (!has) await addSongToPlaylist(id, Song.fromMap(song));
        } else if (has) {
          await removeSongFromPlaylist(id, song['id'] as String);
        }
    }
  }

  // --- RECENT SEARCHES --- (see [DeviceSettingsStore])
  List<String> getRecentSearches() => _settings.getRecentSearches();

  Future<void> addRecentSearch(String query) => _settings.addRecentSearch(query);

  Future<void> clearRecentSearches() => _settings.clearRecentSearches();
}
