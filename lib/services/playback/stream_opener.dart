import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../playback_log_service.dart';
import 'player_backend.dart';

/// Where the audio of a song can be found: the downloaded file, the YouTube
/// video matched for it and the streams of that video.
abstract interface class PlaybackSources {
  Future<bool> hasLocalFile(String songId);
  Future<String> localPath(String songId);

  /// Length of the downloaded file, when it was saved with it.
  Duration? localDuration(String songId);

  /// YouTube video to play for [song], or null when none can be found.
  Future<String?> resolveStreamId(Song song);

  /// Another video for [song], skipping the ids in [exclude].
  Future<String?> alternativeStreamId(Song song, {required Set<String> exclude});

  /// Remembers [videoId] as the source of the song [songId].
  Future<void> rememberSource(String songId, String videoId);

  /// True where the direct stream (Opus) goes before the HLS playlist.
  bool get opusFirst;

  bool hasCachedAudioUrl(String videoId);

  /// Exact length of the video, when its streams were looked up.
  Duration? streamDuration(String videoId);

  Future<String?> hlsAudioUrl(String videoId, {bool force = false});
  Future<String?> audioStreamUrl(String videoId, {bool force = false});
  Future<String?> hlsUrl(String videoId);
}

/// What loading a track needs from the audio handler.
abstract interface class StreamOpenerHost {
  Song? get currentSong;

  /// Replaces the queued song with [id].
  void updateSong(String id, Song Function(Song) update);

  /// True when the queue has a track after the current one.
  bool get hasNext;

  /// True while another device plays instead of this one.
  bool get isRemote;

  /// The user wants a song that cannot be played to be passed over.
  bool get skipUnplayable;

  bool get userPaused;
  bool get userStopped;
  set userStopped(bool value);

  double get playerVolume;
  double get speed;

  /// Where the playback is, in seconds.
  double get positionSeconds;

  /// Where [song] starts, in seconds.
  double startOffsetSecondsOf(Song song);

  /// The YouTube video [song] is played from, when known without asking.
  String? knownVideoIdOf(Song song);

  /// A load begins, from [start]: what belonged to the previous track (a
  /// crossfade not started by this load, a seek in flight, the parts to
  /// skip) is cleared.
  void onLoadStarting(Duration start);

  void publish({
    required AudioProcessingState processing,
    required bool playing,
    bool pollPosition = true,
  });

  /// Looks up, beside the load, the parts of [videoId] to skip and how loud
  /// it is.
  void prepareExtras(String? videoId, int generation);

  /// The downloaded file of [song] is playing.
  void onLocalFilePlaying(Song song);

  /// The current track has started: what comes next can be prepared.
  void prepareWhatFollows(Song song, int generation);

  /// The player changed what it reports.
  void onPlayerValue(PlayerBackend player);

  /// Sets the length of what is playing from what the player [reported]
  /// and what is [known] of the source; returns the length taken.
  Duration resolveTrackDuration(Duration reported, Duration? known);

  /// A seek asked while the track was loading, once.
  Duration? takePendingSeek();

  void setPosition(Duration position, {bool announce = false});
  void publishCurrentMediaItem();

  /// Shows where what plays comes from.
  void showSource(String source);

  Future<void> activateSession();

  /// The new player is playing: a crossfade waiting for it starts to move.
  void startFadeRampIfFading();
  void finishCrossfade();

  void reportError(String message);
  void reportInfo(String message);

  /// Loads the current song again.
  Future<void> reload({bool allowLocal = true, double? startSeconds, bool freshUrl = false});

  Future<void> skipToNext();
}

/// How an attempt to open a source ended.
enum _Open {
  /// The source is attached and playing (or paused, if the user asked).
  ok,

  /// A newer load started meanwhile: nothing more to do for this one.
  superseded,

  /// The source could not be played.
  failed,
}

/// Loads the current song into a player, from one of these sources, tried
/// in this order:
/// 1. the downloaded file, for songs saved offline;
/// 2. the audio-only HLS playlist of the matched YouTube video;
/// 3. the direct AAC stream of the same video;
/// 4. its full HLS manifest, video included.
/// When a video cannot be played at all, the next best match is tried.
class StreamOpener {
  StreamOpener({
    required StreamOpenerHost host,
    required PlaybackSources sources,
    required PlayerBackendFactory createPlayer,
    this.openTimeout = const Duration(seconds: 20),
    this.skipDelay = const Duration(milliseconds: 1500),
  })  : _host = host,
        _sources = sources,
        _createPlayer = createPlayer;

  final StreamOpenerHost _host;
  final PlaybackSources _sources;

  // Makes the player of a source: the native one, or a fake in the tests.
  final PlayerBackendFactory _createPlayer;

  /// How long a source may take to become playable.
  final Duration openTimeout;

  /// How long after a failure the next song starts.
  final Duration skipDelay;

  static const int _maxSourceAttempts = 3;

  /// The player of the current track.
  PlayerBackend? player;

  /// Counts the loads: one that is no longer the last has been superseded.
  int generation = 0;

  /// True from a load until its player is attached: the previous player is
  /// still around and what it reports must not be published.
  bool loading = false;

  /// True from the moment a new player is attached until it is told to
  /// play: meanwhile it reports "paused", which would flash on the lock
  /// screen.
  bool starting = false;

  /// YouTube video being streamed, or null while a local file plays.
  String? currentStreamId;

  // Songs that could not be played one after the other: past a few, the
  // queue is not skipped through any further.
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  // Videos that failed for a song in this session, so they are not retried,
  // and how many times a song was reloaded after an error while playing.
  final Map<String, Set<String>> _failedStreams = {};
  final Map<String, int> _errorReloads = {};
  int _errorHandledFor = -1;

  /// [songId] is asked for again: what failed for it before is tried anew.
  void forgetFailures(String songId) {
    _failedStreams.remove(songId);
    _errorReloads.remove(songId);
  }

  /// The player failed while a track was playing (dropped connection,
  /// expired stream URL, unreadable file). Reload once from where it was,
  /// with a fresh URL; if it fails again, move to another source.
  Future<void> onPlaybackError(String description) async {
    if (_errorHandledFor == generation) return;
    _errorHandledFor = generation;

    final song = _host.currentSong;
    final seconds = _host.positionSeconds;
    PlaybackLogService.instance.error(
      'PLAYER',
      'errore durante la riproduzione a ${seconds.toStringAsFixed(1)}s '
      '(${currentStreamId ?? 'file locale'}): $description',
    );
    if (song == null) return;

    final reloads = _errorReloads[song.id] ?? 0;
    if (reloads < 1) {
      _errorReloads[song.id] = reloads + 1;
      await _host.reload(
        // A local file that failed once is not tried again.
        allowLocal: false,
        startSeconds: seconds,
        freshUrl: true,
      );
      return;
    }
    await _recoverFromStreamFailure('errore di riproduzione', definitive: false);
  }

  /// Loads and plays the current song. [startSeconds] defaults to the song's
  /// start offset; [freshUrl] skips the remembered stream URL.
  Future<void> load({
    bool allowLocal = true,
    double? startSeconds,
    bool freshUrl = false,
  }) async {
    final song = _host.currentSong;
    if (song == null) return;
    final start = startSeconds ?? _host.startOffsetSecondsOf(song);
    final generation = ++this.generation;
    loading = true;
    starting = false;
    _host.onLoadStarting(Duration(milliseconds: (start * 1000).round()));
    final log = PlaybackLogService.instance;
    log.log('LOAD', '#$generation "${song.title}" - ${song.artist} id=${song.id}'
        '${start > 0 ? ' da ${start.toStringAsFixed(1)}s' : ''}');

    // Silence the previous track right away; its player is replaced once the
    // new one is ready.
    unawaited(pauseQuietly(player));

    // Immediately notify UI that we are buffering
    _host.publish(
      processing: AudioProcessingState.buffering,
      playing: true,
      pollPosition: false,
    );

    try {
      if (allowLocal && await _sources.hasLocalFile(song.id)) {
        if (generation != this.generation) return;
        final path = await _sources.localPath(song.id);
        _host.prepareExtras(_host.knownVideoIdOf(song), generation);
        final opened = await _open(
          () => _createPlayer(PlayerSource.file(path)),
          generation,
          start: start,
          source: 'file locale',
          knownDuration: _sources.localDuration(song.id),
        );
        if (opened == _Open.ok) {
          currentStreamId = null;
          _host.onLocalFilePlaying(song);
          _host.prepareWhatFollows(song, generation);
        }
        // An unreadable file falls through to streaming below.
        if (opened != _Open.failed) return;
      }

      final videoId = await _sources.resolveStreamId(song);
      if (generation != this.generation) {
        log.log('LOAD', '#$generation superato da un caricamento più recente');
        return;
      }
      if (videoId == null) {
        _failLoad('Nessuna sorgente trovata per ${song.title}');
        return;
      }
      currentStreamId = videoId;
      _host.prepareExtras(videoId, generation);

      final outcome = await _openStream(videoId, generation, start: start, freshUrl: freshUrl);
      if (outcome.result == _Open.ok) {
        _host.prepareWhatFollows(song, generation);
        return;
      }
      if (outcome.result == _Open.superseded || generation != this.generation) return;

      await _recoverFromStreamFailure(
        outcome.unavailable ? 'video non disponibile' : 'stream non riproducibile',
        // YouTube itself refused the video: do not pick it again.
        definitive: outcome.unavailable,
      );
    } catch (e, stack) {
      log.error('LOAD', '#$generation "${song.title}" fallito: $e', stack);
      if (generation == this.generation) {
        _failLoad('Errore di riproduzione per ${song.title}');
      }
    }
  }

  /// Streams [videoId]: its audio-only HLS playlist first, then the direct
  /// AAC stream, then the full HLS manifest. [unavailable] is true when
  /// YouTube returned no stream at all for it.
  Future<({_Open result, bool unavailable})> _openStream(
    String videoId,
    int generation, {
    required double start,
    required bool freshUrl,
  }) async {
    final log = PlaybackLogService.instance;
    const superseded = (result: _Open.superseded, unavailable: false);

    Future<_Open> openUrl(String url, String label, {bool hls = false}) => _open(
          () => _createPlayer(PlayerSource.network(url, isHls: hls)),
          generation,
          start: start,
          source: '$label $videoId',
          knownDuration: _sources.streamDuration(videoId),
        );

    final hadRemembered = _sources.hasCachedAudioUrl(videoId);

    // Where Opus plays, its direct stream is the best audio there is: it
    // goes first, and the HLS playlist (AAC) is what follows if it fails.
    // On iOS the HLS playlist goes first: same AAC, better seeking.
    final opusFirst = _sources.opusFirst;
    String? hlsAudio;
    if (!opusFirst) {
      // [freshUrl] makes this first lookup forget every remembered URL of
      // the video, so the ones asked below are new as well.
      hlsAudio = await _sources.hlsAudioUrl(videoId, force: freshUrl);
      if (generation != this.generation) return superseded;
      if (hlsAudio != null) {
        final opened = await openUrl(hlsAudio, 'HLS audio', hls: true);
        if (opened != _Open.failed) return (result: opened, unavailable: false);
      }
    }

    var url = await _sources.audioStreamUrl(videoId, force: opusFirst && freshUrl);
    if (generation != this.generation) return superseded;

    if (url == null) {
      log.error('LOAD', 'YouTube non ha restituito uno stream audio per $videoId');
    } else {
      var opened = await openUrl(url, 'stream');
      if (opened != _Open.failed) return (result: opened, unavailable: false);

      // A remembered URL can have expired: one more try with a new one.
      if (hadRemembered && !freshUrl) {
        log.log('LOAD', 'URL ricordato rifiutato, ne chiedo uno nuovo per $videoId');
        url = await _sources.audioStreamUrl(videoId, force: true);
        if (generation != this.generation) return superseded;
        if (url != null) {
          opened = await openUrl(url, 'stream (nuovo URL)');
          if (opened != _Open.failed) return (result: opened, unavailable: false);
        }
      }
    }

    if (opusFirst) {
      hlsAudio = await _sources.hlsAudioUrl(videoId);
      if (generation != this.generation) return superseded;
      if (hlsAudio != null) {
        final opened = await openUrl(hlsAudio, 'HLS audio', hls: true);
        if (opened != _Open.failed) return (result: opened, unavailable: false);
      }
    }

    final hls = await _sources.hlsUrl(videoId);
    if (generation != this.generation) return superseded;
    if (hls != null) {
      final opened = await openUrl(hls, 'HLS completo', hls: true);
      if (opened != _Open.failed) return (result: opened, unavailable: false);
    }
    return (
      result: _Open.failed,
      unavailable: url == null && hls == null && hlsAudio == null,
    );
  }

  /// The raw label goes to the playback log; for the interface the YouTube
  /// branches read better as plain "YouTube" ("HLS audio..." is noise).
  static String prettySource(String source) {
    if (source.startsWith('HLS')) return 'YouTube (HLS)';
    if (source.startsWith('Opus')) return 'YouTube (Opus)';
    if (source.startsWith('stream')) return 'YouTube';
    return source;
  }

  /// Creates a player for one source, waits until it can play and makes it
  /// the active one.
  Future<_Open> _open(
    PlayerBackend Function() create,
    int generation, {
    required double start,
    required String source,
    Duration? knownDuration,
  }) async {
    final log = PlaybackLogService.instance;
    final watch = Stopwatch()..start();
    final controller = create();
    try {
      await controller.initialize().timeout(openTimeout);
      if (generation != this.generation) {
        await disposeQuietly(controller);
        return _Open.superseded;
      }

      final previous = player;
      player = controller;
      loading = false;
      starting = true;
      controller.addListener(() => _host.onPlayerValue(controller));
      unawaited(disposeQuietly(previous));

      final reported = controller.value.duration;
      final trackDuration = _host.resolveTrackDuration(reported, knownDuration);
      final misreported = (reported - trackDuration).abs() > const Duration(seconds: 2);

      await controller.setVolume(_host.playerVolume);
      await controller.setPlaybackSpeed(_host.speed);
      // A newer load can begin while this player is being set up (skipping
      // quickly through tracks). It silenced this one and will replace it:
      // carrying on would start a track that was already skipped.
      if (generation != this.generation) return _Open.superseded;
      final startAt = _host.takePendingSeek() ?? Duration(milliseconds: (start * 1000).round());
      if (startAt > Duration.zero) await controller.seekTo(startAt);
      if (generation != this.generation) return _Open.superseded;
      _host.setPosition(startAt, announce: true);
      _host.publishCurrentMediaItem();
      _host.showSource(prettySource(source));
      _consecutiveFailures = 0;
      log.log(
        'PLAY',
        '#$generation $source pronto in ${watch.elapsedMilliseconds}ms, '
        'durata ${trackDuration.inSeconds}s'
        '${misreported ? ' (il lettore ne dichiara ${reported.inSeconds})' : ''}',
      );

      if (_host.userPaused) {
        // Paused while it was loading: ready, but silent.
        starting = false;
        _host.publish(processing: AudioProcessingState.ready, playing: false);
      } else {
        await _host.activateSession();
        if (generation != this.generation) return _Open.superseded;
        await controller.play();
        starting = false;
        _host.startFadeRampIfFading();
        // What it reported while starting was skipped: publish where it is.
        _host.onPlayerValue(controller);
      }
      return _Open.ok;
    } catch (e, stack) {
      log.error(
        'PLAY',
        '#$generation $source non riproducibile dopo ${watch.elapsedMilliseconds}ms: $e',
        e is TimeoutException ? null : stack,
      );
      if (identical(player, controller)) {
        player = null;
        starting = false;
        loading = generation == this.generation;
      }
      await disposeQuietly(controller);
      return generation == this.generation ? _Open.failed : _Open.superseded;
    }
  }

  Future<void> pauseQuietly(PlayerBackend? controller) async {
    try {
      await controller?.pause();
    } catch (_) {
      // Already disposed: nothing to silence.
    }
  }

  Future<void> disposeQuietly(PlayerBackend? controller) async {
    if (controller == null) return;
    await pauseQuietly(controller);
    try {
      await controller.dispose();
    } catch (e) {
      debugPrint('StreamOpener.disposeQuietly: $e');
    }
  }

  /// Reports a failed load and leaves the "buffering" state set when it
  /// started; otherwise the player would show a spinner forever. The next
  /// play() retries the load.
  void _failLoad(String message) {
    PlaybackLogService.instance.error('FAIL', message);
    _host.reportError(message);
    _host.userStopped = true;
    loading = false;
    _host.publish(processing: AudioProcessingState.idle, playing: false);
    _host.finishCrossfade();
    _skipAfterFailure();
  }

  /// A song that cannot be played is passed over, when the user wants it:
  /// the next one starts after a moment, unless something else was asked
  /// meanwhile. A few failures in a row stop it (no network, most likely).
  void _skipAfterFailure() {
    if (!_host.skipUnplayable || _host.isRemote) return;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      PlaybackLogService.instance.log('SKIP', 'troppi brani non riproducibili di fila: mi fermo');
      _consecutiveFailures = 0;
      return;
    }
    if (!_host.hasNext) return;
    _consecutiveFailures++;
    final generation = this.generation;
    final failed = _host.currentSong?.id;
    unawaited(Future<void>.delayed(skipDelay, () async {
      if (generation != this.generation ||
          !_host.userStopped ||
          _host.currentSong?.id != failed) {
        return;
      }
      PlaybackLogService.instance.log('SKIP', 'brano non riproducibile: passo al successivo');
      _host.reportInfo('Brano non disponibile: passo al successivo');
      await _host.skipToNext();
    }));
  }

  /// The current video cannot be played: try the next best match, up to
  /// [_maxSourceAttempts] videos per song. A [definitive] failure replaces
  /// the remembered source, so the broken one is not picked again.
  Future<void> _recoverFromStreamFailure(String reason, {required bool definitive}) async {
    final generation = this.generation;
    final song = _host.currentSong;
    final failedId = currentStreamId;
    if (song == null || failedId == null) {
      _failLoad('Impossibile riprodurre "${song?.title ?? ''}" ($reason)');
      return;
    }

    final failed = (_failedStreams[song.id] ??= <String>{})..add(failedId);
    if (failed.length >= _maxSourceAttempts) {
      _failLoad('Impossibile riprodurre "${song.title}" ($reason)');
      return;
    }

    PlaybackLogService.instance.log(
      'RECOVER',
      '"${song.title}": $reason su $failedId, cerco un\'altra sorgente '
      '(tentativo ${failed.length + 1}/$_maxSourceAttempts)',
    );
    final alternative = await _sources.alternativeStreamId(song, exclude: failed);
    if (generation != this.generation) return;
    if (alternative == null) {
      _failLoad('Impossibile riprodurre "${song.title}" ($reason, nessuna alternativa)');
      return;
    }

    PlaybackLogService.instance.log('RECOVER', 'nuova sorgente: $alternative');
    _host.updateSong(song.id, (s) => s.copyWith(youtubeVideoId: alternative));
    if (definitive) {
      await _sources.rememberSource(song.id, alternative);
    }
    await _host.reload(allowLocal: false);
  }
}
