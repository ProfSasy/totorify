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
        await box.deleteAll(box.keys.take(_maxAnswers ~/ 5).toList());
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
