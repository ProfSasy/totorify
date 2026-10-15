import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/artist.dart';
import '../models/playlist.dart';
import '../models/song.dart';

/// Something pinned to the top of the Home: a song, a playlist or an
/// artist, kept with what is needed to show it and open it.
@immutable
class Pin {
  const Pin({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.data = const {},
  });

  static const String song = 'song';
  static const String playlist = 'playlist';
  static const String artist = 'artist';

  final String kind;
  final String id;
  final String title;
  final String subtitle;
  final String? imageUrl;
  final Map<String, dynamic> data;

  factory Pin.ofSong(Song song) => Pin(
    kind: Pin.song,
    id: song.id,
    title: song.title,
    subtitle: song.artist,
    imageUrl: song.thumbnailUrl,
    data: song.toMap(),
  );

  factory Pin.ofPlaylist(Playlist playlist, String? cover) => Pin(
    kind: Pin.playlist,
    id: playlist.id,
    title: playlist.title,
    subtitle: 'Playlist',
    imageUrl: cover,
  );

  factory Pin.ofArtist(Artist artist) => Pin(
    kind: Pin.artist,
    id: artist.id,
    title: artist.name,
    subtitle: 'Artista',
    imageUrl: artist.imageUrl,
    data: artist.toMap(),
  );

  Song? get asSong => kind == Pin.song ? Song.fromMap(data) : null;
  Artist? get asArtist => kind == Pin.artist ? Artist.fromMap(data) : null;

  Map<String, dynamic> toMap() => {
    'kind': kind,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'imageUrl': imageUrl,
    'data': data,
  };

  static Pin? fromMap(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Pin(
        kind: raw['kind'] as String,
        id: raw['id'] as String,
        title: raw['title'] as String? ?? '',
        subtitle: raw['subtitle'] as String? ?? '',
        imageUrl: raw['imageUrl'] as String?,
        data: Map<String, dynamic>.from(raw['data'] as Map? ?? const {}),
      );
    } catch (_) {
      return null;
    }
  }
}

/// What the user decides about the library beyond what it contains: what
/// is pinned to the Home, the playlists hidden, the artists blocked.
class LibraryExtras {
  LibraryExtras._();
  static final LibraryExtras instance = LibraryExtras._();

  static const String boxName = 'kreate_extras';
  static const int maxPins = 12;

  Box? _box;

  final ValueNotifier<List<Pin>> pins = ValueNotifier<List<Pin>>(const []);

  /// Ids of the playlists kept out of the library and the Home.
  final ValueNotifier<Set<String>> hiddenPlaylists = ValueNotifier<Set<String>>(const {});

  /// Names of the artists whose songs are never suggested (lower case).
  final ValueNotifier<Set<String>> blockedArtists = ValueNotifier<Set<String>>(const {});

  Future<void> init() async {
    try {
      _box = await Hive.openBox(boxName);
    } catch (e) {
      debugPrint('LibraryExtras: box non leggibile ($e)');
      await Hive.deleteBoxFromDisk(boxName);
      _box = await Hive.openBox(boxName);
    }
    final box = _box!;
    pins.value = [
      for (final raw in box.get('pins', defaultValue: const []) as List) ?Pin.fromMap(raw),
    ];
    hiddenPlaylists.value = {
      ...List<String>.from(box.get('hidden', defaultValue: const []) as List),
    };
    blockedArtists.value = {
      ...List<String>.from(box.get('blocked', defaultValue: const []) as List),
    };
  }

  // ── Pins ────────────────────────────────────────────────────────────────

  bool isPinned(String kind, String id) => pins.value.any((p) => p.kind == kind && p.id == id);

  Future<bool> togglePin(Pin pin) async {
    final current = [...pins.value];
    final at = current.indexWhere((p) => p.kind == pin.kind && p.id == pin.id);
    final pinned = at == -1;
    if (pinned) {
      current.insert(0, pin);
      if (current.length > maxPins) current.removeLast();
    } else {
      current.removeAt(at);
    }
    pins.value = current;
    await _box?.put('pins', [for (final p in current) p.toMap()]);
    return pinned;
  }

  // ── Hidden playlists ────────────────────────────────────────────────────

  bool isHidden(String playlistId) => hiddenPlaylists.value.contains(playlistId);

  Future<void> setHidden(String playlistId, bool hidden) async {
    final next = {...hiddenPlaylists.value};
    hidden ? next.add(playlistId) : next.remove(playlistId);
    hiddenPlaylists.value = next;
    await _box?.put('hidden', next.toList());
  }

  // ── Blocked artists ─────────────────────────────────────────────────────

  static String _key(String artist) => artist.trim().toLowerCase();

  bool isBlocked(String artist) {
    final blocked = blockedArtists.value;
    if (blocked.isEmpty) return false;
    return artist
        .split(RegExp(r',|&| feat\.| ft\.', caseSensitive: false))
        .any((name) => blocked.contains(_key(name)));
  }

  Future<void> setBlocked(String artist, bool blocked) async {
    final next = {...blockedArtists.value};
    blocked ? next.add(_key(artist)) : next.remove(_key(artist));
    blockedArtists.value = next;
    await _box?.put('blocked', next.toList());
  }

  /// [songs] without those of blocked artists.
  List<Song> withoutBlocked(List<Song> songs) => blockedArtists.value.isEmpty
      ? songs
      : [
          for (final s in songs)
            if (!isBlocked(s.artist)) s,
        ];

  // ── Backup ──────────────────────────────────────────────────────────────

  Map<String, Object?> export() => {
    'pins': [for (final p in pins.value) p.toMap()],
    'hidden': hiddenPlaylists.value.toList(),
    'blocked': blockedArtists.value.toList(),
  };

  Future<void> restore(Map<String, Object?> data) async {
    final box = _box;
    if (box == null) return;
    if (data['pins'] is List) await box.put('pins', data['pins']);
    if (data['hidden'] is List) await box.put('hidden', data['hidden']);
    if (data['blocked'] is List) await box.put('blocked', data['blocked']);
    pins.value = [
      for (final raw in box.get('pins', defaultValue: const []) as List) ?Pin.fromMap(raw),
    ];
    hiddenPlaylists.value = {
      ...List<String>.from(box.get('hidden', defaultValue: const []) as List),
    };
    blockedArtists.value = {
      ...List<String>.from(box.get('blocked', defaultValue: const []) as List),
    };
  }
}
