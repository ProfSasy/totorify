import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import 'app_settings.dart';
import 'canvas_service.dart';
import 'lyrics_service.dart';
import 'playback_log_service.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';
import 'ytmusic_service.dart';
import 'flacdl/flacdl_service.dart';

/// Outcome of fetching one audio file: [failure] is null when it worked,
/// and [mode] says how the bytes came down.
typedef _Fetch = ({String? failure, String mode});

/// Downloads songs for offline playback: the audio in parallel ranges, then
/// the lyrics and the Canvas video that go with it.
///
/// Every download leaves its trace in the diagnostic log (tag `DOWNLOAD`):
/// source, size, time and speed when it works, the reason when it does not.
class DownloadService {
  static final DownloadService instance = DownloadService._internal();
  DownloadService._internal();

  static const _visionOsUa =
      'com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; IT)';

  static const int _chunkSize = 1024 * 1024;
  static const Duration _chunkTimeout = Duration(seconds: 30);
  // YouTube's servers refuse a request now and then (HTTP 403) and accept
  // the same one a moment later: a part is asked again before giving up.
  static const int _chunkAttempts = 3;
  // A connection that sends nothing for this long is given up.
  static const Duration _stallTimeout = Duration(seconds: 30);
  static const int _minValidBytes = 8 * 1024; // short tracks are legitimate

  final ValueNotifier<Map<String, double>> downloadProgressNotifier =
      ValueNotifier<Map<String, double>>({});

  final _failures = StreamController<String>.broadcast();

  /// Messages for the user about downloads that did not work.
  Stream<String> get failures => _failures.stream;

  Set<String>? _likedIds;

  /// From now on, a song given a heart is downloaded too, when the user
  /// wants it so (Settings > Playback).
  void downloadWhatIsLiked() {
    final favorites = StorageService.instance.favoritesNotifier;
    _likedIds = {for (final song in favorites.value) song.id};
    favorites.addListener(() {
      final known = _likedIds!;
      final now = favorites.value;
      final added = [for (final song in now) if (!known.contains(song.id)) song];
      _likedIds = {for (final song in now) song.id};
      if (!AppSettings.instance.downloadOnLike.value) return;
      for (final song in added) {
        if (!StorageService.instance.isDownloaded(song.id)) unawaited(downloadSong(song));
      }
    });
  }

  /// The downloads folder, created when missing: it does not exist on a new
  /// install, nor after "delete all downloads" removed it.
  Future<Directory> _ensureDownloadDir() async {
    final dir = Directory(StorageService.instance.downloadsPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  final Map<String, Future<bool>> _inFlight = {};

  /// Downloads a single song. Concurrent requests for the same song share
  /// the same future. [announceFailure] tells the user when it fails; a
  /// playlist download reports its own total instead.
  Future<bool> downloadSong(
    Song song, {
    bool force = false,
    bool announceFailure = true,
  }) {
    final running = _inFlight[song.id];
    if (running != null) return running;
    final future = _downloadSongInternal(song, force: force, announceFailure: announceFailure);
    _inFlight[song.id] = future;
    return future.whenComplete(() => _inFlight.remove(song.id));
  }

  Future<bool> _downloadSongInternal(
    Song song, {
    required bool force,
    required bool announceFailure,
  }) async {
    final storage = StorageService.instance;
    final log = PlaybackLogService.instance;
    if (!force && await storage.hasLocalAudioFile(song.id)) {
      return true;
    }

    final watch = Stopwatch()..start();
    final filePath = await storage.getLocalAudioPath(song.id);
    final tempFile = File('$filePath.tmp');
    final finalFile = File(filePath);
    log.log('DOWNLOAD', 'avvio "${song.title}" - ${song.artist} id=${song.id}'
        '${force ? ' (riscarico)' : ''}');

    var failure = 'motivo sconosciuto';
    try {
      await _ensureDownloadDir();
      _updateProgress(song.id, 0.05);

      // FLAC dal bridge: quando attivo, prima il file già pronto del bridge
      // (qualità senza perdita, nessun token da gestire); se non va,
      // si prosegue esattamente come sempre.
      if (await _tryDownloadFlacDl(song)) {
        _removeProgress(song.id);
        return true;
      }

      // The source is resolved exactly like playback does (scored matching,
      // remembered choices), so a download is never a different recording
      // from the one that plays.
      final videoId = await TrackMatcherService.instance.resolveAndCacheStreamId(song);
      if (videoId == null || videoId.isEmpty) {
        failure = 'nessuna sorgente trovata';
      } else {
        // A remembered URL can have expired: the second try asks a new one.
        for (var attempt = 0; attempt < 2; attempt++) {
          final url = await YTMusicService.instance
              .getAudioStreamUrl(videoId, force: attempt > 0);
          if (url == null) {
            failure = 'YouTube non ha restituito uno stream per $videoId';
            continue;
          }
          if (await tempFile.exists()) await tempFile.delete();

          final fetched = await _fetchAudio(song, Uri.parse(url), tempFile);
          if (fetched.failure != null) {
            failure = fetched.failure!;
            log.log('DOWNLOAD',
                '"${song.title}": tentativo ${attempt + 1} fallito ($failure)');
            continue;
          }

          final bytes = await tempFile.length();
          if (await finalFile.exists()) await finalFile.delete();
          await tempFile.rename(filePath);
          _updateProgress(song.id, 1.0);
          await storage.saveDownloadedSong(song);
          // The exact length, so playback does not have to trust the
          // player's figure for this kind of file (see AudioPlayerHandler).
          final length = YTMusicService.instance.streamDuration(videoId);
          if (length != null) await storage.saveDownloadDuration(song.id, length);

          final seconds = watch.elapsedMilliseconds / 1000;
          final megabytes = bytes / (1024 * 1024);
          log.log(
            'DOWNLOAD',
            '"${song.title}" scaricato: ${megabytes.toStringAsFixed(1)} MB in '
            '${seconds.toStringAsFixed(1)}s '
            '(${(megabytes / (seconds > 0 ? seconds : 1)).toStringAsFixed(1)} MB/s), '
            '${fetched.mode}, sorgente $videoId',
          );
          unawaited(saveExtras(song));

          await Future.delayed(const Duration(milliseconds: 250));
          _removeProgress(song.id);
          return true;
        }
      }
    } catch (e, stack) {
      failure = '$e';
      log.error('DOWNLOAD', '"${song.title}": $e', stack);
    }

    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      // Left behind: the next attempt overwrites it.
    }
    _removeProgress(song.id);
    log.error(
      'DOWNLOAD',
      '"${song.title}" non scaricato dopo '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s: $failure',
    );
    if (announceFailure) _failures.add('Download non riuscito: ${song.title}');
    return false;
  }

  /// FLAC dal bridge: un solo file dalla CDN del bridge, già pronto dal job
  /// (Range a blocchi come i download abituali, UA da browser normale).
  /// False quando manca il bridge, la sessione o il brano: il flusso YouTube
  /// poi prosegue identico a sempre.
  Future<bool> _tryDownloadFlacDl(Song song) async {
    if (!AppSettings.instance.flacDlEnabled.value) return false;
    final log = PlaybackLogService.instance;

    final stream = await FlacDlService.instance.resolveDownload(song);
    if (stream == null) {
      log.log('DOWNLOAD', '"${song.title}": flacdl non disponibile, YouTube segue');
      return false;
    }

    final filePath =
        '${StorageService.instance.downloadsPath}/${song.id}.flac';
    final tempFile = File('$filePath.tmp');
    final finalFile = File(filePath);
    final watch = Stopwatch()..start();
    try {
      if (await tempFile.exists()) await tempFile.delete();

      final fetched = await _fetchAudio(
        song,
        Uri.parse(stream.url),
        tempFile,
        headers: FlacDlService.cdnHeaders,
      );
      if (fetched.failure != null) {
        log.log(
          'DOWNLOAD',
          '"${song.title}": FLAC dal bridge non riuscito '
          '(${fetched.failure})',
        );
        FlacDlService.instance.discard(song.id);
        return false;
      }

      final bytes = await tempFile.length();
      if (await finalFile.exists()) await finalFile.delete();
      await tempFile.rename(filePath);
      _updateProgress(song.id, 1.0);
      await StorageService.instance.saveDownloadedSong(song);
      await StorageService.instance.saveDownloadDuration(song.id, song.duration);
      final seconds = watch.elapsedMilliseconds / 1000;
      log.log(
        'DOWNLOAD',
        '"${song.title}" FLAC dal bridge: '
        '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB in '
        '${seconds.toStringAsFixed(1)}s, ${fetched.mode}, ${stream.name}',
      );
      unawaited(saveExtras(song));
      return true;
    } catch (e, stack) {
      log.error('DOWNLOAD', '"${song.title}": FLAC dal bridge fallito: $e', stack);
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Brings the audio at [uri] down into [tempFile] and checks its size.
  /// [headers] ridefinisce la UA: i file della CDN del bridge preferiscono
  /// un UA da browser normale (FlacDlService.cdnHeaders).
  Future<_Fetch> _fetchAudio(
    Song song,
    Uri uri,
    File tempFile, {
    Map<String, String> headers = const {'User-Agent': _visionOsUa},
  }) async {
    // YouTube writes the size in the stream URL itself; asking the server
    // is the fallback.
    var expected = int.tryParse(uri.queryParameters['clen'] ?? '') ?? 0;
    if (expected <= 0) expected = await _lengthFromServer(uri, headers);

    var mode = 'a blocchi';
    String? failure;
    if (expected > _chunkSize) {
      final chunks = await _downloadInChunks(
        song: song,
        uri: uri,
        tempFile: tempFile,
        contentLength: expected,
        headers: headers,
      );
      failure = chunks.failure;
      if (chunks.retries > 0) mode = 'a blocchi (${chunks.retries} richieste ripetute)';
    }
    // Small files, unknown length, or a server that ignored the ranges.
    if (expected <= _chunkSize || failure == _rangesIgnored) {
      mode = 'in un flusso';
      failure = await _downloadStream(song: song, uri: uri, tempFile: tempFile, headers: headers);
    }
    if (failure != null) return (failure: failure, mode: mode);

    final actual = await tempFile.length();
    if (actual < _minValidBytes) {
      return (failure: 'file troppo piccolo ($actual byte)', mode: mode);
    }
    if (expected > 0 && (actual < expected * 0.98 || actual > expected * 1.02)) {
      return (failure: 'dimensione $actual byte invece di $expected', mode: mode);
    }
    return (failure: null, mode: mode);
  }

  Future<int> _lengthFromServer(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      final response = await http.head(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
      return int.tryParse(response.headers['content-length'] ?? '') ?? 0;
    } catch (e) {
      debugPrint('DownloadService.head: $e');
      return 0;
    }
  }

  static const String _rangesIgnored = 'il server ha ignorato gli intervalli';

  /// Downloads 1 MB parts in parallel into their own files (no handle ever
  /// truncates another part), then joins them. [failure] is null on
  /// success and [_rangesIgnored] when the server sent the whole file;
  /// [retries] counts the requests that had to be made again.
  Future<({String? failure, int retries})> _downloadInChunks({
    required Song song,
    required Uri uri,
    required File tempFile,
    required int contentLength,
    Map<String, String> headers = const {'User-Agent': _visionOsUa},
  }) async {
    final totalChunks = (contentLength / _chunkSize).ceil();
    var completed = 0;
    var downloadedBytes = 0;
    var retries = 0;
    var rangeBroken = false;
    String? failure;

    try {
      await _runConcurrentPool<int>(
        items: List.generate(totalChunks, (i) => i),
        concurrency: 4,
        worker: (i) async {
          final start = i * _chunkSize;
          final end = (i == totalChunks - 1)
              ? contentLength - 1
              : (start + _chunkSize - 1);

          for (var attempt = 1;; attempt++) {
            // Another part already gave up: no point in going on.
            if (rangeBroken || failure != null) return;
            String problem;
            try {
              final resp = await http.get(
                uri,
                headers: {
                  'Range': 'bytes=$start-$end',
                  ...headers,
                },
              ).timeout(_chunkTimeout);

              if (resp.statusCode == 200) {
                rangeBroken = true;
                return;
              }
              if (resp.statusCode == 206) {
                await File('${tempFile.path}.part$i')
                    .writeAsBytes(resp.bodyBytes, flush: true);
                completed++;
                downloadedBytes += resp.bodyBytes.length;
                _updateProgress(
                  song.id,
                  (downloadedBytes / contentLength).clamp(0.1, 0.9),
                );
                return;
              }
              problem = 'HTTP ${resp.statusCode}';
            } catch (e) {
              problem = '$e';
            }
            if (attempt >= _chunkAttempts) {
              failure ??= '$problem sul blocco ${i + 1} di $totalChunks';
              return;
            }
            retries++;
            await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
          }
        },
      );

      if (rangeBroken) return (failure: _rangesIgnored, retries: retries);
      if (failure != null) return (failure: failure, retries: retries);
      if (completed != totalChunks) {
        return (failure: 'scaricati $completed blocchi su $totalChunks', retries: retries);
      }

      final sink = tempFile.openWrite();
      try {
        for (var i = 0; i < totalChunks; i++) {
          await sink.addStream(File('${tempFile.path}.part$i').openRead());
        }
      } finally {
        await sink.close();
      }
      _updateProgress(song.id, 0.95);
      return (failure: null, retries: retries);
    } catch (e) {
      return (failure: '$e', retries: retries);
    } finally {
      for (var i = 0; i < totalChunks; i++) {
        final part = File('${tempFile.path}.part$i');
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {
          // A leftover part is overwritten by the next attempt.
        }
      }
    }
  }

  /// Plain download of the whole file. Returns null on success.
  Future<String?> _downloadStream({
    required Song song,
    required Uri uri,
    required File tempFile,
    Map<String, String> headers = const {'User-Agent': _visionOsUa},
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      for (final entry in headers.entries) {
        req.headers[entry.key] = entry.value;
      }
      final response = await client.send(req).timeout(_chunkTimeout);
      if (response.statusCode != 200) return 'HTTP ${response.statusCode}';

      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;
      final sink = tempFile.openWrite();
      try {
        await sink.addStream(
          response.stream.timeout(_stallTimeout).map((data) {
            receivedBytes += data.length;
            if (totalBytes > 0) {
              _updateProgress(
                song.id,
                (receivedBytes / totalBytes).clamp(0.1, 0.9),
              );
            }
            return data;
          }),
        );
      } finally {
        await sink.close();
      }
      _updateProgress(song.id, 0.95);
      return null;
    } catch (e) {
      return '$e';
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

    final log = PlaybackLogService.instance;
    log.log(
      'DOWNLOAD',
      'playlist: ${pending.length} brani da scaricare su ${songs.length}'
      '${forceRefresh ? ' (riscarico)' : ''}',
    );
    if (pending.isEmpty) return (0, 0);

    final watch = Stopwatch()..start();
    int successes = 0;
    int failures = 0;

    await _runConcurrentPool<Song>(
      items: pending,
      concurrency: 3,
      worker: (song) async {
        final ok = await downloadSong(song, force: forceRefresh, announceFailure: false);
        if (ok) {
          successes++;
        } else {
          failures++;
        }
      },
    );

    log.log(
      'DOWNLOAD',
      'playlist terminata: $successes riusciti, $failures falliti in '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
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
      // I FLAC dal bridge e i download abituali hanno estensioni diverse:
      // si puliscono entrambe.
      for (final path in [
        '${StorageService.instance.downloadsPath}/$songId.m4a',
        '${StorageService.instance.downloadsPath}/$songId.flac',
      ]) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
        final tempFile = File('$path.tmp');
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
      await StorageService.instance.removeDownloadedSong(songId);
      await _deleteSavedCanvas(songId);
      PlaybackLogService.instance.log('DOWNLOAD', 'eliminato $songId');
    } catch (e, stack) {
      PlaybackLogService.instance.error('DOWNLOAD', 'eliminazione di $songId: $e', stack);
    }
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
    final log = PlaybackLogService.instance;
    try {
      if (!LyricsService.instance.isStored(song.id)) {
        final lyrics = await LyricsService.instance.getLyrics(song);
        log.log('DOWNLOAD',
            '"${song.title}": ${lyrics.isEmpty ? 'nessun testo trovato' : 'testo salvato'}');
      }
      if (_wantsCanvas(song.id)) {
        final url = await CanvasService.instance.remoteCanvasUrl(song);
        if (url == null) {
          log.log('DOWNLOAD', '"${song.title}": nessun canvas da salvare');
        } else {
          await _saveCanvas(song, url);
        }
      }
    } catch (e, stack) {
      log.error('DOWNLOAD', 'extra di "${song.title}": $e', stack);
    }
  }

  Future<void> _saveCanvas(Song song, String url) async {
    final storage = StorageService.instance;
    final log = PlaybackLogService.instance;
    await _ensureDownloadDir();
    final file = File(storage.localCanvasPath(song.id));
    final temp = File('${file.path}.tmp');
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 20));
      final expected = response.contentLength ?? 0;
      if (response.statusCode != 200 || expected > _maxCanvasBytes) {
        log.log('DOWNLOAD', 'canvas di "${song.title}" non salvato: '
            'HTTP ${response.statusCode}, $expected byte');
        return;
      }

      final sink = temp.openWrite();
      try {
        await sink.addStream(response.stream.timeout(_stallTimeout));
      } finally {
        await sink.close();
      }

      final saved = await temp.length();
      final complete = saved > _minValidBytes && (expected == 0 || saved == expected);
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
      log.log(
        'DOWNLOAD',
        'canvas salvato per "${song.title}" '
        '(${(saved / (1024 * 1024)).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      log.log('DOWNLOAD', 'canvas di "${song.title}" non salvato: $e');
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
    final log = PlaybackLogService.instance;
    // Videos of songs that are no longer downloaded.
    for (final id in storage.localCanvasIds) {
      if (!storage.isDownloaded(id)) await _deleteSavedCanvas(id);
    }

    final downloads = storage.downloadsNotifier.value;
    final pending = [
      for (final song in downloads)
        if (_needsExtras(song.id)) song,
    ];
    log.log(
      'DOWNLOAD',
      'brani scaricati: ${downloads.length}, canvas salvati: '
      '${storage.localCanvasIds.length}, da completare: ${pending.length}',
    );
    if (pending.isEmpty) return;
    await Future.wait(pending.map(saveExtras));
    log.log(
      'DOWNLOAD',
      'recupero terminato: ${storage.localCanvasIds.length} canvas salvati in tutto',
    );
  }

  /// Frees the space taken by the saved Canvas videos (the setting was
  /// turned off). The songs keep playing; their Canvas streams again.
  Future<void> deleteSavedCanvases() async {
    final ids = StorageService.instance.localCanvasIds;
    for (final id in ids) {
      await _deleteSavedCanvas(id);
    }
    PlaybackLogService.instance.log('DOWNLOAD', 'eliminati ${ids.length} canvas salvati');
  }

  Future<double> getTotalStorageUsedMB() async {
    try {
      final dir = Directory(StorageService.instance.downloadsPath);
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
      final dir = Directory(StorageService.instance.downloadsPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await StorageService.instance.clearAllDownloadsBox();
      PlaybackLogService.instance.log('DOWNLOAD', 'eliminati tutti i download');
    } catch (e, stack) {
      PlaybackLogService.instance.error('DOWNLOAD', 'eliminazione di tutti i download: $e', stack);
    }
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
