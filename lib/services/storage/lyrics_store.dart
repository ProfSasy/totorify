import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// The lyrics found for the songs, and those the user chose or wrote.
class LyricsStore {
  LyricsStore(this.box, {required this.isDownloaded});

  final Box box;

  /// Whether a song is downloaded: its lyrics are never thrown away.
  final bool Function(Object? songId) isDownloaded;

  static const int _maxStored = 1000;

  Map<String, dynamic>? get(String songId) {
    final raw = box.get(songId);
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
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
        final evict = box.keys
            .where((key) => !isDownloaded(key) && !isManual(key))
            .take(_maxStored ~/ 5)
            .toList();
        await box.deleteAll(evict);
      }
      await box.put(songId, data);
    } catch (e) {
      debugPrint('StorageService.saveLyrics: $e');
    }
  }
}
