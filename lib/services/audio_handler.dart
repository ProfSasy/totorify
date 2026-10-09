import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/song.dart';
import 'canvas_service.dart';
import 'canvas_video_pool.dart';
import 'cover_art_service.dart';
import 'playback_log_service.dart';
import 'playback_queue.dart';
import 'recommendation_service.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';
import 'ytmusic_service.dart';

/// How an attempt to open a source ended.
enum _Open {
  /// The source is attached and playing (or paused, if the user asked).
  ok,

  /// A newer load started meanwhile: nothing more to do for this one.
  superseded,

  /// The source could not be played.
  failed,
}

/// Bridge between the UI, audio_service and the native player.
///
/// Audio is played by AVPlayer (through [VideoPlayerController]) from one of
/// these sources, tried in this order:
/// 1. the downloaded file, for songs saved offline;
/// 2. the audio-only HLS playlist of the matched YouTube video;
/// 3. the direct AAC stream of the same video;
/// 4. its full HLS manifest, video included.
/// When a video cannot be played at all, the next best match is tried.
///
/// Playing natively is what makes background playback and the lock screen
/// work. The embedded YouTube player used before is rejected by YouTube for
/// every video (error 152), so it is no longer an option.
///
/// Queue rules (order, shuffle, repeat) live in [PlaybackQueue].
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  final PlaybackQueue _queue = PlaybackQueue();

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  // Background playback must be allowed explicitly: by default the plugin
  // pauses its players when the app leaves the foreground.
  static final VideoPlayerOptions _audioOptions =
      VideoPlayerOptions(allowBackgroundPlayback: true);

  static const Duration _openTimeout = Duration(seconds: 20);
  static const int _maxSourceAttempts = 3;
  static const Duration _seekTimeout = Duration(seconds: 8);
  // How close to the end a track counts as finished.
  static const Duration _endMargin = Duration(milliseconds: 250);

  VideoPlayerController? _player;
  double _volume = 1.0;
  double _speed = 1.0;

  Timer? _positionTimer;

  /// YouTube video being streamed, or null while a local file plays.
  String? _currentStreamId;

  // True until the user (or the queue) asks for playback again after a stop
  // or a failed load: play() then loads the current song from scratch.
  bool _userStopped = true;
  // Set by pause(), cleared by play() and by a new load. A track that
  // finishes loading while this is set stays paused.
  bool _userPaused = false;
  // True from a load until its player is attached: the previous player is
  // still around and what it reports must not be published.
  bool _loading = false;
  // True from the moment a new player is attached until it is told to play:
  // meanwhile it reports "paused", which would flash on the lock screen.
  bool _starting = false;

  // Natural track end can be reported more than once. The gate lets only the
  // first report through until the next track starts.
  bool _endGateOpen = false;

  // Videos that failed for a song in this session, so they are not retried,
  // and how many times a song was reloaded after an error while playing.
  final Map<String, Set<String>> _failedStreams = {};
  final Map<String, int> _errorReloads = {};
  int _errorHandledFor = -1;

  // Real length of what is playing. AVPlayer reports twice the real length
  // for YouTube's direct audio streams, so its own figure is not trusted
  // when a better one is known.
  Duration _trackDuration = Duration.zero;

  // A seek in flight: the player still reports the old position meanwhile.
  bool _seeking = false;
  int _seekGeneration = 0;
  // A seek asked while the track was still loading: it starts from there.
  Duration? _pendingSeek;

  (AudioProcessingState, bool, int)? _lastPublished;

  // Sleep timer state
  Timer? _sleepTimer;
  bool _sleepTimerEndOfTrack = false;
  final ValueNotifier<String?> sleepTimerNotifier = ValueNotifier<String?>(null);

  final ValueNotifier<(String?, bool)> playbackIndicator = ValueNotifier<(String?, bool)>((null, false));

  bool get isSleepTimerActive => _sleepTimer != null || _sleepTimerEndOfTrack;

  Song? get currentSong => _queue.current;

  /// Playback position, refreshed a few times a second while playing. It is
  /// kept out of [playbackState], which is published only when the state
  /// changes: publishing it at every tick rebuilt the whole player several
  /// times a second and kept restarting the progress bar.
  final ValueNotifier<Duration> positionNotifier = ValueNotifier<Duration>(Duration.zero);
  Duration get position => positionNotifier.value;
  Duration? get duration => mediaItem.value?.duration;

  // --- Player events ---

  void _onPlayerValue(VideoPlayerController controller) {
    if (!identical(controller, _player) || _loading) return;
    final value = controller.value;

    if (value.hasError) {
      unawaited(_onPlaybackError(value.errorDescription ?? 'errore sconosciuto'));
      return;
    }
    if (_starting) return;
    _publish(processing: _processingStateOf(value), playing: value.isPlaying);

    if (value.isCompleted) unawaited(_onTrackEnded());
  }

  AudioProcessingState _processingStateOf(VideoPlayerValue value) {
    if (value.hasError || !value.isInitialized) return AudioProcessingState.idle;
    if (value.isCompleted) return AudioProcessingState.completed;
    if (value.isBuffering) return AudioProcessingState.buffering;
    return AudioProcessingState.ready;
  }

  /// The player failed while a track was playing (dropped connection,
  /// expired stream URL, unreadable file). Reload once from where it was,
  /// with a fresh URL; if it fails again, move to another source.
  Future<void> _onPlaybackError(String description) async {
    if (_errorHandledFor == _loadGeneration) return;
    _errorHandledFor = _loadGeneration;

    final song = currentSong;
    final seconds = _currentSeconds();
    PlaybackLogService.instance.error(
      'PLAYER',
      'errore durante la riproduzione a ${seconds.toStringAsFixed(1)}s '
      '(${_currentStreamId ?? 'file locale'}): $description',
    );
    if (song == null) return;

    final reloads = _errorReloads[song.id] ?? 0;
    if (reloads < 1) {
      _errorReloads[song.id] = reloads + 1;
      await _loadAndPlayCurrent(
        // A local file that failed once is not tried again.
        allowLocal: false,
        startSeconds: seconds,
        freshUrl: true,
      );
      return;
    }
    await _recoverFromStreamFailure('errore di riproduzione', definitive: false);
  }

  // --- Publishing state ---

  /// Single place that updates the indicator, the position timer and the
  /// lock screen / Control Center state.
  ///
  /// [pollPosition] is false for the provisional "buffering" shown while a
  /// track loads: there is no position to read from the player yet.
  void _publish({
    required AudioProcessingState processing,
    required bool playing,
    bool pollPosition = true,
  }) {
    final indicator = (currentSong?.id, playing);
    if (playbackIndicator.value != indicator) {
      playbackIndicator.value = indicator;
    }

    if (playing && pollPosition) {
      if (_positionTimer == null) _startPositionTimer();
    } else {
      _stopPositionTimer();
    }

    // The player notifies ten times a second while playing: only a real
    // change is passed on.
    final published = (processing, playing, _queue.index);
    if (published == _lastPublished) return;
    if (_lastPublished?.$1 != processing || _lastPublished?.$2 != playing) {
      PlaybackLogService.instance
          .log('STATE', '${processing.name} playing=$playing');
    }
    _lastPublished = published;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.stop,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: processing,
        playing: playing,
        queueIndex: _queue.index >= 0 ? _queue.index : 0,
        // The lock screen counts on from here by itself.
        updatePosition: position,
        bufferedPosition: position,
        speed: _speed,
      ),
    );
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final player = _player;
      if (player == null || _loading || _seeking) return;
      try {
        final position = await player.position;
        if (position == null || !identical(player, _player) || _loading || _seeking) return;
        _setPosition(position);
        // The end is called here, a moment early, rather than left to the
        // player: it can believe the track is twice as long, and once it has
        // stopped by itself it is busy parking at the end, which gets in the
        // way of repeating the track.
        if (_trackDuration > Duration.zero && position >= _trackDuration - _endMargin) {
          unawaited(_onTrackEnded());
        }
      } catch (_) {
        // The player was disposed between the check and the call.
      }
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  /// Updates the position shown by the app. [announce] also tells the system
  /// (lock screen, Control Center), which otherwise counts on by itself:
  /// needed after a jump.
  void _setPosition(Duration position, {bool announce = false}) {
    var shown = position < Duration.zero ? Duration.zero : position;
    if (_trackDuration > Duration.zero && shown > _trackDuration) shown = _trackDuration;
    positionNotifier.value = shown;
    if (!announce) return;
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: shown,
        bufferedPosition: shown,
        speed: _speed,
      ),
    );
  }

  /// Length of what is playing. [known] comes from YouTube and is exact;
  /// without it the player's figure is used, halved when it is twice the
  /// catalog length (a file downloaded from a direct stream).
  Duration _resolveDuration(Duration reported, Duration? known, Song? song) {
    if (known != null && known > Duration.zero) return known;
    final catalog = song?.duration ?? Duration.zero;
    if (reported <= Duration.zero) return catalog;
    if (catalog > Duration.zero) {
      final doubled = catalog * 2;
      final tolerance = Duration(milliseconds: max(4000, doubled.inMilliseconds ~/ 25));
      if ((reported - doubled).abs() <= tolerance) return reported ~/ 2;
    }
    return reported;
  }

  void _updateQueueBroadcast() {
    queue.add(_queue.items.map((s) => s.toMediaItem()).toList());
  }

  /// Publishes the current song with the length of what is actually playing.
  /// The source can be longer than the catalog entry (a video with an intro),
  /// and the progress bar must follow the real thing.
  void _publishCurrentMediaItem() {
    final song = currentSong;
    if (song == null) return;
    final item = song.toMediaItem();
    final actual = _trackDuration;
    final known = item.duration ?? Duration.zero;
    final differs = (actual - known).abs() > const Duration(seconds: 1);
    mediaItem.add(actual > Duration.zero && differs ? item.copyWith(duration: actual) : item);
  }

  // --- Track end ---

  Future<void> _onTrackEnded() async {
    if (!_endGateOpen) return;
    _endGateOpen = false;
    PlaybackLogService.instance.log(
      'END',
      'fine brano "${currentSong?.title}" repeat=${_queue.repeat.name} shuffle=${_queue.shuffle}',
    );

    if (_sleepTimerEndOfTrack) {
      cancelSleepTimer();
      await pause();
      return;
    }
    if (_queue.repeat == PlaybackRepeat.one) {
      await _restartCurrent();
      return;
    }
    await _advance();
  }

  Future<void> _restartCurrent() async {
    final player = _player;
    if (player == null) return;
    // The player reached the end by itself: it is pausing and moving to the
    // last instant, and a seek sent now would be undone by that.
    if (player.value.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!identical(player, _player)) return;
    }
    final start = _startOffsetOf(currentSong);
    // Not polled meanwhile: the old position would end the track again.
    _seeking = true;
    try {
      await player.seekTo(start);
    } finally {
      _seeking = false;
    }
    if (!identical(player, _player)) return;
    _setPosition(start, announce: true);
    _endGateOpen = true;
    await player.play();
  }

  /// Where [song] starts: the user's manual offset for sources that open
  /// with an intro (a music video), zero otherwise.
  Duration _startOffsetOf(Song? song) {
    if (song == null) return Duration.zero;
    return Duration(milliseconds: StorageService.instance.getStartOffsetMs(song.id) ?? 0);
  }

  /// Moves to the next track: queue order, repeat-all wrap-around, then
  /// autoplay from the recommendations, and finally stop.
  Future<void> _advance() async {
    var target = _queue.peekNext();

    if (target == null && currentSong != null) {
      final related = (await _freshSuggestions(currentSong!)).take(20);
      final firstNew = _queue.items.length;
      if (_queue.appendUnique(related) > 0) {
        _updateQueueBroadcast();
        target = firstNew;
      }
    }

    if (target == null) {
      PlaybackLogService.instance.log('QUEUE', 'fine coda, nessun brano successivo');
      await stop();
      return;
    }
    await _playIndex(target);
  }

  Future<void> _playIndex(int target, {bool back = false}) async {
    _queue.moveTo(target, back: back);
    final song = currentSong!;
    _failedStreams.remove(song.id);
    _errorReloads.remove(song.id);
    mediaItem.add(song.toMediaItem());
    StorageService.instance.addToHistory(song);
    _warmCanvasForCurrent();
    _upgradeCoversAround();
    _pendingSuggestions.remove(song.id);
    unawaited(_topUpSuggestions());
    _userStopped = false;
    await _loadAndPlayCurrent();
  }

  // --- Loading ---

  int _loadGeneration = 0;

  /// Loads and plays the current song. [startSeconds] defaults to the song's
  /// start offset; [freshUrl] skips the remembered stream URL.
  Future<void> _loadAndPlayCurrent({
    bool allowLocal = true,
    double? startSeconds,
    bool freshUrl = false,
  }) async {
    final generation = ++_loadGeneration;
    final song = currentSong;
    if (song == null) return;
    _endGateOpen = true;
    _userPaused = false;
    _loading = true;
    _starting = false;
    _seeking = false;
    _seekGeneration++;
    _pendingSeek = null;
    _trackDuration = Duration.zero;
    final start = startSeconds ?? _startOffsetOf(song).inMilliseconds / 1000;
    positionNotifier.value = Duration(milliseconds: (start * 1000).round());
    final log = PlaybackLogService.instance;
    log.log('LOAD', '#$generation "${song.title}" - ${song.artist} id=${song.id}'
        '${start > 0 ? ' da ${start.toStringAsFixed(1)}s' : ''}');

    // Silence the previous track right away; its player is replaced once the
    // new one is ready.
    unawaited(_pauseQuietly(_player));

    // Immediately notify UI that we are buffering
    _publish(
      processing: AudioProcessingState.buffering,
      playing: true,
      pollPosition: false,
    );

    try {
      if (allowLocal && await StorageService.instance.hasLocalAudioFile(song.id)) {
        if (generation != _loadGeneration) return;
        final path = await StorageService.instance.getLocalAudioPath(song.id);
        final opened = await _open(
          () => VideoPlayerController.file(File(path), videoPlayerOptions: _audioOptions),
          generation,
          start: start,
          source: 'file locale',
        );
        if (opened == _Open.ok) _currentStreamId = null;
        // An unreadable file falls through to streaming below.
        if (opened != _Open.failed) return;
      }

      final videoId = await TrackMatcherService.instance.resolveAndCacheStreamId(song);
      if (generation != _loadGeneration) {
        log.log('LOAD', '#$generation superato da un caricamento più recente');
        return;
      }
      if (videoId == null) {
        _failLoad('Nessuna sorgente trovata per ${song.title}');
        return;
      }
      _currentStreamId = videoId;

      final outcome = await _openStream(videoId, generation, start: start, freshUrl: freshUrl);
      if (outcome.result == _Open.ok) {
        unawaited(_prefetchNext());
        return;
      }
      if (outcome.result == _Open.superseded || generation != _loadGeneration) return;

      await _recoverFromStreamFailure(
        outcome.unavailable ? 'video non disponibile' : 'stream non riproducibile',
        // YouTube itself refused the video: do not pick it again.
        definitive: outcome.unavailable,
      );
    } catch (e, stack) {
      log.error('LOAD', '#$generation "${song.title}" fallito: $e', stack);
      if (generation == _loadGeneration) {
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
    final yt = YTMusicService.instance;
    final log = PlaybackLogService.instance;
    const superseded = (result: _Open.superseded, unavailable: false);

    Future<_Open> openUrl(String url, String label, {VideoFormat? format}) => _open(
          () => VideoPlayerController.networkUrl(
            Uri.parse(url),
            formatHint: format,
            videoPlayerOptions: _audioOptions,
          ),
          generation,
          start: start,
          source: '$label $videoId',
          knownDuration: yt.streamDuration(videoId),
        );

    final hadRemembered = yt.hasCachedAudioUrl(videoId);

    // [freshUrl] makes this first lookup forget every remembered URL of the
    // video, so the ones asked below are new as well.
    final hlsAudio = await yt.getHlsAudioUrl(videoId, force: freshUrl);
    if (generation != _loadGeneration) return superseded;
    if (hlsAudio != null) {
      final opened = await openUrl(hlsAudio, 'HLS audio', format: VideoFormat.hls);
      if (opened != _Open.failed) return (result: opened, unavailable: false);
    }

    var url = await yt.getAudioStreamUrl(videoId);
    if (generation != _loadGeneration) return superseded;

    if (url == null) {
      log.error('LOAD', 'YouTube non ha restituito uno stream audio per $videoId');
    } else {
      var opened = await openUrl(url, 'stream');
      if (opened != _Open.failed) return (result: opened, unavailable: false);

      // A remembered URL can have expired: one more try with a new one.
      if (hadRemembered && !freshUrl) {
        log.log('LOAD', 'URL ricordato rifiutato, ne chiedo uno nuovo per $videoId');
        url = await yt.getAudioStreamUrl(videoId, force: true);
        if (generation != _loadGeneration) return superseded;
        if (url != null) {
          opened = await openUrl(url, 'stream (nuovo URL)');
          if (opened != _Open.failed) return (result: opened, unavailable: false);
        }
      }
    }

    final hls = await yt.getHlsUrl(videoId);
    if (generation != _loadGeneration) return superseded;
    if (hls != null) {
      final opened = await openUrl(hls, 'HLS completo', format: VideoFormat.hls);
      if (opened != _Open.failed) return (result: opened, unavailable: false);
    }
    return (
      result: _Open.failed,
      unavailable: url == null && hls == null && hlsAudio == null,
    );
  }

  /// Creates a player for one source, waits until it can play and makes it
  /// the active one.
  Future<_Open> _open(
    VideoPlayerController Function() create,
    int generation, {
    required double start,
    required String source,
    Duration? knownDuration,
  }) async {
    final log = PlaybackLogService.instance;
    final watch = Stopwatch()..start();
    final controller = create();
    try {
      await controller.initialize().timeout(_openTimeout);
      if (generation != _loadGeneration) {
        await _disposeQuietly(controller);
        return _Open.superseded;
      }

      final previous = _player;
      _player = controller;
      _loading = false;
      _starting = true;
      controller.addListener(() => _onPlayerValue(controller));
      unawaited(_disposeQuietly(previous));

      final reported = controller.value.duration;
      _trackDuration = _resolveDuration(reported, knownDuration, currentSong);
      final misreported = (reported - _trackDuration).abs() > const Duration(seconds: 2);

      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_speed);
      final startAt = _pendingSeek ?? Duration(milliseconds: (start * 1000).round());
      _pendingSeek = null;
      if (startAt > Duration.zero) await controller.seekTo(startAt);
      _setPosition(startAt, announce: true);
      _publishCurrentMediaItem();
      log.log(
        'PLAY',
        '#$generation $source pronto in ${watch.elapsedMilliseconds}ms, '
        'durata ${_trackDuration.inSeconds}s'
        '${misreported ? ' (il lettore ne dichiara ${reported.inSeconds})' : ''}',
      );

      if (_userPaused) {
        // Paused while it was loading: ready, but silent.
        _starting = false;
        _publish(processing: AudioProcessingState.ready, playing: false);
      } else {
        await _activateSession();
        await controller.play();
        _starting = false;
        // What it reported while starting was skipped: publish where it is.
        _onPlayerValue(controller);
      }
      return _Open.ok;
    } catch (e, stack) {
      log.error(
        'PLAY',
        '#$generation $source non riproducibile dopo ${watch.elapsedMilliseconds}ms: $e',
        e is TimeoutException ? null : stack,
      );
      if (identical(_player, controller)) {
        _player = null;
        _starting = false;
        _loading = generation == _loadGeneration;
      }
      await _disposeQuietly(controller);
      return generation == _loadGeneration ? _Open.failed : _Open.superseded;
    }
  }

  /// Makes this app the one that owns audio output, so other apps stop and
  /// the lock screen shows this player.
  Future<void> _activateSession() async {
    try {
      final session = await AudioSession.instance;
      if (!await session.setActive(true)) {
        PlaybackLogService.instance.log('SESSION', 'attivazione della sessione audio rifiutata');
      }
    } catch (e) {
      PlaybackLogService.instance.error('SESSION', 'attivazione sessione audio: $e');
    }
  }

  Future<void> _pauseQuietly(VideoPlayerController? controller) async {
    try {
      await controller?.pause();
    } catch (_) {
      // Already disposed: nothing to silence.
    }
  }

  Future<void> _disposeQuietly(VideoPlayerController? controller) async {
    if (controller == null) return;
    await _pauseQuietly(controller);
    try {
      await controller.dispose();
    } catch (e) {
      debugPrint('AudioPlayerHandler._disposeQuietly: $e');
    }
  }

  /// Reports a failed load and leaves the "buffering" state set when it
  /// started; otherwise the player would show a spinner forever. The next
  /// play() retries the load.
  void _failLoad(String message) {
    PlaybackLogService.instance.error('FAIL', message);
    _errorController.add(message);
    _userStopped = true;
    _loading = false;
    _publish(processing: AudioProcessingState.idle, playing: false);
  }

  /// The current video cannot be played: try the next best match, up to
  /// [_maxSourceAttempts] videos per song. A [definitive] failure replaces
  /// the remembered source, so the broken one is not picked again.
  Future<void> _recoverFromStreamFailure(String reason, {required bool definitive}) async {
    final generation = _loadGeneration;
    final song = currentSong;
    final failedId = _currentStreamId;
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
    final alternative = await TrackMatcherService.instance
        .alternativeStreamId(song, exclude: failed);
    if (generation != _loadGeneration) return;
    if (alternative == null) {
      _failLoad('Impossibile riprodurre "${song.title}" ($reason, nessuna alternativa)');
      return;
    }

    PlaybackLogService.instance.log('RECOVER', 'nuova sorgente: $alternative');
    _queue.updateSong(song.id, (s) => s.copyWith(youtubeVideoId: alternative));
    if (definitive) {
      await StorageService.instance.cacheYouTubeMapping(song.id, alternative);
    }
    await _loadAndPlayCurrent(allowLocal: false);
  }

  /// Resolves the next track's stream ahead of time, so skipping to it (or
  /// reaching it) starts without the matching and lookup delay.
  Future<void> _prefetchNext() async {
    // With shuffle the next track is drawn when needed, not known now.
    if (_queue.shuffle) return;
    final next = _queue.peekNext();
    if (next == null) return;
    final song = _queue.items[next];
    try {
      if (StorageService.instance.isDownloaded(song.id)) return;
      final videoId = await TrackMatcherService.instance.resolveAndCacheStreamId(song);
      if (videoId == null) return;
      final yt = YTMusicService.instance;
      if (await yt.getHlsAudioUrl(videoId) == null) await yt.getAudioStreamUrl(videoId);
    } catch (e) {
      debugPrint('AudioPlayerHandler._prefetchNext: $e');
    }
  }

  // --- Core API ---

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    PlaybackLogService.instance.log(
      'CMD',
      'playSong "${song.title}" id=${song.id} coda=${queue?.length ?? 1}',
    );
    _queue.replace((queue != null && queue.isNotEmpty) ? queue : [song], song);
    _failedStreams.remove(song.id);
    _errorReloads.remove(song.id);
    _syncSuggestionsWithQueue();
    _updateQueueBroadcast();
    mediaItem.add(song.toMediaItem());
    StorageService.instance.addToHistory(song);

    _warmCanvasForCurrent();
    _upgradeCoversAround();
    if (smartShuffleNotifier.value) {
      _resetSuggestionBudget();
      unawaited(_topUpSuggestions());
    }

    _userStopped = false;
    await _loadAndPlayCurrent();
  }

  Future<void> switchAudioSource(Song song, String newYoutubeVideoId, {Duration? newDuration}) async {
    PlaybackLogService.instance
        .log('CMD', 'cambio sorgente "${song.title}" -> $newYoutubeVideoId');
    _failedStreams.remove(song.id);
    _errorReloads.remove(song.id);
    await StorageService.instance.cacheYouTubeMapping(song.id, newYoutubeVideoId);
    _queue.updateSong(song.id, (s) => s.copyWith(
          youtubeVideoId: newYoutubeVideoId,
          duration: (newDuration != null && newDuration > Duration.zero) ? newDuration : s.duration,
        ));
    _updateQueueBroadcast();

    if (currentSong?.id == song.id) {
      mediaItem.add(currentSong!.toMediaItem());
      // Keep the position. A download belongs to the old source, so the new
      // stream is played instead of the local file.
      await _loadAndPlayCurrent(allowLocal: false, startSeconds: _currentSeconds());
    }
  }

  double _currentSeconds() => position.inMilliseconds / 1000;

  @override
  Future<void> play() async {
    PlaybackLogService.instance.log(
      'CMD',
      'play (daCapo=$_userStopped inCaricamento=$_loading)',
    );
    _userPaused = false;
    if (_userStopped && currentSong != null) {
      _userStopped = false;
      await _loadAndPlayCurrent();
      return;
    }
    // While a track loads there is nothing to start yet: clearing
    // _userPaused above is enough, the load plays it when ready.
    final player = _player;
    if (player == null || _loading) return;

    final atEnd = player.value.isCompleted ||
        (_trackDuration > Duration.zero && position >= _trackDuration - _endMargin);
    if (atEnd) {
      // Finished (sleep timer at the end of the track): start it again.
      final start = _startOffsetOf(currentSong);
      await player.seekTo(start);
      _setPosition(start, announce: true);
      _endGateOpen = true;
    }
    await _activateSession();
    await player.play();
  }

  @override
  Future<void> pause() async {
    PlaybackLogService.instance.log('CMD', 'pause (inCaricamento=$_loading)');
    _userPaused = true;
    if (_loading) {
      // No player events arrive during a load: show the pause ourselves.
      _publish(processing: AudioProcessingState.buffering, playing: false);
      return;
    }
    await _player?.pause();
  }

  @override
  Future<void> stop() async {
    PlaybackLogService.instance.log('CMD', 'stop');
    _userStopped = true;
    _loading = false;
    _starting = false;
    _seeking = false;
    _pendingSeek = null;
    // Cancels a load in progress.
    _loadGeneration++;
    _stopPositionTimer();
    final player = _player;
    _player = null;
    await _disposeQuietly(player);
    _publish(processing: AudioProcessingState.idle, playing: false);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final log = PlaybackLogService.instance;
    var target = position < Duration.zero ? Duration.zero : position;
    if (_trackDuration > Duration.zero && target > _trackDuration) target = _trackDuration;
    log.log('CMD', 'seek ${target.inSeconds}s (inCaricamento=$_loading)');

    final player = _player;
    if (_loading) {
      // Nothing to move yet: the track starts from there once it is ready.
      _pendingSeek = target;
      _setPosition(target, announce: true);
      return;
    }
    if (player == null) return;

    // The bar and the lock screen move at once; the player follows. Until it
    // has, what it reports is the old position and must not be shown.
    final generation = ++_seekGeneration;
    _seeking = true;
    _setPosition(target, announce: true);
    if (target < _trackDuration - _endMargin) _endGateOpen = true;

    final watch = Stopwatch()..start();
    try {
      // Bounded: a seek the player never confirms must not freeze the bar.
      await player.seekTo(target).timeout(_seekTimeout);
    } catch (e) {
      log.error('SEEK', 'spostamento a ${target.inSeconds}s non confermato: $e');
    }
    // A newer seek or another track took over meanwhile.
    if (generation != _seekGeneration || !identical(player, _player)) return;
    _seeking = false;

    Duration? reached;
    try {
      reached = await player.position;
    } catch (_) {
      // Disposed meanwhile: nothing to report.
    }
    log.log(
      'SEEK',
      'a ${target.inSeconds}s in ${watch.elapsedMilliseconds}ms, '
      'il lettore è a ${reached == null ? '?' : (reached.inMilliseconds / 1000).toStringAsFixed(1)}s',
    );
  }

  @override
  Future<void> skipToNext() async {
    PlaybackLogService.instance.log('CMD', 'skipToNext');
    _endGateOpen = false;
    await _advance();
  }

  /// Plays the queued track at [index], keeping the queue as it is. Tapping
  /// the track that is playing starts it again.
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queue.items.length) return;
    PlaybackLogService.instance.log('CMD', 'skipToQueueItem $index');
    if (index == _queue.index && !_userStopped) {
      await seek(_startOffsetOf(currentSong));
      if (!playbackState.value.playing) await play();
      return;
    }
    _endGateOpen = false;
    await _playIndex(index);
  }

  @override
  Future<void> skipToPrevious() async {
    PlaybackLogService.instance.log('CMD', 'skipToPrevious');
    final start = _startOffsetOf(currentSong);
    if (!_loading && _currentSeconds() - start.inMilliseconds / 1000 > 4.0) {
      await seek(start);
      return;
    }
    final target = _queue.peekPrevious();
    if (target != null) {
      await _playIndex(target, back: true);
    } else {
      await seek(start);
    }
  }

  // --- Original covers ---

  /// Swaps YouTube video thumbnails for the official album cover on the
  /// current track and the ones around it.
  void _upgradeCoversAround() {
    final items = _queue.items;
    final index = _queue.index;
    if (index < 0) return;

    for (var i = index - 1; i <= index + 3; i++) {
      if (i < 0 || i >= items.length) continue;
      final song = items[i];
      if (!CoverArtService.needsOriginal(song.thumbnailUrl)) continue;

      unawaited(() async {
        try {
          final cover = await CoverArtService.instance.originalCover(song);
          if (cover == null) return;
          _queue.updateSong(song.id, (s) => s.copyWith(thumbnailUrl: cover));
          _updateQueueBroadcast();

          final current = currentSong;
          if (current != null && current.id == song.id) {
            _publishCurrentMediaItem();
            await StorageService.instance.addToHistory(current);
          }
        } catch (e) {
          debugPrint('AudioPlayerHandler._upgradeCoversAround: $e');
        }
      }());
    }
  }

  // --- Recommendations & Smart Shuffle ---

  /// Smart Shuffle: shuffle plus recommended tracks mixed into the queue.
  final ValueNotifier<bool> smartShuffleNotifier = ValueNotifier<bool>(false);

  /// Ids of the queued songs that were added as recommendations.
  final ValueNotifier<Set<String>> suggestedIdsNotifier =
      ValueNotifier<Set<String>>(const {});

  // Recommendations queued but not played yet, and how many more may still
  // be added to the current queue.
  final Set<String> _pendingSuggestions = {};
  int _suggestionBudget = 0;
  bool _toppingUp = false;
  static const int _suggestionsAhead = 3;

  /// YouTube video to seed recommendations from when the catalog has no
  /// match for [song].
  String? _youtubeSeedFor(Song song) {
    if (song.id == currentSong?.id && _currentStreamId != null) return _currentStreamId;
    return TrackMatcherService.needsResolution(song.id) ? song.youtubeVideoId : song.id;
  }

  /// Recommendations for [seed] that are not already in the queue.
  Future<List<Song>> _freshSuggestions(Song seed) async {
    final recommended = await RecommendationService.instance
        .forSong(seed, youtubeSeedId: _youtubeSeedFor(seed));
    final queuedIds = {for (final s in _queue.items) s.id};
    final queuedKeys = {for (final s in _queue.items) RecommendationService.songKey(s)};
    return [
      for (final song in recommended)
        if (!queuedIds.contains(song.id) &&
            queuedKeys.add(RecommendationService.songKey(song)))
          song,
    ];
  }

  /// Recommended next tracks for the song playing now, for the queue view.
  Future<List<Song>> suggestionsForCurrent({int limit = 6}) async {
    final seed = currentSong;
    if (seed == null) return [];
    return (await _freshSuggestions(seed)).take(limit).toList();
  }

  Future<void> setSmartShuffle(bool enabled) async {
    if (smartShuffleNotifier.value == enabled) return;
    smartShuffleNotifier.value = enabled;
    PlaybackLogService.instance.log('CMD', enabled ? 'smart shuffle on' : 'smart shuffle off');

    if (enabled) {
      await setShuffleMode(AudioServiceShuffleMode.all);
      _resetSuggestionBudget();
      await _topUpSuggestions();
      return;
    }

    // Drop the recommendations that have not played yet.
    final items = _queue.items;
    for (var i = items.length - 1; i >= 0; i--) {
      if (i != _queue.index && _pendingSuggestions.contains(items[i].id)) {
        _queue.removeAt(i);
      }
    }
    _syncSuggestionsWithQueue();
    _updateQueueBroadcast();
  }

  void _resetSuggestionBudget() {
    // About one recommendation every three tracks of the user's own queue.
    final suggested = suggestedIdsNotifier.value;
    final own = _queue.items.where((s) => !suggested.contains(s.id)).length;
    _suggestionBudget = (own / 3).ceil().clamp(3, 30);
  }

  /// Forgets the recommendations that are no longer in the queue.
  void _syncSuggestionsWithQueue() {
    final queuedIds = {for (final s in _queue.items) s.id};
    _pendingSuggestions.retainAll(queuedIds);
    final kept = suggestedIdsNotifier.value.intersection(queuedIds);
    if (kept.length != suggestedIdsNotifier.value.length) {
      suggestedIdsNotifier.value = kept;
    }
  }

  /// Keeps a few recommendations queued ahead while Smart Shuffle is on.
  Future<void> _topUpSuggestions() async {
    if (!smartShuffleNotifier.value || _toppingUp) return;
    final seed = currentSong;
    if (seed == null ||
        _suggestionBudget <= 0 ||
        _pendingSuggestions.length >= _suggestionsAhead) {
      return;
    }

    _toppingUp = true;
    try {
      final picks = await _freshSuggestions(seed);
      // The track or the mode changed while loading: the next change retries.
      if (!smartShuffleNotifier.value || currentSong?.id != seed.id) return;

      var added = 0;
      for (final song in picks) {
        if (_suggestionBudget <= 0 ||
            _pendingSuggestions.length >= _suggestionsAhead) {
          break;
        }
        // Spread them after the current track: +2, +5, +8.
        _queue.insertAt(_queue.index + 2 + added * 3, song);
        _pendingSuggestions.add(song.id);
        _suggestionBudget--;
        added++;
      }
      if (added > 0) {
        suggestedIdsNotifier.value = {
          ...suggestedIdsNotifier.value,
          ..._pendingSuggestions,
        };
        _updateQueueBroadcast();
      }
    } catch (e) {
      debugPrint('AudioPlayerHandler._topUpSuggestions: $e');
    } finally {
      _toppingUp = false;
    }
  }

  // --- Sleep timer logic ---
  void setSleepTimer(Duration? duration, {bool endOfTrack = false}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndOfTrack = endOfTrack;

    if (endOfTrack) {
      sleepTimerNotifier.value = 'Fine brano';
      return;
    }

    if (duration != null) {
      final minutes = duration.inMinutes;
      sleepTimerNotifier.value = '$minutes min';
      _sleepTimer = Timer(duration, () {
        pause();
        _sleepTimer = null;
        _sleepTimerEndOfTrack = false;
        sleepTimerNotifier.value = null;
      });
    } else {
      sleepTimerNotifier.value = null;
    }
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndOfTrack = false;
    sleepTimerNotifier.value = null;
  }

  // --- Queue logic ---
  void addToQueue(Song song) {
    _queue.append(song);
    _updateQueueBroadcast();
  }

  void playNext(Song song) {
    _queue.insertAfterCurrent(song);
    _updateQueueBroadcast();
  }

  void removeFromQueue(int index) {
    final wasCurrent = _queue.removeAt(index);
    _syncSuggestionsWithQueue();
    _updateQueueBroadcast();
    if (!wasCurrent) return;

    // The playing song was removed: continue with the one that took its place.
    final next = currentSong;
    if (next == null) {
      mediaItem.add(null);
      unawaited(stop());
      return;
    }
    mediaItem.add(next.toMediaItem());
    if (playbackState.value.playing) {
      _userStopped = false;
      unawaited(_loadAndPlayCurrent());
    } else {
      // Paused: do not start playing on our own. play() loads the new song.
      _userStopped = true;
      unawaited(pause());
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    _queue.move(oldIndex, newIndex);
    _updateQueueBroadcast();
  }

  List<Song> get currentPlaylist => _queue.items;

  void _warmCanvasForCurrent() {
    final song = currentSong;
    if (song == null) return;
    final items = _queue.items;
    final index = _queue.index;

    unawaited(() async {
      final url = await CanvasService.instance.getCanvasUrl(song);
      if (url == null || url.isEmpty || currentSong?.id != song.id) return;
      await CanvasVideoPool.instance.warm(url);
    }());

    if (index > 0) {
      final prevSong = items[index - 1];
      unawaited(() async {
        final url = await CanvasService.instance.prefetch(prevSong);
        if (url == null || url.isEmpty) return;
        await CanvasVideoPool.instance.warm(url);
      }());
    }

    for (var offset = 1; offset <= 2; offset++) {
      final nextIndex = index + offset;
      if (nextIndex < 0 || nextIndex >= items.length) break;
      final nextSong = items[nextIndex];
      unawaited(() async {
        final url = await CanvasService.instance.prefetch(nextSong);
        if (url == null || url.isEmpty) return;
        await CanvasVideoPool.instance.warm(url);
      }());
    }
  }

  /// Saves where [song] starts and, when it is playing, jumps there so the
  /// user hears the new starting point right away.
  Future<void> applyStartOffset(Song song, int offsetMs) async {
    await StorageService.instance.cacheStartOffset(song.id, offsetMs);
    if (currentSong?.id == song.id) {
      await seek(Duration(milliseconds: offsetMs));
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final mode = switch (repeatMode) {
      AudioServiceRepeatMode.one => PlaybackRepeat.one,
      AudioServiceRepeatMode.all => PlaybackRepeat.all,
      _ => PlaybackRepeat.off,
    };
    _queue.setRepeat(mode);
    playbackState.add(playbackState.value.copyWith(
      repeatMode: repeatMode,
      updatePosition: position,
    ));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all ||
        shuffleMode == AudioServiceShuffleMode.group;
    _queue.setShuffle(enabled);
    if (!enabled && smartShuffleNotifier.value) await setSmartShuffle(false);
    playbackState.add(playbackState.value.copyWith(
      shuffleMode: enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      updatePosition: position,
    ));
  }

  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _player?.setVolume(volume);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _player?.setPlaybackSpeed(speed);
  }
}
