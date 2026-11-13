import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// What is known of where each song plays from: the YouTube video matched
/// for it, where it starts, its Spotify track and the length of its
/// downloaded file. One box, told apart by the prefix of the key.
class SourceMappingStore {
  SourceMappingStore(this.box);

  final Box box;

  // In memory, so that a match is not read from disk at every lookup.
  final Map<String, String> _mappings = {};

  /// Reads the matches again from the box (at start, and after a backup
  /// is put back).
  void reload() {
    _mappings.clear();
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is String && val.isNotEmpty) {
        _mappings[key.toString()] = val;
      }
    }
  }

  String? getMapping(String songId) {
    if (_mappings.containsKey(songId)) {
      return _mappings[songId];
    }
    try {
      final val = box.get(songId) as String?;
      if (val != null && val.isNotEmpty) {
        _mappings[songId] = val;
      }
      return val;
    } catch (_) {
      return null;
    }
  }

  Future<void> cacheMapping(String songId, String youtubeVideoId) async {
    _mappings[songId] = youtubeVideoId;
    try {
      await box.put(songId, youtubeVideoId);
    } catch (e) {
      debugPrint('StorageService.cacheYouTubeMapping: $e');
    }
  }

  /// Manual start offset for songs whose source is a music video with an
  /// intro: the clip begins at this offset instead of 0.
  int? getStartOffsetMs(String songId) {
    final value = box.get('offset_$songId');
    return value is int ? value : null;
  }

  Future<void> cacheStartOffset(String songId, int offsetMs) async {
    try {
      await box.put('offset_$songId', offsetMs);
    } catch (e) {
      debugPrint('StorageService.cacheStartOffset: $e');
    }
  }

  /// Spotify track matched to a song from another catalog, so its Canvas
  /// is looked up without searching again.
  String? getSpotifyId(String songId) {
    final value = box.get('spotify_id_$songId');
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> cacheSpotifyId(String songId, String spotifyTrackId) async {
    try {
      await box.put('spotify_id_$songId', spotifyTrackId);
    } catch (e) {
      debugPrint('StorageService.cacheSpotifyId: $e');
    }
  }

  /// Exact length of a downloaded song, measured when it was downloaded.
  Duration? getDownloadDuration(String songId) {
    final value = box.get('duration_$songId');
    return value is int && value > 0 ? Duration(milliseconds: value) : null;
  }

  Future<void> saveDownloadDuration(String songId, Duration duration) async {
    try {
      await box.put('duration_$songId', duration.inMilliseconds);
    } catch (e) {
      debugPrint('StorageService.saveDownloadDuration: $e');
    }
  }
}
