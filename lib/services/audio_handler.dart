import 'dart:async';
import 'dart:io';

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
/// three sources, tried in this order:
/// 1. the downloaded file, for songs saved offline;
/// 2. the direct AAC stream of the matched YouTube video;
/// 3. the HLS stream of the same video.
/// When a video cannot be played at all, the next best match is tried.
///
/// Playing natively is what makes background playback and the lock screen
/// work. The embedded YouTube player used before is rejected by YouTube for
/// every video (error 152), so it is no longer an option.
///
/// Queue rules (order, shuffle, repeat) live in [PlaybackQueue].
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  final PlaybackQueue _queue = PlaybackQueue();

  final bool _isAutoplayEnabled = true;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  // Background playback must be allowed explicitly: by default the plugin
  // pauses its players when the app leaves the foreground.
  static final VideoPlayerOptions _audioOptions =
      VideoPlayerOptions(allowBackgroundPlayback: true);

  static const Duration _openTimeout = Duration(seconds: 20);
  static const int _maxSourceAttempts = 3;

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

  // Natural track end can be reported more than once. The gate lets only the
  // first report through until the next track starts.
  bool _endGateOpen = false;

  // Videos that failed for a song in this session, so they are not retried,
  // and how many times a song was reloaded after an error while playing.
  final Map<String, Set<String>> _failedStreams = {};
  final Map<String, int> _errorReloads = {};
  int _errorHandledFor = -1;

  (AudioProcessingState, bool)? _lastPublished;

  // Sleep timer state
  Timer? _sleepTimer;
  bool _sleepTimerEndOfTrack = false;
  final ValueNotifier<String?> sleepTimerNotifier = ValueNotifier<String?>(null);

  final ValueNotifier<(String?, bool)> playbackIndicator = ValueNotifier<(String?, bool)>((null, false));

  bool get isSleepTimerActive => _sleepTimer != null || _sleepTimerEndOfTrack;

  Song? get currentSong => _queue.current;

  Stream<Duration> get positionStream => Stream.periodic(const Duration(milliseconds: 200), (_) => position);
  Stream<Duration?> get durationStream => mediaItem.map((item) => item?.duration);
  Duration get position => playbackState.value.updatePosition;
  Duration? get duration => mediaItem.value?.duration;

  // --- Player events ---

  void _onPlayerValue(VideoPlayerController controller) {
    if (!identical(controller, _player) || _loading) return;
    final value = controller.value;

    if (value.hasError) {
      unawaited(_onPlaybackError(value.errorDescription ?? 'errore sconosciuto'));
      return;
    }
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

    final published = (processing, playing);
    if (published != _lastPublished) {
      _lastPublished = published;
      PlaybackLogService.instance
          .log('STATE', '${processing.name} playing=$playing');
    }

    if (playing && pollPosition) {
      if (_positionTimer == null) _startPositionTimer();
    } else {
      _stopPositionTimer();
    }

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
      ),
    );
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final player = _player;
      if (player == null || _loading) return;
      try {
        // Asked to the player each time: the value it caches is refreshed
        // only twice a second, too coarse for synced lyrics.
        final position = await player.position;
        if (position != null && identical(player, _player) && !_loading) {
          _setPosition(position, player.value.playbackSpeed);
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

  void _setPosition(Duration position, double speed) {
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
        bufferedPosition: position,
        speed: speed,
      ),
    );
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
    final actual = _loading ? Duration.zero : (_player?.value.duration ?? Duration.zero);
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
    _endGateOpen = true;
    await _player?.seekTo(_startOffsetOf(currentSong));
    await _player?.play();
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

    if (target == null && _isAutoplayEnabled && currentSong != null) {
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
    final start = startSeconds ?? _startOffsetOf(song).inMilliseconds / 1000;
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

  /// Streams [videoId]: its direct AAC stream first, then its HLS stream.
  /// [unavailable] is true when YouTube returned no stream at all for it.
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
        );

    final hadRemembered = yt.hasCachedAudioUrl(videoId);
    var url = await yt.getAudioStreamUrl(videoId, force: freshUrl);
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
      final opened = await openUrl(hls, 'HLS', format: VideoFormat.hls);
      if (opened != _Open.failed) return (result: opened, unavailable: false);
    }
    return (result: _Open.failed, unavailable: url == null && hls == null);
  }

  /// Creates a player for one source, waits until it can play and makes it
  /// the active one.
  Future<_Open> _open(
    VideoPlayerController Function() create,
    int generation, {
    required double start,
    required String source,
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
      controller.addListener(() => _onPlayerValue(controller));
      unawaited(_disposeQuietly(previous));

      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_speed);
      if (start > 0) {
        await controller.seekTo(Duration(milliseconds: (start * 1000).round()));
      }
      _publishCurrentMediaItem();
      log.log(
        'PLAY',
        '#$generation $source pronto in ${watch.elapsedMilliseconds}ms, '
        'durata ${controller.value.duration.inSeconds}s',
      );

      if (_userPaused) {
        // Paused while it was loading: ready, but silent.
        _publish(processing: AudioProcessingState.ready, playing: false);
      } else {
        await _activateSession();
        await controller.play();
      }
      _setPosition(controller.value.position, _speed);
      return _Open.ok;
    } catch (e, stack) {
      log.error(
        'PLAY',
        '#$generation $source non riproducibile dopo ${watch.elapsedMilliseconds}ms: $e',
        e is TimeoutException ? null : stack,
      );
      if (identical(_player, controller)) {
        _player = null;
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
      if (videoId != null) await YTMusicService.instance.getAudioStreamUrl(videoId);
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

  double _currentSeconds() => (_player?.value.position.inMilliseconds ?? 0) / 1000;

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

    final value = player.value;
    if (value.isCompleted || (value.duration > Duration.zero && value.position >= value.duration)) {
      await player.seekTo(_startOffsetOf(currentSong));
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
    PlaybackLogService.instance.log('CMD', 'seek ${position.inSeconds}s');
    if (_loading) return;
    await _player?.seekTo(position);
    // The position is polled only while playing: publish it now so a seek
    // made while paused moves the progress bar too.
    _setPosition(position, _speed);
  }

  @override
  Future<void> skipToNext() async {
    PlaybackLogService.instance.log('CMD', 'skipToNext');
    _endGateOpen = false;
    await _advance();
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
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all ||
        shuffleMode == AudioServiceShuffleMode.group;
    _queue.setShuffle(enabled);
    if (!enabled && smartShuffleNotifier.value) await setSmartShuffle(false);
    playbackState.add(playbackState.value.copyWith(
      shuffleMode: enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
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
