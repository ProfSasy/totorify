import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_http.dart';
import 'playback_log_service.dart';

/// Canvas videos of the songs played lately, kept as files.
///
/// A Canvas streamed from Spotify's servers takes a moment to start, every
/// time. A song that is played again finds its video here and shows it at
/// once, also without a connection. The files live in the system's cache
/// folder (iOS can reclaim it) and the oldest ones make room for the new.
class CanvasFileCache {
  CanvasFileCache._();
  static final CanvasFileCache instance = CanvasFileCache._();

  static const int _maxFiles = 60;
  static const int _maxTotalBytes = 80 * 1024 * 1024;
  static const int _maxFileBytes = 8 * 1024 * 1024;
  static const int _minFileBytes = 20 * 1024;

  Directory? _dir;
  // File name → size, in the order they were last used (oldest first).
  final Map<String, int> _files = {};
  Future<void> _queue = Future.value();

  /// Reads what is already on disk. Until it has run nothing is found.
  Future<void> init() async {
    try {
      final dir = Directory('${(await getApplicationCacheDirectory()).path}/canvas');
      if (!await dir.exists()) await dir.create(recursive: true);
      final entries = <(String, int, DateTime)>[];
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.endsWith('.mp4')) {
          // A download that was interrupted.
          unawaited(_delete(entry));
          continue;
        }
        final stat = await entry.stat();
        entries.add((name, stat.size, stat.modified));
      }
      entries.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (name, size, _) in entries) {
        _files[name] = size;
      }
      _dir = dir;
    } catch (e) {
      debugPrint('CanvasFileCache.init: $e');
    }
  }

  static String _nameOf(String url) => '${md5.convert(utf8.encode(url))}.mp4';

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone.
    }
  }

  /// The file kept for the Canvas at [url], as a file URL, or null.
  String? fileUrlFor(String url) {
    final dir = _dir;
    if (dir == null) return null;
    final name = _nameOf(url);
    final size = _files.remove(name);
    if (size == null) return null;
    // Used now: last in line to be removed.
    _files[name] = size;
    return Uri.file('${dir.path}/$name').toString();
  }

  /// Saves the Canvas at [url] for the next time. One at a time, so that it
  /// never takes much of the connection the music is using.
  Future<void> keep(String url) {
    return _queue = _queue.then((_) => _download(url)).catchError((Object e) {
      debugPrint('CanvasFileCache.keep: $e');
    });
  }

  Future<void> _download(String url) async {
    final dir = _dir;
    final name = _nameOf(url);
    if (dir == null || _files.containsKey(name)) return;

    final file = File('${dir.path}/$name');
    final temp = File('${file.path}.part');
    try {
      final response = await appHttp
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 20));
      final expected = response.contentLength ?? 0;
      if (response.statusCode != 200 || expected > _maxFileBytes) {
        // Not read: the connection is given back by draining it.
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        return;
      }
      final sink = temp.openWrite();
      try {
        await sink.addStream(response.stream.timeout(const Duration(seconds: 20)));
      } finally {
        await sink.close();
      }
      final size = await temp.length();
      if (size < _minFileBytes || size > _maxFileBytes || (expected > 0 && size != expected)) {
        await temp.delete();
        return;
      }
      await temp.rename(file.path);
      _files[name] = size;
      PlaybackLogService.instance.log(
        'CANVAS',
        'video tenuto per il prossimo ascolto '
        '(${(size / (1024 * 1024)).toStringAsFixed(1)} MB, ${_files.length} in tutto)',
      );
      await _prune();
    } catch (e) {
      debugPrint('CanvasFileCache: $url non salvato: $e');
      await _delete(temp);
    }
  }

  Future<void> _prune() async {
    final dir = _dir;
    if (dir == null) return;
    var total = _files.values.fold<int>(0, (sum, size) => sum + size);
    while (_files.length > _maxFiles || total > _maxTotalBytes) {
      final oldest = _files.keys.first;
      total -= _files.remove(oldest)!;
      await _delete(File('${dir.path}/$oldest'));
    }
  }

  /// Removes the file kept for [url]: it did not play.
  void drop(String url) {
    final dir = _dir;
    final name = _nameOf(url);
    if (dir == null || _files.remove(name) == null) return;
    unawaited(_delete(File('${dir.path}/$name')));
  }

  /// Removes every file.
  Future<void> clear() async {
    final dir = _dir;
    if (dir == null) return;
    final names = _files.keys.toList();
    _files.clear();
    for (final name in names) {
      await _delete(File('${dir.path}/$name'));
    }
  }
}
