import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'app_settings.dart';
import 'connect/connect_protocol.dart';
import 'download_service.dart';
import 'playback_log_service.dart';
import 'playback/crossfade.dart';
import 'playback/loudness.dart';
import 'playback/app_playback_sources.dart';
import 'playback/player_backend.dart';
import 'playback/preloader.dart';
import 'playback/segment_skipper.dart';
import 'playback/sleep_timer.dart';
import 'playback/stream_opener.dart';
import 'playback/suggestions.dart';
import 'playback_queue.dart';
import 'recommendation_service.dart';
import 'sponsor_block_service.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';
import 'ytmusic_service.dart';

part 'audio_handler_hosts.dart';

/// Bridge between the UI, audio_service and the native player.
///
/// Audio is played by AVPlayer (through a [PlayerBackend]) from one of
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
///
/// The playback can be handed to another device running Totorify (see
/// `connect/`). While it is, nothing plays here: every command goes to that
/// device, which reports what it is doing, and this handler shows it, so
/// the whole interface works as its remote.
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  final PlaybackQueue _queue = PlaybackQueue();

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  /// Short notes of what the player did by itself (a part of the video
  /// skipped, a song that could not be played and was passed over).
  final _infoController = StreamController<String>.broadcast();
  Stream<String> get infoStream => _infoController.stream;

  AudioPlayerHandler({PlayerBackendFactory? createPlayer})
      : _createPlayer = createPlayer ?? VideoPlayerBackend.new {
    AppSettings.instance.normalizeVolume.addListener(_loudness.onSettingChanged);
  }

  // SponsorBlock: jumps over the parts of the video that are not music.
  late final SegmentSkipper _skipper = SegmentSkipper(
    fetchSegments: SponsorBlockService.instance.segmentsFor,
    currentGeneration: () => _loadGeneration,
    canSkip: () => !_seeking && !_loading && _remote == null,
    trackDuration: () => _trackDuration,
    seek: seek,
    endTrack: () => unawaited(_onTrackEnded()),
    reportInfo: _infoController.add,
  );

  // How much the current track is lowered to sound as loud as the others.
  late final LoudnessNormalizer _loudness = LoudnessNormalizer(
    isEnabled: () => AppSettings.instance.normalizeVolume.value,
    knownLoudness: (videoId) {
      final known = YTMusicService.instance.streamDetails(videoId);
      return known == null ? null : (loudnessDb: known.loudnessDb);
    },
    fetchLoudness: YTMusicService.instance.loudnessOf,
    currentGeneration: () => _loadGeneration,
    currentVideoId: () =>
        _currentStreamId ?? (currentSong == null ? null : _videoIdOf(currentSong!)),
    onGainChanged: () {
      final player = _player;
      if (player != null) unawaited(player.setVolume(_playerVolume).catchError((_) {}));
    },
  );
  double get _gain => _loudness.gain;

  /// Where what plays comes from ("HLS audio", "file locale"…), for the
  /// details of the track.
  final ValueNotifier<String?> sourceNotifier = ValueNotifier<String?>(null);

  /// YouTube video being streamed, or null while a local file plays.
  String? get currentStreamId => _currentStreamId;

  /// How much the current track is lowered by the normalization (1 = not).
  double get normalizationGain => _gain;

  late final CrossfadeController _crossfade = CrossfadeController(_CrossfadeHost(this));

  // Makes the player of a source: the native one, or a fake in the tests.
  final PlayerBackendFactory _createPlayer;

  // Loads the current song into a player; it owns the player and the state
  // of the load, read and written here through the accessors below.
  late final StreamOpener _opener = StreamOpener(
    host: _StreamOpenerHost(this),
    sources: const AppPlaybackSources(),
    createPlayer: _createPlayer,
  );
  static const Duration _seekTimeout = Duration(seconds: 8);
  // How close to the end a track counts as finished.
  static const Duration _endMargin = Duration(milliseconds: 250);

  PlayerBackend? get _player => _opener.player;
  set _player(PlayerBackend? player) => _opener.player = player;
  // Lowered for a moment while another app speaks.
  double _volume = 1.0;
  // How loud this app plays, as set by the devices that control it.
  double _outputVolume = 1.0;
  double _speed = 1.0;

  Timer? _positionTimer;

  /// YouTube video being streamed, or null while a local file plays.
  String? get _currentStreamId => _opener.currentStreamId;

  // The device that is playing instead of this one, when there is one.
  RemoteOutput? _remote;
  // True while a change that came from that device is applied here: it
  // must not be sent back to it.
  bool _followingRemote = false;
  // Where the other device said it was, and when: the position shown moves
  // on from there between its reports.
  ({Duration position, DateTime at, bool playing})? _remoteAnchor;
  Timer? _remoteTicker;
  // Where play() starts from after the playback came back paused.
  Duration? _resumeAt;

  /// Name of the device that is playing instead of this one, or null.
  final ValueNotifier<String?> remoteNameNotifier = ValueNotifier<String?>(null);

  /// How loud the app that is playing plays, from 0 to 1: the one on the
  /// other device while it plays instead of this one.
  final ValueNotifier<double> outputVolumeNotifier = ValueNotifier<double>(1.0);
  // When the volume of the other device was last set from here: its
  // reports are not allowed to move the slider back while it is dragged.
  DateTime? _volumeSetAt;

  bool get isRemote => _remote != null;

  // True until the user (or the queue) asks for playback again after a stop
  // or a failed load: play() then loads the current song from scratch.
  bool _userStopped = true;
  // Set by pause(), cleared by play() and by a new load. A track that
  // finishes loading while this is set stays paused.
  bool _userPaused = false;
  // True from a load until its player is attached: the previous player is
  // still around and what it reports must not be published.
  bool get _loading => _opener.loading;
  set _loading(bool value) => _opener.loading = value;
  // True from the moment a new player is attached until it is told to play:
  // meanwhile it reports "paused", which would flash on the lock screen.
  bool get _starting => _opener.starting;
  set _starting(bool value) => _opener.starting = value;

  // Natural track end can be reported more than once. The gate lets only the
  // first report through until the next track starts.
  bool _endGateOpen = false;

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

  late final SleepTimerController _sleep = SleepTimerController(onElapsed: pause);
  bool get _sleepTimerEndOfTrack => _sleep.endOfTrack;
  ValueNotifier<String?> get sleepTimerNotifier => _sleep.notifier;

  final ValueNotifier<(String?, bool)> playbackIndicator = ValueNotifier<(String?, bool)>((null, false));

  bool get isSleepTimerActive => _sleep.isActive;

  Song? get currentSong => _queue.current;

  /// Playback position, refreshed a few times a second while playing. It is
  /// kept out of [playbackState], which is published only when the state
  /// changes: publishing it at every tick rebuilt the whole player several
  /// times a second and kept restarting the progress bar.
  final ValueNotifier<Duration> positionNotifier = ValueNotifier<Duration>(Duration.zero);
  Duration get position => positionNotifier.value;
  Duration? get duration => mediaItem.value?.duration;

  // --- Player events ---

  void _onPlayerValue(PlayerBackend controller) {
    if (!identical(controller, _player) || _loading) return;
    final value = controller.value;

    if (value.hasError) {
      unawaited(_opener.onPlaybackError(value.errorDescription ?? 'errore sconosciuto'));
      return;
    }
    if (_starting) return;
    _publish(processing: _processingStateOf(value), playing: value.isPlaying);

    if (value.isCompleted) unawaited(_onTrackEnded());
  }

  AudioProcessingState _processingStateOf(PlayerValue value) {
    if (value.hasError || !value.isInitialized) return AudioProcessingState.idle;
    if (value.isCompleted) return AudioProcessingState.completed;
    if (value.isBuffering) return AudioProcessingState.buffering;
    return AudioProcessingState.ready;
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
        _skipper.skipAt(position);
        _crossfade.maybeStart(position);
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

  /// Tells the interface the queue has changed and, with [sync], the device
  /// that is playing instead of this one.
  void _updateQueueBroadcast({bool sync = true}) {
    queue.add(_queue.items.map((s) => s.toMediaItem()).toList());
    if (sync && !_followingRemote) {
      _remote?.send(ConnectProtocol.queue, {
        'songs': ConnectProtocol.encodeSongs(_queue.items.map(_withSource)),
        'currentId': currentSong?.id,
      });
    }
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
      final related = (await _suggestions.fresh(currentSong!)).take(20);
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
    _opener.forgetFailures(song.id);
    mediaItem.add(song.toMediaItem());
    StorageService.instance.addToHistory(song);
    _preloader.warmCanvasForCurrent();
    _preloader.upgradeCoversAround();
    _suggestions.markPlayed(song.id);
    unawaited(_suggestions.topUp());
    _userStopped = false;
    await _loadAndPlayCurrent();
  }

  // --- Loading ---

  int get _loadGeneration => _opener.generation;
  set _loadGeneration(int value) => _opener.generation = value;

  /// Loads and plays the current song. [startSeconds] defaults to the song's
  /// start offset; [freshUrl] skips the remembered stream URL.
  Future<void> _loadAndPlayCurrent({
    bool allowLocal = true,
    double? startSeconds,
    bool freshUrl = false,
  }) async {
    final song = currentSong;
    if (song == null) return;
    _resumeAt = null;
    if (_remote != null) {
      // Another device is playing: it loads the track, this one follows.
      final from = startSeconds ?? _startOffsetOf(song).inMilliseconds / 1000;
      _sendLoad(Duration(milliseconds: (from * 1000).round()));
      return;
    }
    await _opener.load(allowLocal: allowLocal, startSeconds: startSeconds, freshUrl: freshUrl);
  }

  /// Makes this app the one that owns audio output, so other apps stop and
  /// the lock screen shows this player.
  Future<void> _activateSession() async {
    // A computer has no audio session to take: every app plays at once.
    if (Platform.isWindows || Platform.isLinux) return;
    try {
      final session = await AudioSession.instance;
      if (!await session.setActive(true)) {
        PlaybackLogService.instance.log('SESSION', 'attivazione della sessione audio rifiutata');
      }
    } catch (e) {
      PlaybackLogService.instance.error('SESSION', 'attivazione sessione audio: $e');
    }
  }

  Future<void> _disposeQuietly(PlayerBackend? controller) => _opener.disposeQuietly(controller);

  // ── SponsorBlock and normalization ──────────────────────────────────────

  /// The YouTube video [song] is played from, when known: the one matched
  /// for it, or its own id for a song of the YouTube catalog.
  String? _videoIdOf(Song song) => TrackMatcherService.instance.knownStreamIdOf(song);

  /// Looks up, beside the load, the parts of [videoId] to skip and how loud
  /// it is.
  void _prepareExtras(String? videoId, int generation) {
    if (videoId == null || videoId.isEmpty) {
      _loudness.setGain(1.0);
      return;
    }
    unawaited(_skipper.load(videoId, generation));
    unawaited(_loudness.apply(videoId, generation));
  }

  /// See [LoudnessNormalizer.gainFor].
  static double gainFor(double? loudnessDb) => LoudnessNormalizer.gainFor(loudnessDb);

  // Prepares what is around the current track: the next stream, the Canvas
  // videos, the lyrics and the original covers.
  late final PlaybackPreloader _preloader = PlaybackPreloader(
    queue: _queue,
    currentGeneration: () => _loadGeneration,
    onQueueChanged: _updateQueueBroadcast,
    onCurrentCoverChanged: _publishCurrentMediaItem,
  );

  // --- Core API ---

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    PlaybackLogService.instance.log(
      'CMD',
      'playSong "${song.title}" id=${song.id} coda=${queue?.length ?? 1}',
    );
    // Something new starts shuffled, when the user always wants it so.
    if (AppSettings.instance.permanentShuffle.value && !_queue.shuffle) {
      await setShuffleMode(AudioServiceShuffleMode.all);
    }
    _queue.replace((queue != null && queue.isNotEmpty) ? queue : [song], song);
    _opener.forgetFailures(song.id);
    _suggestions.syncWithQueue();
    // Another device, if it is the one playing, gets the queue with the
    // order to play it.
    _updateQueueBroadcast(sync: false);
    mediaItem.add(song.toMediaItem());
    StorageService.instance.addToHistory(song);

    _preloader.warmCanvasForCurrent();
    _preloader.upgradeCoversAround();
    if (smartShuffleNotifier.value) {
      _suggestions.resetBudget();
      unawaited(_suggestions.topUp());
    }

    _userStopped = false;
    await _loadAndPlayCurrent();
  }

  Future<void> switchAudioSource(Song song, String newYoutubeVideoId, {Duration? newDuration}) async {
    PlaybackLogService.instance
        .log('CMD', 'cambio sorgente "${song.title}" -> $newYoutubeVideoId');
    _opener.forgetFailures(song.id);
    await StorageService.instance.cacheYouTubeMapping(song.id, newYoutubeVideoId);
    await TrackMatcherService.instance.rememberChosenSource(song, newYoutubeVideoId);
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
    if (_remote != null) {
      _remote!.send(ConnectProtocol.play);
      _expectFromRemote(playing: true);
      return;
    }
    if (_userStopped && currentSong != null) {
      _userStopped = false;
      // After the playback came back from another device, from where it was.
      final from = _resumeAt;
      await _loadAndPlayCurrent(
        startSeconds: from == null ? null : from.inMilliseconds / 1000,
      );
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
    if (_remote != null) {
      _remote!.send(ConnectProtocol.pause);
      _expectFromRemote(playing: false);
      return;
    }
    _crossfade.finish();
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
    if (_remote != null) {
      _remote!.send(ConnectProtocol.pause);
      _expectFromRemote(playing: false);
      return;
    }
    _crossfade.finish();
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

    _skipper.markEntered(target);
    if (_remote != null) {
      _remote!.send(ConnectProtocol.seek, {'positionMs': target.inMilliseconds});
      _expectFromRemote(position: target);
      return;
    }
    if (_userStopped && _resumeAt != null) {
      // Not loaded yet (the playback came back paused): it starts from here.
      _resumeAt = target;
      _setPosition(target, announce: true);
      return;
    }

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
    if (_remote != null) return _remote!.send(ConnectProtocol.next);
    _endGateOpen = false;
    await _advance();
  }

  /// Plays the queued track at [index], keeping the queue as it is. Tapping
  /// the track that is playing starts it again.
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queue.items.length) return;
    PlaybackLogService.instance.log('CMD', 'skipToQueueItem $index');
    if (_remote != null) return _remote!.send(ConnectProtocol.jump, {'index': index});
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
    if (_remote != null) return _remote!.send(ConnectProtocol.previous);
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

  // --- Recommendations & Smart Shuffle ---

  late final SuggestionManager _suggestions = SuggestionManager(
    queue: _queue,
    recommend: RecommendationService.instance.forSong,
    youtubeSeedFor: _youtubeSeedFor,
    enableShuffle: () => setShuffleMode(AudioServiceShuffleMode.all),
    onQueueChanged: _updateQueueBroadcast,
  );

  /// Smart Shuffle: shuffle plus recommended tracks mixed into the queue.
  ValueNotifier<bool> get smartShuffleNotifier => _suggestions.smartShuffleNotifier;

  /// Ids of the queued songs that were added as recommendations.
  ValueNotifier<Set<String>> get suggestedIdsNotifier => _suggestions.suggestedIdsNotifier;

  /// YouTube video to seed recommendations from when the catalog has no
  /// match for [song].
  String? _youtubeSeedFor(Song song) {
    if (song.id == currentSong?.id && _currentStreamId != null) return _currentStreamId;
    return TrackMatcherService.needsResolution(song.id) ? song.youtubeVideoId : song.id;
  }

  /// Recommended next tracks for the song playing now, for the queue view.
  Future<List<Song>> suggestionsForCurrent({int limit = 6}) =>
      _suggestions.forCurrent(limit: limit);

  Future<void> setSmartShuffle(bool enabled) => _suggestions.setSmartShuffle(enabled);

  // --- Sleep timer logic ---
  void setSleepTimer(Duration? duration, {bool endOfTrack = false}) =>
      _sleep.set(duration, endOfTrack: endOfTrack);

  void cancelSleepTimer() => _sleep.cancel();

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
    _suggestions.syncWithQueue();
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

  /// Keeps only the song that is playing.
  void clearQueue() {
    PlaybackLogService.instance.log('CMD', 'svuota coda');
    _queue.keepOnlyCurrent();
    _suggestions.syncWithQueue();
    _updateQueueBroadcast();
  }

  /// Mixes the songs after the current one, once (the order changes; the
  /// shuffle mode does not).
  void shuffleUpcoming() {
    PlaybackLogService.instance.log('CMD', 'mescola la coda');
    _queue.shuffleAfterCurrent();
    _updateQueueBroadcast();
  }

  /// Plays [seed] followed by songs like it: a radio started from a song.
  Future<void> startRadio(Song seed) async {
    PlaybackLogService.instance.log('CMD', 'radio da "${seed.title}"');
    final playing = playSong(seed, queue: [seed]);
    try {
      final related = await _suggestions.fresh(seed);
      if (currentSong?.id == seed.id && _queue.appendUnique(related.take(40)) > 0) {
        _updateQueueBroadcast();
      }
    } catch (e) {
      debugPrint('AudioPlayerHandler.startRadio: $e');
    }
    await playing;
  }

  /// Puts back a queue kept from a previous session, without playing it:
  /// play() starts the current song from [position].
  void restoreSession(
    List<Song> songs,
    int index, {
    Duration position = Duration.zero,
    bool shuffle = false,
    PlaybackRepeat repeat = PlaybackRepeat.off,
  }) {
    if (songs.isEmpty || currentSong != null || _remote != null) return;
    final start = songs[index.clamp(0, songs.length - 1)];
    _queue.replace(songs, start);
    _queue.setShuffle(shuffle);
    _queue.setRepeat(repeat);
    playbackState.add(playbackState.value.copyWith(
      shuffleMode: shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: switch (repeat) {
        PlaybackRepeat.one => AudioServiceRepeatMode.one,
        PlaybackRepeat.all => AudioServiceRepeatMode.all,
        PlaybackRepeat.off => AudioServiceRepeatMode.none,
      },
    ));
    _updateQueueBroadcast(sync: false);
    mediaItem.add(start.toMediaItem());
    _userStopped = true;
    _resumeAt = position;
    positionNotifier.value = position;
    PlaybackLogService.instance.log(
      'SESSION',
      'coda ripristinata: ${songs.length} brani, "${start.title}" da ${position.inSeconds}s',
    );
  }

  /// The queue as it can be kept for the next session.
  ({List<Song> songs, int index, bool shuffle, PlaybackRepeat repeat}) get queueSnapshot =>
      (songs: _queue.items, index: _queue.index, shuffle: _queue.shuffle, repeat: _queue.repeat);

  List<Song> get currentPlaylist => _queue.items;

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
    _sendModes();
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
    _sendModes();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _player?.setVolume(_playerVolume);
  }

  // Squared: what is heard follows the slider far better than with the
  // plain value, which leaves nearly all the change in its lower third.
  double get _playerVolume => _volume * _outputVolume * _outputVolume * _gain * _crossfade.fadeIn;

  /// Sets how loud the app plays, from 0 to 1, within the volume of the
  /// device: here, or on the device that is playing instead of this one.
  Future<void> setOutputVolume(double volume) async {
    final value = volume.clamp(0.0, 1.0).toDouble();
    outputVolumeNotifier.value = value;
    final remote = _remote;
    if (remote != null) {
      _volumeSetAt = DateTime.now();
      remote.send(ConnectProtocol.volume, {'value': value});
      return;
    }
    _outputVolume = value;
    await _player?.setVolume(_playerVolume);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    _remote?.send(ConnectProtocol.speed, {'value': speed});
    await _player?.setPlaybackSpeed(speed);
  }

  // --- Playing on another device ---
  //
  // Everything below the next heading runs on the device that controls;
  // what follows it, on the device that plays.

  /// [song] with the YouTube video this device plays for it, when known, so
  /// that the other device plays the same recording without matching it
  /// again (and the position means the same thing on both).
  Song _withSource(Song song) {
    if (song.youtubeVideoId != null && song.youtubeVideoId!.isNotEmpty) return song;
    final source = (song.id == currentSong?.id ? _currentStreamId : null) ??
        StorageService.instance.getCachedYouTubeMapping(song.id);
    return (source == null || source.isEmpty) ? song : song.copyWith(youtubeVideoId: source);
  }

  /// Tells the other device to play the current song from [position], with
  /// the whole queue.
  void _sendLoad(Duration position) {
    final remote = _remote;
    if (remote == null || currentSong == null) return;
    _userPaused = false;
    _userStopped = false;
    _trackDuration = Duration.zero;
    remote.send(ConnectProtocol.load, {
      'songs': ConnectProtocol.encodeSongs(_queue.items.map(_withSource)),
      'index': _queue.index,
      'positionMs': position.inMilliseconds,
      'play': true,
      'shuffle': _queue.shuffle,
      'repeat': _queue.repeat.name,
    });
    _remoteAnchor = (position: position, at: DateTime.now(), playing: false);
    positionNotifier.value = position;
    _publish(
      processing: AudioProcessingState.buffering,
      playing: true,
      pollPosition: false,
    );
  }

  void _sendModes() {
    if (_followingRemote) return;
    _remote?.send(ConnectProtocol.mode, {
      'shuffle': _queue.shuffle,
      'repeat': _queue.repeat.name,
    });
  }

  /// Shows at once what a command is about to do on the other device; its
  /// next report confirms or corrects it.
  void _expectFromRemote({bool? playing, Duration? position}) {
    final shown = position ?? this.position;
    final isPlaying = playing ?? playbackState.value.playing;
    _remoteAnchor = (position: shown, at: DateTime.now(), playing: isPlaying);
    positionNotifier.value = shown;
    _publish(
      processing: playbackState.value.processingState,
      playing: isPlaying,
      pollPosition: false,
    );
  }

  /// Hands the playback to [remote]: what is playing here stops, and
  /// continues there from the same point. With nothing loaded here, or when
  /// [takeTheirs] is true, what [remote] is playing ([theirQueue],
  /// [theirState]) is taken up instead, and this device becomes its remote.
  Future<void> attachRemote(
    RemoteOutput remote, {
    List<Song> theirQueue = const [],
    ConnectState? theirState,
    bool takeTheirs = false,
  }) async {
    final song = takeTheirs && theirQueue.isNotEmpty ? null : currentSong;
    final at = position;
    PlaybackLogService.instance.log(
      'CONNECT',
      song == null
          ? 'controllo quello che suona "${remote.name}"'
          : 'passo la riproduzione a "${remote.name}": "${song.title}" da ${at.inSeconds}s',
    );

    // Nothing plays here any more; a load in progress is dropped.
    _crossfade.finish();
    _loadGeneration++;
    _loading = false;
    _starting = false;
    _seeking = false;
    _pendingSeek = null;
    _resumeAt = null;
    _stopPositionTimer();
    final player = _player;
    _player = null;
    await _disposeQuietly(player);

    _remote = remote;
    remoteNameNotifier.value = remote.name;
    _volumeSetAt = null;
    outputVolumeNotifier.value = theirState?.volume ?? 1.0;
    _remoteTicker?.cancel();
    _remoteTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final anchor = _remoteAnchor;
      if (anchor == null || !anchor.playing) return;
      var shown = anchor.position + DateTime.now().difference(anchor.at) * _speed;
      if (_trackDuration > Duration.zero && shown > _trackDuration) shown = _trackDuration;
      positionNotifier.value = shown;
    });

    if (song != null) {
      _sendLoad(at);
    } else if (theirQueue.isNotEmpty) {
      applyRemoteQueue(theirQueue, currentId: theirState?.songId);
      if (theirState != null) applyRemoteState(theirState);
    }
  }

  /// The connection to the device that is playing was opened again.
  void replaceRemote(RemoteOutput remote) {
    if (_remote != null) _remote = remote;
  }

  /// Takes the playback back from the other device. With [resumeAt] the
  /// current song continues here from that point: at once when [play] is
  /// true, at the next play() otherwise.
  Future<void> detachRemote({Duration? resumeAt, bool play = false}) async {
    final remote = _remote;
    if (remote == null) return;
    PlaybackLogService.instance.log(
      'CONNECT',
      'riprendo la riproduzione da "${remote.name}"'
      '${resumeAt == null ? '' : ' a ${resumeAt.inSeconds}s'}',
    );
    _remote = null;
    _remoteAnchor = null;
    _remoteTicker?.cancel();
    _remoteTicker = null;
    remoteNameNotifier.value = null;
    outputVolumeNotifier.value = _outputVolume;

    final at = resumeAt ?? position;
    if (currentSong == null) {
      _publish(processing: AudioProcessingState.idle, playing: false);
      return;
    }
    if (play) {
      _userStopped = false;
      await _loadAndPlayCurrent(startSeconds: at.inMilliseconds / 1000);
      return;
    }
    // Paused: nothing is loaded until the user asks for it.
    _userStopped = true;
    _resumeAt = at;
    positionNotifier.value = at;
    _publish(processing: AudioProcessingState.ready, playing: false);
  }

  /// The other device reports what it is doing.
  void applyRemoteState(ConnectState state) {
    if (_remote == null) return;
    final items = _queue.items;
    var index = state.index;
    if (index < 0 || index >= items.length || items[index].id != state.songId) {
      index = state.songId == null ? -1 : items.indexWhere((s) => s.id == state.songId);
    }
    if (index != -1 && index != _queue.index) {
      _queue.moveTo(index);
      final song = currentSong!;
      mediaItem.add(song.toMediaItem());
      StorageService.instance.addToHistory(song);
      _preloader.warmCanvasForCurrent();
    }

    final volumeSetAt = _volumeSetAt;
    if (volumeSetAt == null ||
        DateTime.now().difference(volumeSetAt) > const Duration(milliseconds: 1500)) {
      outputVolumeNotifier.value = state.volume;
    }

    _trackDuration = state.duration;
    final shown = mediaItem.value?.duration ?? Duration.zero;
    if (state.duration > Duration.zero &&
        (shown - state.duration).abs() > const Duration(seconds: 1)) {
      _publishCurrentMediaItem();
    }

    if (state.shuffle != _queue.shuffle || state.repeat != _queue.repeat.name) {
      _followingRemote = true;
      try {
        unawaited(setShuffleMode(
          state.shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
        ));
        unawaited(setRepeatMode(switch (state.repeat) {
          'one' => AudioServiceRepeatMode.one,
          'all' => AudioServiceRepeatMode.all,
          _ => AudioServiceRepeatMode.none,
        }));
      } finally {
        _followingRemote = false;
      }
    }

    _remoteAnchor = (position: state.position, at: DateTime.now(), playing: state.playing && !state.loading);
    positionNotifier.value = state.position;
    _publish(
      processing: state.loading ? AudioProcessingState.buffering : AudioProcessingState.ready,
      playing: state.playing,
      pollPosition: false,
    );
  }

  /// The other device sends its queue (it grew by itself at the end, or
  /// another controller changed it).
  void applyRemoteQueue(List<Song> songs, {String? currentId}) {
    if (_remote == null) return;
    final mine = _queue.items;
    final same = mine.length == songs.length &&
        [for (var i = 0; i < songs.length; i++) i].every(
          (i) => mine[i].id == songs[i].id && mine[i].thumbnailUrl == songs[i].thumbnailUrl,
        );
    if (same) return;
    final hadCurrent = currentSong?.id;
    _queue.adopt(songs, currentId: currentId ?? hadCurrent);
    _suggestions.syncWithQueue();
    _followingRemote = true;
    try {
      _updateQueueBroadcast();
    } finally {
      _followingRemote = false;
    }
    final song = currentSong;
    if (song != null && song.id != hadCurrent) mediaItem.add(song.toMediaItem());
  }

  // --- Playing for another device ---

  /// What this device is doing, for the devices that control it.
  ConnectState get connectState {
    final state = playbackState.value;
    final loading = _loading ||
        state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;
    return ConnectState(
      songId: currentSong?.id,
      index: _queue.index,
      position: position,
      duration: _trackDuration > Duration.zero
          ? _trackDuration
          : (currentSong?.duration ?? Duration.zero),
      // A player that stops to buffer reports itself as not playing for a
      // moment: for who controls it, it is still playing unless it was
      // told to pause.
      playing: state.playing || (loading && !_userPaused && !_userStopped),
      loading: loading,
      shuffle: _queue.shuffle,
      repeat: _queue.repeat.name,
      volume: _outputVolume,
    );
  }

  /// A controller asks this device to play [songs] from the one at [index],
  /// starting at [position].
  Future<void> loadFromRemote(
    List<Song> songs,
    int index,
    Duration position, {
    bool play = true,
  }) async {
    if (songs.isEmpty) return;
    // This device was the remote of another one: it plays itself now, and
    // the other is left to what it was doing.
    if (_remote != null) await detachRemote();
    final start = songs[index.clamp(0, songs.length - 1)];
    PlaybackLogService.instance.log(
      'CONNECT',
      'ricevuto "${start.title}" da ${position.inSeconds}s, coda di ${songs.length}',
    );
    _queue.replace(songs, start);
    _opener.forgetFailures(start.id);
    _suggestions.syncWithQueue();
    _updateQueueBroadcast();
    mediaItem.add(start.toMediaItem());
    StorageService.instance.addToHistory(start);
    _preloader.warmCanvasForCurrent();
    _preloader.upgradeCoversAround();

    _userStopped = false;
    final loaded = _loadAndPlayCurrent(startSeconds: position.inMilliseconds / 1000);
    // Asked to stay paused: the load honours a pause that arrives meanwhile.
    if (!play) unawaited(pause());
    await loaded;
  }

  /// A controller changed the queue: the current song goes on playing.
  void adoptQueue(List<Song> songs, {String? currentId}) {
    _queue.adopt(songs, currentId: currentId);
    _suggestions.syncWithQueue();
    _updateQueueBroadcast();
  }
}
