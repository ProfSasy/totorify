import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// The Canvas found for a song (or the fact that it has none) survives a
/// restart, so it is not looked up again at every session.
class CanvasAnswerStore {
  CanvasAnswerStore(this.box);

  final Box box;

  static const int _maxAnswers = 1500;

  /// The stored answer for [songId], or null when there is none or it was
  /// made by other rules ([version]).
  ({String? url, DateTime savedAt})? get(String songId, int version) {
    final raw = box.get(songId);
    if (raw is! Map || raw['v'] != version || raw['at'] is! int) return null;
    final url = raw['url'];
    return (
      url: url is String && url.isNotEmpty ? url : null,
      savedAt: DateTime.fromMillisecondsSinceEpoch(raw['at'] as int),
    );
  }

  Future<void> save(String songId, String? url, int version) async {
    try {
      if (box.length >= _maxAnswers) {
        // The oldest answers go, by the moment saved with each: a box gives
        // its keys sorted, not in the order they arrived.
        int savedAt(Object? key) {
          final raw = box.get(key);
          final at = raw is Map ? raw['at'] : null;
          return at is int ? at : 0;
        }

        final byAge = [
          for (final (i, key) in box.keys.indexed) (savedAt(key), i, key),
        ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
        await box.deleteAll([for (final entry in byAge.take(_maxAnswers ~/ 5)) entry.$3]);
      }
      await box.put(songId, {
        'url': url,
        'v': version,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('StorageService.saveCanvasAnswer: $e');
    }
  }

  Future<void> remove(String songId) async => box.delete(songId);

  Future<void> clear() async => box.clear();
}
