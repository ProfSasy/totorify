import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import 'canvas_service.dart';
import 'lyrics_service.dart';
import 'playback_log_service.dart';
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
        // The exact length, so playback does not have to trust the player's
        // figure for this kind of file (see AudioPlayerHandler).
        final length = YTMusicService.instance.streamDuration(targetId);
        if (length != null) {
          await StorageService.instance.saveDownloadDuration(song.id, length);
        }
        unawaited(saveExtras(song));

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
      await _deleteSavedCanvas(songId);
    } catch (e) { debugPrint('DownloadService: $e'); }
  }

  // ── Extras of a download: Canvas video and lyrics ─────────────────────────
  //
  // Saved next to the audio, they make a downloaded song open at once and
  // work offline: nothing has to be looked up or fetched to show them.

  static const int _maxCanvasBytes = 30 * 1024 * 1024;
  // One song at a time, with a pause: nobody is waiting, and each Canvas
  // lookup is a burst of requests that Spotify rate-limits.
  static const Duration _extrasPause = Duration(milliseconds: 1500);

  Future<void> _extrasQueue = Future.value();
  final Set<String> _extrasQueued = {};

  bool _wantsCanvas(String songId) {
    final storage = StorageService.instance;
    final canvas = CanvasService.instance;
    if (!storage.savesCanvasWithDownloads || !canvas.isEnabled) return false;
    if (storage.hasLocalCanvas(songId)) return false;
    // Already known to have none: nothing to save.
    final knownNone = canvas.hasCachedResult(songId) &&
        canvas.getCachedCanvasUrlSync(songId) == null;
    return !knownNone;
  }

  bool _needsExtras(String songId) {
    if (!StorageService.instance.isDownloaded(songId)) return false;
    return _wantsCanvas(songId) || !LyricsService.instance.isStored(songId);
  }

  /// Saves the lyrics and (unless turned off in Settings) the Canvas video
  /// of a downloaded song. Returns at once when there is nothing to do.
  Future<void> saveExtras(Song song) {
    if (!_needsExtras(song.id) || !_extrasQueued.add(song.id)) return Future.value();
    final done = _extrasQueue.then((_) => _saveExtras(song)).whenComplete(() {
      _extrasQueued.remove(song.id);
    });
    _extrasQueue = done.then((_) => Future<void>.delayed(_extrasPause));
    return done;
  }

  Future<void> _saveExtras(Song song) async {
    try {
      if (!LyricsService.instance.isStored(song.id)) {
        await LyricsService.instance.getLyrics(song);
      }
      if (_wantsCanvas(song.id)) {
        final url = await CanvasService.instance.remoteCanvasUrl(song);
        if (url != null) await _saveCanvas(song, url);
      }
    } catch (e) {
      debugPrint('DownloadService.saveExtras "${song.title}": $e');
    }
  }

  Future<void> _saveCanvas(Song song, String url) async {
    final storage = StorageService.instance;
    await _getDownloadDir();
    final file = File(storage.localCanvasPath(song.id));
    final temp = File('${file.path}.tmp');
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 20));
      final expected = response.contentLength ?? 0;
      if (response.statusCode != 200 || expected > _maxCanvasBytes) {
        debugPrint('DownloadService canvas "${song.title}": '
            'HTTP ${response.statusCode}, $expected byte');
        return;
      }

      final sink = temp.openWrite();
      try {
        await sink.addStream(response.stream.timeout(const Duration(seconds: 30)));
      } finally {
        await sink.close();
      }

      final saved = await temp.length();
      final complete = saved > 8 * 1024 && (expected == 0 || saved == expected);
      // The song can have been deleted, or the setting turned off, while
      // its Canvas was coming down.
      if (!complete ||
          !storage.isDownloaded(song.id) ||
          !storage.savesCanvasWithDownloads) {
        return;
      }
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      storage.setLocalCanvas(song.id, saved: true);
      PlaybackLogService.instance.log(
        'DOWNLOAD',
        'canvas salvato per "${song.title}" '
        '(${(saved / (1024 * 1024)).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      debugPrint('DownloadService canvas "${song.title}": $e');
    } finally {
      client.close();
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // Left behind: the next save overwrites it.
      }
    }
  }

  Future<void> _deleteSavedCanvas(String songId) async {
    final storage = StorageService.instance;
    storage.setLocalCanvas(songId, saved: false);
    try {
      final file = File(storage.localCanvasPath(songId));
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('DownloadService._deleteSavedCanvas: $e');
    }
  }

  /// Brings the songs downloaded before (or while offline) up to date:
  /// saves the Canvas and lyrics they miss, in the background.
  Future<void> backfillExtras() async {
    final storage = StorageService.instance;
    // Videos of songs that are no longer downloaded.
    for (final id in storage.localCanvasIds) {
      if (!storage.isDownloaded(id)) await _deleteSavedCanvas(id);
    }

    final pending = [
      for (final song in storage.downloadsNotifier.value)
        if (_needsExtras(song.id)) song,
    ];
    if (pending.isEmpty) return;
    PlaybackLogService.instance.log(
      'DOWNLOAD',
      'recupero canvas e testi di ${pending.length} brani scaricati',
    );
    await Future.wait(pending.map(saveExtras));
    PlaybackLogService.instance.log(
      'DOWNLOAD',
      'recupero terminato: ${storage.localCanvasIds.length} canvas salvati in tutto',
    );
  }

  /// Frees the space taken by the saved Canvas videos (the setting was
  /// turned off). The songs keep playing; their Canvas streams again.
  Future<void> deleteSavedCanvases() async {
    for (final id in StorageService.instance.localCanvasIds) {
      await _deleteSavedCanvas(id);
    }
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
