import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/song.dart';
import 'app_settings.dart';
import 'audio_handler.dart';
import 'playback_queue.dart';

/// Keeps the queue and where it was, so that the next launch starts from
/// there (paused): what Yuma and the other players call a persistent queue.
///
/// Saved a moment after every change of the queue or of the song, every
/// few seconds while playing, at a pause and when the app goes to the
/// background.
class SessionKeeper {
  SessionKeeper._();
  static final SessionKeeper instance = SessionKeeper._();

  static const String _boxName = 'kreate_session';
  static const int _maxSongs = 500;

  Box? _box;
  AudioPlayerHandler? _handler;
  Timer? _debounce;
  Timer? _ticker;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Opens the store, puts back the last session into [handler] (when the
  /// setting is on) and keeps it up to date from then on.
  Future<void> attach(AudioPlayerHandler handler) async {
    _handler = handler;
    try {
      _box = await Hive.openBox(_boxName);
    } catch (e) {
      debugPrint('SessionKeeper: box non leggibile ($e)');
      try {
        await Hive.deleteBoxFromDisk(_boxName);
        _box = await Hive.openBox(_boxName);
      } catch (_) {
        return;
      }
    }
    if (AppSettings.instance.persistentQueue.value) _restore(handler);

    _subscriptions
      ..add(handler.queue.listen((_) => _soon()))
      ..add(handler.mediaItem.listen((_) => _soon()))
      ..add(
        handler.playbackState.map((state) => state.playing).distinct().listen((playing) {
          _ticker?.cancel();
          if (playing) {
            _ticker = Timer.periodic(const Duration(seconds: 15), (_) => save());
          } else {
            unawaited(save());
          }
        }),
      );
    AppSettings.instance.persistentQueue.addListener(_onSettingChanged);
  }

  void _onSettingChanged() {
    if (!AppSettings.instance.persistentQueue.value) unawaited(_box?.clear());
  }

  void _soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), save);
  }

  /// Writes the session now.
  Future<void> save() async {
    final handler = _handler;
    final box = _box;
    if (handler == null || box == null || !AppSettings.instance.persistentQueue.value) return;
    final snapshot = handler.queueSnapshot;
    if (snapshot.songs.isEmpty || snapshot.index < 0) {
      await box.clear();
      return;
    }
    // A very long queue is kept around the current song.
    var songs = snapshot.songs;
    var index = snapshot.index;
    if (songs.length > _maxSongs) {
      final from = (index - 50).clamp(0, songs.length - _maxSongs);
      songs = songs.sublist(from, from + _maxSongs);
      index -= from;
    }
    try {
      await box.putAll({
        'songs': [for (final song in songs) song.toMap()],
        'index': index,
        'positionMs': handler.position.inMilliseconds,
        'shuffle': snapshot.shuffle,
        'repeat': snapshot.repeat.name,
      });
    } catch (e) {
      debugPrint('SessionKeeper.save: $e');
    }
  }

  void _restore(AudioPlayerHandler handler) {
    final box = _box!;
    try {
      final raw = box.get('songs');
      if (raw is! List || raw.isEmpty) return;
      final songs = [for (final map in raw) Song.fromMap(Map<String, dynamic>.from(map as Map))];
      handler.restoreSession(
        songs,
        box.get('index') as int? ?? 0,
        position: Duration(milliseconds: box.get('positionMs') as int? ?? 0),
        shuffle: box.get('shuffle') as bool? ?? false,
        repeat: PlaybackRepeat.values.firstWhere(
          (mode) => mode.name == box.get('repeat'),
          orElse: () => PlaybackRepeat.off,
        ),
      );
    } catch (e) {
      debugPrint('SessionKeeper._restore: $e');
    }
  }

  @visibleForTesting
  Future<void> detach() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _debounce?.cancel();
    _ticker?.cancel();
    AppSettings.instance.persistentQueue.removeListener(_onSettingChanged);
    _handler = null;
  }
}
