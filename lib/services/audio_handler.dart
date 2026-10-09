import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/song.dart';
import 'canvas_service.dart';
import 'canvas_video_pool.dart';
import 'cover_art_service.dart';
import 'playback_log_service.dart';
import 'playback_queue.dart';
import 'recommendation_service.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';

/// Bridge between the UI, audio_service and two engines:
/// - the YouTube iframe, for streamed tracks;
/// - a local [VideoPlayerController] (AVPlayer), for tracks downloaded to
///   disk, which play offline and never touch the iframe.
///
/// Queue rules (order, shuffle, repeat) live in [PlaybackQueue].
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  final YoutubePlayerController _ytController;
  final PlaybackQueue _queue = PlaybackQueue();

  final bool _isAutoplayEnabled = true;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  Timer? _positionTimer;
  String? _currentStreamId;
  bool _userStopped = true;

  // Local engine state. [_usingLocal] is true while [_local] is the active
  // engine; the iframe listener then ignores its events.
  VideoPlayerController? _local;
  bool _usingLocal = false;
  double _volume = 1.0;
  double _speed = 1.0;

  // Natural track end can be reported more than once by the engines. The gate
  // lets only the first report through until the next track starts.
  bool _endGateOpen = false;

  // Sleep timer state
  Timer? _sleepTimer;
  bool _sleepTimerEndOfTrack = false;
  final ValueNotifier<String?> sleepTimerNotifier = ValueNotifier<String?>(null);

  final ValueNotifier<(String?, bool)> playbackIndicator = ValueNotifier<(String?, bool)>((null, false));

  bool get isSleepTimerActive => _sleepTimer != null || _sleepTimerEndOfTrack;

  Song? get currentSong => _queue.current;

  YoutubePlayerController get ytController => _ytController;

  Stream<Duration> get positionStream => Stream.periodic(const Duration(milliseconds: 200), (_) => position);
  Stream<Duration?> get durationStream => mediaItem.map((item) => item?.duration);
  Duration get position => playbackState.value.updatePosition;
  Duration? get duration => mediaItem.value?.duration;

  AudioPlayerHandler()
      : _ytController = YoutubePlayerController(
          params: const YoutubePlayerParams(
            showControls: false,
            showFullscreenButton: false,
            loop: false,
            playsInline: true,
            privacyEnhancedMode: false,
            origin: 'https://www.youtube.com',
            pointerEvents: PointerEvents.none,
          ),
        ) {
    _initListeners();
  }

  void _initListeners() {
    _ytController.listen((event) {
      if (_usingLocal) return;
      _broadcastStreamState(event);

      // The error stays on the player value until the next load, and every
      // later event carries it again: report it once per load.
      if (event.hasError && _errorReportedFor != _loadGeneration) {
        _errorReportedFor = _loadGeneration;
        PlaybackLogService.instance.log('ERR', 'iframe: ${event.error}');
        _errorController.add('Errore player iframe: ${event.error}');
      }

      if (event.playerState == PlayerState.ended) {
        unawaited(_onTrackEnded());
      }
    });
  }

  // --- Publishing state ---

  void _broadcastStreamState(YoutubePlayerValue event) {
    final state = event.playerState;

    AudioProcessingState mappedState;
    switch (state) {
      case PlayerState.unStarted:
      case PlayerState.unknown:
        mappedState = AudioProcessingState.idle;
        break;
      case PlayerState.buffering:
        mappedState = AudioProcessingState.buffering;
        break;
      case PlayerState.playing:
      case PlayerState.paused:
        mappedState = AudioProcessingState.ready;
        break;
      case PlayerState.ended:
        mappedState = AudioProcessingState.completed;
        break;
      case PlayerState.cued:
        mappedState = AudioProcessingState.ready;
        break;
    }

    _publish(processing: mappedState, playing: state == PlayerState.playing);
  }

  void _onLocalValue(VideoPlayerController controller) {
    if (!identical(controller, _local)) return;
    final value = controller.value;

    if (value.hasError) {
      _errorController.add('Errore riproduzione offline: ${value.errorDescription}');
    }
    _publish(processing: _localProcessingState(value), playing: value.isPlaying);

    if (value.isCompleted) unawaited(_onTrackEnded());
  }

  AudioProcessingState _localProcessingState(VideoPlayerValue value) {
    if (value.hasError || !value.isInitialized) return AudioProcessingState.idle;
    if (value.isCompleted) return AudioProcessingState.completed;
    if (value.isBuffering) return AudioProcessingState.buffering;
    return AudioProcessingState.ready;
  }

  /// Single place that updates the indicator, the position timer and the
  /// lock screen / Control Center state, whichever engine is active.
  void _publish({required AudioProcessingState processing, required bool playing}) {
    final indicator = (currentSong?.id, playing);
    if (playbackIndicator.value != indicator) {
      playbackIndicator.value = indicator;
    }

    if (playing) {
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
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _pollPosition());
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _pollPosition() async {
    if (_usingLocal) {
      final value = _local?.value;
      if (value == null) return;
      _setPosition(value.position, value.playbackSpeed);
      return;
    }

    final state = await _ytController.playerState;
    if (state != PlayerState.playing) return;
    final seconds = await _ytController.currentTime;
    final speed = await _ytController.playbackRate;
    _setPosition(Duration(milliseconds: (seconds * 1000).toInt()), speed);
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

  // --- Track end ---

  Future<void> _onTrackEnded() async {
    if (!_endGateOpen) return;
    _endGateOpen = false;

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
    final start = _startOffsetOf(currentSong);
    if (_usingLocal) {
      await _local?.seekTo(start);
      await _local?.play();
    } else {
      await _ytController.seekTo(seconds: start.inMilliseconds / 1000, allowSeekAhead: true);
      await _ytController.playVideo();
    }
  }

  /// Where [song] starts: the user's manual offset for sources that open
  /// with an intro (a music video), zero otherwise.
  Duration _startOffsetOf(Song? song) {
    if (song == null) return Duration.zero;
    return Duration(milliseconds: StorageService.instance.getStartOffsetMs(song.id) ?? 0);
  }

  /// Moves to the next track: queue order, repeat-all wrap-around, then
  /// autoplay from YouTube Music, and finally stop.
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
      await stop();
      return;
    }
    await _playIndex(target);
  }

  Future<void> _playIndex(int target, {bool back = false}) async {
    _queue.moveTo(target, back: back);
    final song = currentSong!;
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
  int _errorReportedFor = -1;

  /// Loads and plays the current song. [startSeconds] defaults to the song's
  /// start offset.
  Future<void> _loadAndPlayCurrent({bool allowLocal = true, double? startSeconds}) async {
    final generation = ++_loadGeneration;
    final song = currentSong;
    if (song == null) return;
    _endGateOpen = true;
    final start = startSeconds ?? _startOffsetOf(song).inMilliseconds / 1000;

    // Immediately notify UI that we are buffering
    _publish(processing: AudioProcessingState.buffering, playing: true);

    try {
      if (allowLocal && await StorageService.instance.hasLocalAudioFile(song.id)) {
        if (generation != _loadGeneration) return;
        final path = await StorageService.instance.getLocalAudioPath(song.id);
        // A stale or failed local load falls through to streaming below.
        if (await _playLocal(path, generation, startSeconds: start)) return;
      }

      final targetStreamId = await TrackMatcherService.instance.resolveAndCacheStreamId(song);
      if (generation != _loadGeneration) return;
      if (targetStreamId == null) {
        _failLoad('Nessuna sorgente trovata per ${song.title}');
        return;
      }

      await _stopLocal();
      _usingLocal = false;
      _currentStreamId = targetStreamId;
      if (start > 0) {
        await _ytController.loadVideoById(videoId: targetStreamId, startSeconds: start);
      } else {
        await _ytController.loadVideoById(videoId: targetStreamId);
      }
      await Future.delayed(const Duration(milliseconds: 300));
      if (generation != _loadGeneration) return;
      await _ytController.playVideo();
    } catch (e) {
      PlaybackLogService.instance.log('ERR', 'load "${song.title}": $e');
      if (generation == _loadGeneration) {
        _failLoad('Errore di riproduzione per ${song.title}');
      }
    }
  }

  /// Reports a failed load and leaves the "buffering" state set when it
  /// started; otherwise the player would show a spinner forever. The next
  /// play() retries the load.
  void _failLoad(String message) {
    _errorController.add(message);
    _userStopped = true;
    _publish(processing: AudioProcessingState.idle, playing: false);
  }

  /// Plays a downloaded file. Returns true when the load was handled (played,
  /// or superseded by a newer load), false when the file must be streamed.
  Future<bool> _playLocal(String path, int generation, {double startSeconds = 0}) async {
    final controller = VideoPlayerController.file(File(path));
    try {
      try {
        await _ytController.pauseVideo();
      } catch (_) {}

      await controller.initialize();
      if (generation != _loadGeneration) {
        await controller.dispose();
        return true;
      }

      await _stopLocal();
      _usingLocal = true;
      _local = controller;
      _currentStreamId = null;
      controller.addListener(() => _onLocalValue(controller));

      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_speed);
      if (startSeconds > 0) {
        await controller.seekTo(Duration(milliseconds: (startSeconds * 1000).round()));
      }
      await controller.play();
      _setPosition(controller.value.position, _speed);
      PlaybackLogService.instance.log('PLAY', 'locale: $path');
      return true;
    } catch (e) {
      debugPrint('AudioPlayerHandler._playLocal: $e');
      PlaybackLogService.instance.log('PLAY', 'file locale non leggibile, stream: $e');
      if (identical(_local, controller)) {
        _local = null;
        _usingLocal = false;
      }
      try {
        await controller.dispose();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _stopLocal() async {
    final controller = _local;
    _local = null;
    if (controller == null) return;
    try {
      await controller.pause();
      await controller.dispose();
    } catch (e) {
      debugPrint('AudioPlayerHandler._stopLocal: $e');
    }
  }

  // --- Core API ---

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    PlaybackLogService.instance.log('CMD', 'playSong "${song.title}"');
    _queue.replace((queue != null && queue.isNotEmpty) ? queue : [song], song);
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
    await StorageService.instance.cacheYouTubeMapping(song.id, newYoutubeVideoId);
    _queue.updateSong(song.id, (s) => s.copyWith(
          youtubeVideoId: newYoutubeVideoId,
          duration: (newDuration != null && newDuration > Duration.zero) ? newDuration : s.duration,
        ));
    _currentStreamId = newYoutubeVideoId;
    _updateQueueBroadcast();

    if (currentSong?.id == song.id) {
      mediaItem.add(currentSong!.toMediaItem());
      // Keep the position. A download belongs to the old source, so the new
      // stream is played instead of the local file.
      final position = await _currentSeconds();
      await _loadAndPlayCurrent(allowLocal: false, startSeconds: position);
    }
  }

  Future<double> _currentSeconds() async {
    if (_usingLocal) return (_local?.value.position.inMilliseconds ?? 0) / 1000;
    return _ytController.currentTime;
  }

  @override
  Future<void> play() async {
    if (_userStopped && currentSong != null) {
      _userStopped = false;
      await _loadAndPlayCurrent();
      return;
    }
    if (_usingLocal) {
      final controller = _local;
      if (controller == null) return;
      final value = controller.value;
      if (value.isCompleted || (value.duration > Duration.zero && value.position >= value.duration)) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
      return;
    }
    await _ytController.playVideo();
  }

  @override
  Future<void> pause() async {
    if (_usingLocal) {
      await _local?.pause();
      return;
    }
    await _ytController.pauseVideo();
  }

  @override
  Future<void> stop() async {
    _userStopped = true;
    _stopPositionTimer();
    if (_usingLocal) {
      _usingLocal = false;
      await _stopLocal();
    } else {
      await _ytController.stopVideo();
    }
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_usingLocal) {
      await _local?.seekTo(position);
      _setPosition(position, _speed);
      return;
    }
    await _ytController.seekTo(seconds: position.inMilliseconds / 1000, allowSeekAhead: true);
    // The position is polled only while playing: publish it now so a seek
    // made while paused moves the progress bar too.
    _setPosition(position, _speed);
  }

  @override
  Future<void> skipToNext() async {
    _endGateOpen = false;
    await _advance();
  }

  @override
  Future<void> skipToPrevious() async {
    final start = _startOffsetOf(currentSong);
    final seconds = await _currentSeconds();
    if (seconds - start.inMilliseconds / 1000 > 4.0) {
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
            mediaItem.add(current.toMediaItem());
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
    if (_usingLocal) {
      await _local?.setVolume(volume);
      return;
    }
    await _ytController.setVolume((volume * 100).toInt());
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    if (_usingLocal) {
      await _local?.setPlaybackSpeed(speed);
      return;
    }
    await _ytController.setPlaybackRate(speed);
  }
}
