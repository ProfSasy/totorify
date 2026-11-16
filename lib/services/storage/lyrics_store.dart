import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// The lyrics found for the songs, and those the user chose or wrote.
class LyricsStore {
  LyricsStore(this.box, {required this.isDownloaded});

  final Box box;

  /// Whether a song is downloaded: its lyrics are never thrown away.
  final bool Function(Object? songId) isDownloaded;

  static const int _maxStored = 1000;

  // When the lyrics were saved, kept beside them for the eviction: a box
  // gives its keys sorted, not in the order they arrived. Lyrics saved
  // before it was (no moment) count as the oldest.
  static const String _savedAtKey = '_savedAt';

  Map<String, dynamic>? get(String songId) {
    final raw = box.get(songId);
    return raw is Map ? (Map<String, dynamic>.from(raw)..remove(_savedAtKey)) : null;
  }

  int _savedAt(Object? key) {
    final raw = box.get(key);
    final at = raw is Map ? raw[_savedAtKey] : null;
    return at is int ? at : 0;
  }

  /// True for the lyrics the user chose or wrote.
  bool isManual(Object? key) {
    final raw = box.get(key);
    return raw is Map && raw['manual'] == true;
  }

  /// Forgets the lyrics found by the sources; those chosen or written by
  /// the user stay.
  Future<void> clearFound() async {
    try {
      await box.deleteAll([
        for (final key in box.keys)
          if (!isManual(key)) key,
      ]);
    } catch (e) {
      debugPrint('StorageService.clearFoundLyrics: $e');
    }
  }

  /// How many songs have lyrics saved.
  int get count => box.length;

  Future<void> save(String songId, Map<String, dynamic> data) async {
    try {
      if (box.length >= _maxStored) {
        // The oldest go first, but never those of a downloaded song nor
        // those the user chose or wrote.
        final candidates = [
          for (final (i, key) in box.keys.indexed)
            if (!isDownloaded(key) && !isManual(key)) (_savedAt(key), i, key),
        ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
        final evict = [for (final entry in candidates.take(_maxStored ~/ 5)) entry.$3];
        await box.deleteAll(evict);
      }
      await box.put(songId, {...data, _savedAtKey: DateTime.now().millisecondsSinceEpoch});
    } catch (e) {
      debugPrint('StorageService.saveLyrics: $e');
    }
  }
}
