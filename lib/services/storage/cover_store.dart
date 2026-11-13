import 'package:hive_flutter/hive_flutter.dart';

/// Official album covers resolved for the songs whose own artwork was a
/// YouTube video thumbnail.
class CoverStore {
  CoverStore(this.box);

  final Box box;

  String? get(String songId) {
    final raw = box.get(songId);
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  Future<void> save(String songId, String url) async {
    await box.put(songId, url);
  }
}
