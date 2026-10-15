import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/song.dart';
import 'app_settings.dart';
import 'audio_handler.dart';

/// One listen: a song played for a while, when, and for how long.
@immutable
class PlayEvent {
  const PlayEvent(this.song, this.at, this.listened);

  final Song song;
  final DateTime at;
  final Duration listened;

  Map<String, Object?> toMap() => {
    's': song.toMap(),
    'at': at.millisecondsSinceEpoch,
    'ms': listened.inMilliseconds,
  };

  static PlayEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    try {
      return PlayEvent(
        Song.fromMap(Map<String, dynamic>.from(raw['s'] as Map)),
        DateTime.fromMillisecondsSinceEpoch(raw['at'] as int),
        Duration(milliseconds: raw['ms'] as int? ?? 0),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A song or an artist with how much it was played.
@immutable
class Ranked<T> {
  const Ranked(this.item, this.plays, this.time);

  final T item;
  final int plays;
  final Duration time;
}

/// The periods the statistics are shown for.
enum StatsPeriod {
  week('Ultimi 7 giorni', Duration(days: 7)),
  month('Ultimi 30 giorni', Duration(days: 30)),
  year('Quest\'anno', null),
  all('Da sempre', null);

  const StatsPeriod(this.label, this.length);

  final String label;
  final Duration? length;

  DateTime? get since {
    final now = DateTime.now();
    return switch (this) {
      StatsPeriod.year => DateTime(now.year),
      StatsPeriod.all => null,
      _ => now.subtract(length!),
    };
  }
}

/// What was listened to, song by song, with the moment and the time spent:
/// the statistics, the history day by day, the songs not heard in a while.
///
/// A song counts once it played for 30 seconds (or half of it, when it is
/// shorter). Nothing is kept while the history is paused.
class ListeningStats {
  ListeningStats._();
  static final ListeningStats instance = ListeningStats._();

  static const String _boxName = 'kreate_plays';
  static const int _maxEvents = 20000;
  static const Duration _minimum = Duration(seconds: 30);
  static const String _pendingKey = 'pending';

  Box? _box;
  final List<PlayEvent> _events = [];

  /// Bumped at every listen recorded or removed.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  // The song playing, and how long it has played so far.
  Song? _song;
  Duration _listened = Duration.zero;
  DateTime? _since;

  List<PlayEvent> get events => List.unmodifiable(_events);

  Future<void> attach(AudioPlayerHandler handler) async {
    try {
      _box = await Hive.openBox(_boxName);
    } catch (e) {
      debugPrint('ListeningStats: box non leggibile ($e)');
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox(_boxName);
    }
    final box = _box!;
    _events
      ..clear()
      ..addAll([
        for (final key in box.keys)
          if (key != _pendingKey) ?PlayEvent.fromMap(box.get(key)),
      ]);
    _events.sort((a, b) => a.at.compareTo(b.at));
    // A listen the app could not close (it was shut while playing).
    final pending = PlayEvent.fromMap(box.get(_pendingKey));
    if (pending != null) {
      await box.delete(_pendingKey);
      if (pending.listened >= _minimum) record(pending.song, pending.listened, at: pending.at);
    }

    handler.mediaItem.listen((item) {
      final song = handler.currentSong;
      if (song?.id == _song?.id) return;
      _close();
      _song = song;
      _listened = Duration.zero;
      _since = handler.playbackState.value.playing ? DateTime.now() : null;
    });
    handler.playbackState.map((state) => state.playing).distinct().listen((playing) {
      if (playing) {
        _since ??= DateTime.now();
      } else {
        _pause();
      }
    });
  }

  void _pause() {
    final since = _since;
    if (since != null) _listened += DateTime.now().difference(since);
    _since = null;
  }

  /// The song that was playing is done: kept when it played long enough.
  void _close() {
    _pause();
    final song = _song;
    if (song == null) return;
    final needed = song.duration > Duration.zero && song.duration < _minimum * 2
        ? song.duration ~/ 2
        : _minimum;
    if (_listened >= needed) record(song, _listened);
    unawaited(_box?.delete(_pendingKey));
    _song = null;
    _listened = Duration.zero;
  }

  /// Notes the song playing now, as far as it went: the app is leaving the
  /// screen and may be closed. It is counted at the next start if so.
  void checkpoint() {
    final song = _song;
    if (song == null) return;
    var listened = _listened;
    final since = _since;
    if (since != null) listened += DateTime.now().difference(since);
    unawaited(_box?.put(_pendingKey, PlayEvent(song, DateTime.now(), listened).toMap()));
  }

  void record(Song song, Duration listened, {DateTime? at}) {
    if (AppSettings.instance.pauseListenHistory.value) return;
    final event = PlayEvent(song, at ?? DateTime.now(), listened);
    _events.add(event);
    unawaited(_box?.add(event.toMap()));
    if (_events.length > _maxEvents) _trim();
    changes.value++;
  }

  void _trim() {
    final extra = _events.length - _maxEvents;
    _events.removeRange(0, extra);
    final box = _box;
    if (box == null) return;
    unawaited(box.deleteAll(box.keys.where((key) => key != _pendingKey).take(extra).toList()));
  }

  List<Map<String, Object?>> export() => [for (final event in _events) event.toMap()];

  /// Puts back the listens of a backup, in place of these.
  Future<void> restore(Object? raw) async {
    if (raw is! List) return;
    final restored = [for (final item in raw) ?PlayEvent.fromMap(item)]
      ..sort((a, b) => a.at.compareTo(b.at));
    _events
      ..clear()
      ..addAll(restored);
    final box = _box;
    if (box != null) {
      await box.clear();
      await box.addAll([for (final event in restored) event.toMap()]);
    }
    changes.value++;
  }

  /// Forgets every listen.
  Future<void> clear() async {
    _events.clear();
    await _box?.clear();
    changes.value++;
  }

  /// Forgets the listens of [songId].
  Future<void> forgetSong(String songId) async {
    _events.removeWhere((event) => event.song.id == songId);
    final box = _box;
    if (box != null) {
      final keys = [
        for (final key in box.keys)
          if (PlayEvent.fromMap(box.get(key))?.song.id == songId) key,
      ];
      await box.deleteAll(keys);
    }
    changes.value++;
  }

  // ── Questions ───────────────────────────────────────────────────────────

  Iterable<PlayEvent> since(DateTime? from) =>
      from == null ? _events : _events.where((event) => !event.at.isBefore(from));

  Duration totalTime(StatsPeriod period) =>
      since(period.since).fold(Duration.zero, (sum, event) => sum + event.listened);

  int playCount(StatsPeriod period) => since(period.since).length;

  List<Ranked<Song>> topSongs(StatsPeriod period, {int limit = 50}) {
    final plays = <String, (Song, int, Duration)>{};
    for (final event in since(period.since)) {
      final known = plays[event.song.id];
      plays[event.song.id] = (
        event.song,
        (known?.$2 ?? 0) + 1,
        (known?.$3 ?? Duration.zero) + event.listened,
      );
    }
    final ranked = [for (final entry in plays.values) Ranked(entry.$1, entry.$2, entry.$3)]
      ..sort((a, b) => b.plays != a.plays ? b.plays.compareTo(a.plays) : b.time.compareTo(a.time));
    return ranked.take(limit).toList();
  }

  /// The first artist named by a song: "A, B" and "A feat. B" count for A.
  static String mainArtist(String artist) =>
      artist.split(RegExp(r',|&| feat\.| ft\.| x ', caseSensitive: false)).first.trim();

  List<Ranked<String>> topArtists(StatsPeriod period, {int limit = 30}) {
    final plays = <String, (String, int, Duration)>{};
    for (final event in since(period.since)) {
      final name = mainArtist(event.song.artist);
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      final known = plays[key];
      plays[key] = (name, (known?.$2 ?? 0) + 1, (known?.$3 ?? Duration.zero) + event.listened);
    }
    final ranked = [for (final entry in plays.values) Ranked(entry.$1, entry.$2, entry.$3)]
      ..sort((a, b) => b.plays.compareTo(a.plays));
    return ranked.take(limit).toList();
  }

  /// Listening time by hour of the day (24 values).
  List<Duration> byHour(StatsPeriod period) {
    final hours = List<Duration>.filled(24, Duration.zero);
    for (final event in since(period.since)) {
      hours[event.at.hour] += event.listened;
    }
    return hours;
  }

  /// Days with at least a listen in the period.
  int activeDays(StatsPeriod period) => {
    for (final event in since(period.since)) DateTime(event.at.year, event.at.month, event.at.day),
  }.length;

  DateTime? lastPlayed(String songId) {
    for (var i = _events.length - 1; i >= 0; i--) {
      if (_events[i].song.id == songId) return _events[i].at;
    }
    return null;
  }

  /// Among [favorites], those not heard for [quiet] or more, the ones
  /// played most before first: liked songs worth hearing again.
  List<Song> forgotten(List<Song> favorites, {Duration quiet = const Duration(days: 30)}) {
    if (_events.isEmpty) return const [];
    final last = <String, DateTime>{};
    final count = <String, int>{};
    for (final event in _events) {
      last[event.song.id] = event.at;
      count[event.song.id] = (count[event.song.id] ?? 0) + 1;
    }
    final limit = DateTime.now().subtract(quiet);
    final found = [
      for (final song in favorites)
        if (last[song.id] != null && last[song.id]!.isBefore(limit)) song,
    ]..sort((a, b) => (count[b.id] ?? 0).compareTo(count[a.id] ?? 0));
    return found;
  }
}
