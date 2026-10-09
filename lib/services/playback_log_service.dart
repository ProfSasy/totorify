import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Ring buffer of playback events, used to diagnose issues on real devices.
///
/// Every critical step of the playback pipeline writes here: load, stream
/// resolution, play/pause, skips, completion, repeat decisions, failures.
/// The log can be exported from Settings → Diagnostica → Log riproduzione.
class PlaybackLogService {
  static final PlaybackLogService instance = PlaybackLogService._internal();
  PlaybackLogService._internal();

  static const int _maxEntries = 400;
  final Queue<String> _entries = Queue<String>();

  /// Bumped on every change so the diagnostics screen can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void log(String tag, String message) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    _entries.addLast('[$ts][$tag] $message');
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    revision.value++;
  }

  /// Oldest first.
  List<String> get entries => List.unmodifiable(_entries);

  String export() => _entries.join('\n');

  void clear() {
    _entries.clear();
    revision.value++;
  }
}
