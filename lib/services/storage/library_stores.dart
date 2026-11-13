import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';

// This device's own library, a store per box. Each keeps what its box holds
// in memory, so that the screens do not read the disk again and again;
// `StorageService` decides what goes in and out of them.

/// The songs with a heart, most recently added first.
class FavoritesStore {
  FavoritesStore(this.box);

  final Box box;

  /// The moment a favourite was added, stored with it.
  static const String favoritedAtKey = 'favoritedAt';

  final List<Song> songs = [];
  final Set<String> ids = {};

  /// A box gives its values in the order of their keys, not of their
  /// arrival: the moment each one was added is stored with it. Those saved
  /// before it was (no moment) keep the order they always had, after the
  /// others.
  void load() {
    songs.clear();
    ids.clear();
    final favorites = <(int, int, Song)>[];
    for (final raw in box.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          final song = Song.fromMap(map);
          favorites.add((map[favoritedAtKey] as int? ?? 0, favorites.length, song));
          ids.add(song.id);
        } catch (e) {
          debugPrint('StorageService._loadFavorites: $e');
        }
      }
    }
    favorites.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$2.compareTo(a.$2));
    songs.addAll(favorites.map((entry) => entry.$3));
  }
}

/// The playlists made on this device.
class PlaylistStore {
  PlaylistStore(this.box);

  final Box box;
  final List<Playlist> playlists = [];

  void load() {
    playlists.clear();
    for (final raw in box.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          playlists.add(Playlist.fromMap(map));
        } catch (e) {
          debugPrint('StorageService._loadPlaylists: $e');
        }
      }
    }
  }
}

/// What was played on this device, last first.
class HistoryStore {
  HistoryStore(this.box);

  final Box box;

  /// The key the whole history is kept under.
  static const String key = 'recent_songs';

  final List<Song> songs = [];

  void load() {
    songs.clear();
    final rawHistory = box.get(key, defaultValue: <dynamic>[]);
    final rawList = rawHistory is List ? rawHistory : const <dynamic>[];
    for (final raw in rawList) {
      try {
        final map = Map<String, dynamic>.from(raw as Map);
        songs.add(Song.fromMap(map));
      } catch (e) {
        debugPrint('StorageService._loadHistory: $e');
      }
    }
  }
}

/// The songs saved for listening offline.
class DownloadStore {
  DownloadStore(this.box);

  final Box box;
  final List<Song> songs = [];
  final Set<String> ids = {};

  void load() {
    songs.clear();
    ids.clear();
    for (final raw in box.values) {
      if (raw != null) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          final song = Song.fromMap(map);
          songs.add(song);
          ids.add(song.id);
        } catch (e) {
          debugPrint('StorageService._loadDownloads: $e');
        }
      }
    }
  }
}

/// The artists followed on this device, most recently followed first.
class ArtistStore {
  ArtistStore(this.box);

  final Box box;
  final List<Artist> artists = [];

  void load() {
    artists.clear();
    final followed = <(int, Artist)>[];
    for (final raw in box.values) {
      if (raw == null) continue;
      try {
        final map = Map<String, dynamic>.from(raw as Map);
        followed.add((map['followedAt'] as int? ?? 0, Artist.fromMap(map)));
      } catch (e) {
        debugPrint('StorageService._loadArtists: $e');
      }
    }
    followed.sort((a, b) => b.$1.compareTo(a.$1));
    artists.addAll(followed.map((entry) => entry.$2));
  }
}

/// The library of a phone, shown beside this device's own: kept apart, in
/// sections, and replaced when another phone connects. Empty on a phone.
class GuestLibraryStore {
  GuestLibraryStore(this.box);

  final Box box;

  static const String sectionFavorites = 'favorites';
  static const String sectionPlaylists = 'playlists';
  static const String sectionArtists = 'artists';
  static const String sectionHistory = 'history';

  final List<Song> favorites = [];
  final List<Playlist> playlists = [];
  final List<Song> history = [];
  final List<Artist> artists = [];

  void load() {
    List<T> read<T>(String section, T Function(Map<String, dynamic> map) make) {
      final raw = box.get(section);
      final made = <T>[];
      for (final item in raw is List ? raw : const <dynamic>[]) {
        try {
          made.add(make(Map<String, dynamic>.from(item as Map)));
        } catch (e) {
          debugPrint('StorageService._loadGuestLibrary $section: $e');
        }
      }
      return made;
    }

    favorites
      ..clear()
      ..addAll(read(sectionFavorites, Song.fromMap));
    playlists
      ..clear()
      ..addAll(read(sectionPlaylists, Playlist.fromMap));
    artists
      ..clear()
      ..addAll(read(sectionArtists, Artist.fromMap));
    history
      ..clear()
      ..addAll(read(sectionHistory, Song.fromMap));
  }

  /// Writes one section as it is in memory.
  Future<void> save(String section) async {
    final List<Map<String, dynamic>> data;
    switch (section) {
      case sectionFavorites:
        data = [for (final song in favorites) song.toMap()];
      case sectionPlaylists:
        data = [for (final playlist in playlists) playlist.toMap()];
      case sectionArtists:
        data = [for (final artist in artists) artist.toMap()];
      case sectionHistory:
        data = [for (final song in history) song.toMap()];
      default:
        return;
    }
    if (data.isEmpty && !box.containsKey(section)) return;
    await box.put(section, data);
  }
}
