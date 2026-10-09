import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';
import 'ytmusic_service.dart';

/// High-speed offline download service featuring parallel Range chunking
/// and multi-worker concurrent playlist downloading.
class DownloadService {
  static final DownloadService instance = DownloadService._internal();
  DownloadService._internal();

  static const _visionOsUa =
      'com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; IT)';

  final ValueNotifier<Map<String, double>> downloadProgressNotifier =
      ValueNotifier<Map<String, double>>({});

  Future<String> _getDownloadDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final downloadDir = Directory('${appDir.path}/downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  final Map<String, Future<bool>> _inFlight = {};

  /// Downloads a single song using high-speed parallel Range chunking.
  /// Concurrent requests for the same song share the same future.
  Future<bool> downloadSong(Song song, {bool force = false}) {
    final running = _inFlight[song.id];
    if (running != null) return running;
    final future = _downloadSongInternal(song, force: force);
    _inFlight[song.id] = future;
    return future.whenComplete(() => _inFlight.remove(song.id));
  }

  Future<bool> _downloadSongInternal(Song song, {required bool force}) async {
    if (!force && await StorageService.instance.hasLocalAudioFile(song.id)) {
      return true;
    }

    final filePath = await StorageService.instance.getLocalAudioPath(song.id);
    final tempFilePath = '$filePath.tmp';
    final tempFile = File(tempFilePath);
    final finalFile = File(filePath);

    try {
      _updateProgress(song.id, 0.05);

      // 1. Resolve the audio source exactly like playback does: scored
      // matching (title/artist/duration) with the persistent mapping cache.
      // Downloads therefore never grab the wrong video and never re-resolve
      // a song that was already matched or is already playing.
      final targetId =
          await TrackMatcherService.instance.resolveAndCacheStreamId(song);
      if (targetId == null || targetId.isEmpty) {
        _removeProgress(song.id);
        return false;
      }

      // Shared YTMusicService cache: if playback just resolved this stream
      // the download starts immediately, and parallel downloads of the same
      // video collapse into one resolution.
      final audioUrl =
          await YTMusicService.instance.getAudioStreamUrl(targetId);
      if (audioUrl == null) {
        _removeProgress(song.id);
        return false;
      }

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      final uri = Uri.parse(audioUrl);

      // 2. Query Content-Length via HEAD request
      int contentLength = 0;
      try {
        final headResp = await http.head(uri, headers: {
          'User-Agent': _visionOsUa,
        }).timeout(const Duration(seconds: 8));
        contentLength = int.tryParse(headResp.headers['content-length'] ?? '') ?? 0;
      } catch (e) {
        debugPrint('DownloadService.head: $e');
      }

      bool downloaded = false;
      const chunkSize = 1024 * 1024; // 1 MB chunks

      // 3a. Parallel chunk download into separate part files. Each part is
      // written to its own file so no handle ever truncates another chunk.
      if (contentLength > chunkSize) {
        downloaded = await _downloadInChunks(
          song: song,
          uri: uri,
          tempFile: tempFile,
          contentLength: contentLength,
          chunkSize: chunkSize,
        );
      }

      // 3b. Streaming fallback (small files, unknown length, or a CDN that
      // ignored the Range requests).
      if (!downloaded) {
        downloaded = await _downloadStream(
          song: song,
          uri: uri,
          tempFile: tempFile,
        );
      }

      if (!downloaded) {
        if (await tempFile.exists()) await tempFile.delete();
        _removeProgress(song.id);
        return false;
      }

      // 4. Integrity verification against the expected size when available.
      final actualLength = await tempFile.length();
      final expectedOk = contentLength <= 0 ||
          (actualLength >= contentLength * 0.98 &&
              actualLength <= contentLength * 1.02);
      const minValidSize = 8 * 1024; // short tracks are legitimate
      final minOk = contentLength > 0 || actualLength >= minValidSize;

      if (actualLength > 0 && expectedOk && minOk) {
        if (await finalFile.exists()) {
          await finalFile.delete();
        }
        await tempFile.rename(filePath);
        _updateProgress(song.id, 1.0);

        await StorageService.instance.saveDownloadedSong(song);

        await Future.delayed(const Duration(milliseconds: 250));
        _removeProgress(song.id);
        return true;
      }

      if (await tempFile.exists()) await tempFile.delete();
      _removeProgress(song.id);
      return false;
    } catch (e) {
      debugPrint('DownloadService.downloadSong: $e');
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (e) {
          debugPrint('DownloadService: $e');
        }
      }
      _removeProgress(song.id);
      return false;
    }
  }

  /// Downloads 1 MB parts in parallel, then merges them sequentially.
  /// Returns false when the CDN ignores Range requests (HTTP 200) so the
  /// caller can fall back to a plain streaming download.
  Future<bool> _downloadInChunks({
    required Song song,
    required Uri uri,
    required File tempFile,
    required int contentLength,
    required int chunkSize,
  }) async {
    final totalChunks = (contentLength / chunkSize).ceil();
    final parts = <File>[];
    int downloadedBytes = 0;
    bool rangeBroken = false;

    try {
      await _runConcurrentPool<int>(
        items: List.generate(totalChunks, (i) => i),
        concurrency: 4,
        worker: (i) async {
          if (rangeBroken) return;
          final start = i * chunkSize;
          final end = (i == totalChunks - 1)
              ? contentLength - 1
              : (start + chunkSize - 1);

          final resp = await http.get(
            uri,
            headers: {
              'Range': 'bytes=$start-$end',
              'User-Agent': _visionOsUa,
            },
          ).timeout(const Duration(seconds: 30));

          if (resp.statusCode == 200) {
            // The server ignored the Range header: the body is the whole
            // file, so chunked download is not viable.
            rangeBroken = true;
            return;
          }
          if (resp.statusCode != 206) {
            throw Exception('HTTP ${resp.statusCode} on chunk $i');
          }

          final part = File('${tempFile.path}.part$i');
          await part.writeAsBytes(resp.bodyBytes, flush: true);
          parts.add(part);
          downloadedBytes += resp.bodyBytes.length;
          _updateProgress(
            song.id,
            (downloadedBytes / contentLength).clamp(0.1, 0.9),
          );
        },
      );

      if (rangeBroken || parts.length != totalChunks) {
        return false;
      }

      // Merge the parts sequentially into the temp file.
      final sink = tempFile.openWrite();
      try {
        for (var i = 0; i < totalChunks; i++) {
          final part = File('${tempFile.path}.part$i');
          if (!await part.exists()) return false;
          await for (final chunk in part.openRead()) {
            sink.add(chunk);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      _updateProgress(song.id, 0.95);
      return true;
    } catch (e) {
      debugPrint('DownloadService._downloadInChunks: $e');
      return false;
    } finally {
      for (var i = 0; i < totalChunks; i++) {
        final part = File('${tempFile.path}.part$i');
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }

  Future<bool> _downloadStream({
    required Song song,
    required Uri uri,
    required File tempFile,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', uri)..headers['User-Agent'] = _visionOsUa;
      final response =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return false;

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;
      final sink = tempFile.openWrite();
      try {
        await response.stream.listen(
          (data) {
            sink.add(data);
            receivedBytes += data.length;
            if (totalBytes > 0) {
              _updateProgress(
                song.id,
                (receivedBytes / totalBytes).clamp(0.1, 0.9),
              );
            }
          },
          cancelOnError: true,
        ).asFuture();
      } finally {
        await sink.flush();
        await sink.close();
      }
      _updateProgress(song.id, 0.95);
      return true;
    } catch (e) {
      debugPrint('DownloadService._downloadStream: $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// Downloads all songs in a playlist, three at a time. Returns how many
  /// downloads succeeded and how many failed.
  Future<(int, int)> downloadPlaylist(List<Song> songs, {bool forceRefresh = false}) async {
    final pending = songs
        .where((s) => forceRefresh || !StorageService.instance.isDownloaded(s.id))
        .toList();

    if (pending.isEmpty) return (0, 0);

    int successes = 0;
    int failures = 0;

    await _runConcurrentPool<Song>(
      items: pending,
      concurrency: 3,
      worker: (song) async {
        final ok = await downloadSong(song, force: forceRefresh);
        if (ok) {
          successes++;
        } else {
          failures++;
        }
      },
    );

    return (successes, failures);
  }

  /// Helper to run async tasks with controlled concurrency.
  Future<void> _runConcurrentPool<T>({
    required List<T> items,
    required int concurrency,
    required Future<void> Function(T item) worker,
  }) async {
    int nextIndex = 0;
    final activeWorkers = <Future<void>>[];

    while (nextIndex < items.length || activeWorkers.isNotEmpty) {
      while (nextIndex < items.length && activeWorkers.length < concurrency) {
        final item = items[nextIndex++];
        late Future<void> task;
        task = worker(item).whenComplete(() {
          activeWorkers.remove(task);
        });
        activeWorkers.add(task);
      }

      if (activeWorkers.isNotEmpty) {
        await Future.any(activeWorkers);
      }
    }
  }

  Future<void> deleteDownloadedSong(String songId) async {
    try {
      final filePath = await StorageService.instance.getLocalAudioPath(songId);
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      final tempFile = File('$filePath.tmp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      await StorageService.instance.removeDownloadedSong(songId);
    } catch (e) { debugPrint('DownloadService: $e'); }
  }

  Future<double> getTotalStorageUsedMB() async {
    try {
      final downloadDir = await _getDownloadDir();
      final dir = Directory(downloadDir);
      if (!await dir.exists()) return 0.0;

      int totalBytes = 0;
      await for (final file in dir.list(recursive: false, followLinks: false)) {
        if (file is File) {
          totalBytes += await file.length();
        }
      }
      return totalBytes / (1024 * 1024);
    } catch (e) {
      debugPrint('DownloadService.getTotalStorageUsedMB: $e');
      return 0.0;
    }
  }

  Future<void> clearAllDownloads() async {
    try {
      final downloadDir = await _getDownloadDir();
      final dir = Directory(downloadDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await StorageService.instance.clearAllDownloadsBox();
    } catch (e) { debugPrint('DownloadService: $e'); }
  }

  void _updateProgress(String songId, double progress) {
    final current = Map<String, double>.from(downloadProgressNotifier.value);
    current[songId] = progress;
    downloadProgressNotifier.value = current;
  }

  void _removeProgress(String songId) {
    final current = Map<String, double>.from(downloadProgressNotifier.value);
    current.remove(songId);
    downloadProgressNotifier.value = current;
  }
}
