import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/song.dart';
import 'app_settings.dart';
import 'canvas_service.dart';
import 'canvas_video_pool.dart';
import 'connect/connect_protocol.dart';
import 'cover_art_service.dart';
import 'download_service.dart';
import 'lyrics_service.dart';
import 'playback_log_service.dart';
import 'playback_queue.dart';
import 'recommendation_service.dart';
import 'sponsor_block_service.dart';
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

  AudioPlayerHandler() {
    AppSettings.instance.normalizeVolume.addListener(_onNormalizeChanged);
  }

  // SponsorBlock: the parts of the video playing to jump over, and which of
  // them were already jumped (or entered on purpose by the user) in this
  // load.
  List<SkipSegment> _segments = const [];
  final Set<int> _segmentsPassed = {};

  // How much the current track is lowered to sound as loud as the others.
  double _gain = 1.0;

  // Songs that could not be played one after the other: past a few, the
  // queue is not skipped through any further.
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  /// Where what plays comes from ("HLS audio", "file locale"…), for the
  /// details of the track.
  final ValueNotifier<String?> sourceNotifier = ValueNotifier<String?>(null);

  /// YouTube video being streamed, or null while a local file plays.
  String? get currentStreamId => _currentStreamId;

  /// How much the current track is lowered by the normalization (1 = not).
  double get normalizationGain => _gain;

  // Crossfade: the player of the song fading out while the next one fades
  // in, how loud it was when it started to fade, and the level of the one
  // coming in (0 to 1).
  VideoPlayerController? _fadingOut;
  double _fadingOutVolume = 0;
  double _fadeIn = 1.0;
  Timer? _fadeTimer;
  // True while the load of the song coming in is being started by the
  // crossfade itself: any other load ends the crossfade at once.
  bool _crossfadeStarting = false;

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
  // Lowered for a moment while another app speaks.
  double _volume = 1.0;
  // How loud this app plays, as set by the devices that control it.
  double _outputVolume = 1.0;
  double _speed = 1.0;

  Timer? _positionTimer;

  /// YouTube video being streamed, or null while a local file plays.
  String? _currentStreamId;

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
        _skipSegmentAt(position);
        _maybeCrossfade(position);
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
    final song = currentSong;
    if (song == null) return;
    _resumeAt = null;
    if (_remote != null) {
      // Another device is playing: it loads the track, this one follows.
      final from = startSeconds ?? _startOffsetOf(song).inMilliseconds / 1000;
      _sendLoad(Duration(milliseconds: (from * 1000).round()));
      return;
    }
    if (_crossfadeStarting) {
      _crossfadeStarting = false;
    } else {
      _finishCrossfade();
    }
    final generation = ++_loadGeneration;
    _endGateOpen = true;
    _userPaused = false;
    _loading = true;
    _starting = false;
    _seeking = false;
    _seekGeneration++;
    _pendingSeek = null;
    _trackDuration = Duration.zero;
    _segments = const [];
    _segmentsPassed.clear();
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
        _prepareExtras(_videoIdOf(song), generation);
        final opened = await _open(
          () => VideoPlayerController.file(File(path), videoPlayerOptions: _audioOptions),
          generation,
          start: start,
          source: 'file locale',
          knownDuration: StorageService.instance.getDownloadDuration(song.id),
        );
        if (opened == _Open.ok) {
          _currentStreamId = null;
          // A song downloaded before Canvas and lyrics were saved with it.
          unawaited(DownloadService.instance.saveExtras(song));
          _prepareWhatFollows(song, generation);
        }
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
      _prepareExtras(videoId, generation);

      final outcome = await _openStream(videoId, generation, start: start, freshUrl: freshUrl);
      if (outcome.result == _Open.ok) {
        _prepareWhatFollows(song, generation);
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

    // Where Opus plays, its direct stream is the best audio there is: it
    // goes first, and the HLS playlist (AAC) is what follows if it fails.
    // On iOS the HLS playlist goes first: same AAC, better seeking.
    final opusFirst = YTMusicService.opusPlayable;
    String? hlsAudio;
    if (!opusFirst) {
      // [freshUrl] makes this first lookup forget every remembered URL of
      // the video, so the ones asked below are new as well.
      hlsAudio = await yt.getHlsAudioUrl(videoId, force: freshUrl);
      if (generation != _loadGeneration) return superseded;
      if (hlsAudio != null) {
        final opened = await openUrl(hlsAudio, 'HLS audio', format: VideoFormat.hls);
        if (opened != _Open.failed) return (result: opened, unavailable: false);
      }
    }

    var url = await yt.getAudioStreamUrl(videoId, force: opusFirst && freshUrl);
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

    if (opusFirst) {
      hlsAudio = await yt.getHlsAudioUrl(videoId);
      if (generation != _loadGeneration) return superseded;
      if (hlsAudio != null) {
        final opened = await openUrl(hlsAudio, 'HLS audio', format: VideoFormat.hls);
        if (opened != _Open.failed) return (result: opened, unavailable: false);
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

      await controller.setVolume(_playerVolume);
      await controller.setPlaybackSpeed(_speed);
      // A newer load can begin while this player is being set up (skipping
      // quickly through tracks). It silenced this one and will replace it:
      // carrying on would start a track that was already skipped.
      if (generation != _loadGeneration) return _Open.superseded;
      final startAt = _pendingSeek ?? Duration(milliseconds: (start * 1000).round());
      _pendingSeek = null;
      if (startAt > Duration.zero) await controller.seekTo(startAt);
      if (generation != _loadGeneration) return _Open.superseded;
      _setPosition(startAt, announce: true);
      _publishCurrentMediaItem();
      sourceNotifier.value = source;
      _consecutiveFailures = 0;
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
        if (generation != _loadGeneration) return _Open.superseded;
        await controller.play();
        _starting = false;
        if (_fadingOut != null) _startFadeRamp();
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
    _finishCrossfade();
    _skipAfterFailure();
  }

  // ── Crossfade ───────────────────────────────────────────────────────────

  /// Near the end of the track, with crossfade on, the next one starts
  /// while this one goes on: this one fades out as the other fades in.
  void _maybeCrossfade(Duration position) {
    final seconds = AppSettings.instance.crossfadeSeconds.value;
    if (seconds <= 0 || _fadingOut != null || _remote != null || !_endGateOpen) return;
    // A short track would be all fade.
    if (_trackDuration < Duration(seconds: seconds * 3)) return;
    if (position < _trackDuration - Duration(seconds: seconds)) return;
    if (_queue.repeat == PlaybackRepeat.one || _sleepTimerEndOfTrack || _userPaused) return;
    final next = _queue.peekNext();
    final old = _player;
    if (next == null || old == null) return;

    PlaybackLogService.instance.log('FADE', 'dissolvenza di ${seconds}s verso il prossimo brano');
    _endGateOpen = false;
    _fadingOutVolume = _playerVolume;
    _fadingOut = old;
    // The song fading out is no longer the player: what it reports is not
    // published, and the next load does not silence it.
    _player = null;
    _fadeIn = 0.0;
    _crossfadeStarting = true;
    unawaited(_playIndex(next));
  }

  void _startFadeRamp() {
    final total = AppSettings.instance.crossfadeSeconds.value * 1000;
    final started = DateTime.now();
    final old = _fadingOut;
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final level = total <= 0
          ? 1.0
          : (DateTime.now().difference(started).inMilliseconds / total).clamp(0.0, 1.0);
      _fadeIn = level;
      final player = _player;
      if (player != null) unawaited(player.setVolume(_playerVolume).catchError((_) {}));
      if (old != null) {
        unawaited(old.setVolume(_fadingOutVolume * (1 - level)).catchError((_) {}));
      }
      if (level >= 1) _finishCrossfade();
    });
  }

  /// Ends a crossfade at once: the song fading out stops, the one coming in
  /// plays at its full volume.
  void _finishCrossfade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final old = _fadingOut;
    _fadingOut = null;
    _crossfadeStarting = false;
    if (_fadeIn != 1.0) {
      _fadeIn = 1.0;
      final player = _player;
      if (player != null) unawaited(player.setVolume(_playerVolume).catchError((_) {}));
    }
    if (old != null) unawaited(_disposeQuietly(old));
  }

  /// A song that cannot be played is passed over, when the user wants it:
  /// the next one starts after a moment, unless something else was asked
  /// meanwhile. A few failures in a row stop it (no network, most likely).
  void _skipAfterFailure() {
    if (!AppSettings.instance.skipUnplayable.value || _remote != null) return;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      PlaybackLogService.instance.log('SKIP', 'troppi brani non riproducibili di fila: mi fermo');
      _consecutiveFailures = 0;
      return;
    }
    if (_queue.peekNext() == null) return;
    _consecutiveFailures++;
    final generation = _loadGeneration;
    final failed = currentSong?.id;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 1500), () async {
      if (generation != _loadGeneration || !_userStopped || currentSong?.id != failed) return;
      PlaybackLogService.instance.log('SKIP', 'brano non riproducibile: passo al successivo');
      _infoController.add('Brano non disponibile: passo al successivo');
      await skipToNext();
    }));
  }

  // ── SponsorBlock and normalization ──────────────────────────────────────

  /// The YouTube video [song] is played from, when known: the one matched
  /// for it, or its own id for a song of the YouTube catalog.
  String? _videoIdOf(Song song) => TrackMatcherService.instance.knownStreamIdOf(song);

  /// Looks up, beside the load, the parts of [videoId] to skip and how loud
  /// it is.
  void _prepareExtras(String? videoId, int generation) {
    if (videoId == null || videoId.isEmpty) {
      _setGain(1.0);
      return;
    }
    unawaited(() async {
      final segments = await SponsorBlockService.instance.segmentsFor(videoId);
      if (generation != _loadGeneration || segments.isEmpty) return;
      _segments = segments;
      PlaybackLogService.instance.log('SKIP', 'SponsorBlock $videoId: ${segments.join(', ')}');
    }());
    unawaited(_applyLoudness(videoId, generation));
  }

  Future<void> _applyLoudness(String videoId, int generation) async {
    if (!AppSettings.instance.normalizeVolume.value) {
      _setGain(1.0);
      return;
    }
    final known = YTMusicService.instance.streamDetails(videoId);
    // Known already (the streams were just looked up): set before playing.
    if (known != null) {
      _setGain(gainFor(known.loudnessDb));
      return;
    }
    final db = await YTMusicService.instance.loudnessOf(videoId);
    if (generation != _loadGeneration) return;
    _setGain(gainFor(db));
  }

  /// How much a track [loudnessDb] louder than YouTube's reference is
  /// lowered. Quieter ones are left as they are: the player cannot go above
  /// full volume.
  static double gainFor(double? loudnessDb) {
    if (loudnessDb == null || loudnessDb <= 0) return 1.0;
    return pow(10, -loudnessDb / 20).toDouble().clamp(0.2, 1.0);
  }

  void _setGain(double gain) {
    if (gain == _gain) return;
    _gain = gain;
    final player = _player;
    if (player != null) unawaited(player.setVolume(_playerVolume).catchError((_) {}));
  }

  void _onNormalizeChanged() {
    final videoId = _currentStreamId ?? (currentSong == null ? null : _videoIdOf(currentSong!));
    if (videoId == null) return;
    unawaited(_applyLoudness(videoId, _loadGeneration));
  }

  /// Jumps over the marked part [position] is in, once per load. A part
  /// that runs to the end of the track ends it.
  void _skipSegmentAt(Duration position) {
    if (_segments.isEmpty || _seeking || _loading || _remote != null) return;
    for (var i = 0; i < _segments.length; i++) {
      final segment = _segments[i];
      if (_segmentsPassed.contains(i) || !segment.contains(position)) continue;
      _segmentsPassed.add(i);
      PlaybackLogService.instance.log('SKIP', 'salto $segment');
      final toEnd = _trackDuration > Duration.zero &&
          segment.end >= _trackDuration - const Duration(seconds: 2);
      if (toEnd) {
        unawaited(_onTrackEnded());
      } else {
        unawaited(seek(segment.end));
        _infoController.add(segment.category == 'music_offtopic'
            ? 'Saltata una parte non musicale'
            : 'Saltato un segmento (${SponsorBlockService.categories[segment.category] ?? segment.category})');
      }
      return;
    }
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

  /// The current track has started: what comes next is prepared now, and
  /// not before, so that nothing competes with its first seconds. The next
  /// track's stream first, then the Canvas videos around, and last the file
  /// that makes this track's Canvas instant the next time.
  void _prepareWhatFollows(Song song, int generation) {
    unawaited(() async {
      await _prefetchNext();
      if (generation != _loadGeneration) return;
      _warmCanvasAround();
      unawaited(LyricsService.instance.preload(_upcoming(2)));
      await Future<void>.delayed(const Duration(seconds: 4));
      if (generation != _loadGeneration) return;
      await CanvasService.instance.keepForReplay(song);
    }());
  }

  /// The [count] songs that come after the current one in queue order.
  List<Song> _upcoming(int count) {
    final items = _queue.items;
    final index = _queue.index;
    if (index < 0) return const [];
    return items.sublist(index + 1, (index + 1 + count).clamp(index + 1, items.length));
  }

  /// Resolves the next track's stream ahead of time, so skipping to it (or
  /// reaching it) starts without the matching and lookup delay. With
  /// shuffle the next track is the one the queue has drawn.
  Future<void> _prefetchNext() async {
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
    // Something new starts shuffled, when the user always wants it so.
    if (AppSettings.instance.permanentShuffle.value && !_queue.shuffle) {
      await setShuffleMode(AudioServiceShuffleMode.all);
    }
    _queue.replace((queue != null && queue.isNotEmpty) ? queue : [song], song);
    _failedStreams.remove(song.id);
    _errorReloads.remove(song.id);
    _syncSuggestionsWithQueue();
    // Another device, if it is the one playing, gets the queue with the
    // order to play it.
    _updateQueueBroadcast(sync: false);
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
    _finishCrossfade();
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
    _finishCrossfade();
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

    for (var i = 0; i < _segments.length; i++) {
      if (_segments[i].contains(target)) _segmentsPassed.add(i);
    }
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

  /// Keeps only the song that is playing.
  void clearQueue() {
    PlaybackLogService.instance.log('CMD', 'svuota coda');
    _queue.keepOnlyCurrent();
    _syncSuggestionsWithQueue();
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
      final related = await _freshSuggestions(seed);
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

  /// Looks up and warms the Canvas of the current track, the one the user
  /// is about to look at. It starts with the track, alongside its audio.
  void _warmCanvasForCurrent() {
    final song = currentSong;
    if (song == null) return;
    unawaited(() async {
      final url = await CanvasService.instance.getCanvasUrl(song);
      if (url == null || url.isEmpty || currentSong?.id != song.id) return;
      await CanvasVideoPool.instance.warm(url);
    }());
  }

  /// Looks up and warms the Canvas of the tracks around the current one
  /// (the previous, the next and, in queue order, the one after), so that
  /// skipping shows the video at once.
  void _warmCanvasAround() {
    final items = _queue.items;
    final index = _queue.index;
    if (index < 0) return;
    final around = <int>{
      ?_queue.peekPrevious(),
      ?_queue.peekNext(),
      if (!_queue.shuffle && index + 2 < items.length) index + 2,
    }..remove(index);

    for (final i in around) {
      final song = items[i];
      unawaited(() async {
        final url = await CanvasService.instance.prefetch(song);
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
  double get _playerVolume => _volume * _outputVolume * _outputVolume * _gain * _fadeIn;

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
    _finishCrossfade();
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
      _warmCanvasForCurrent();
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
    _syncSuggestionsWithQueue();
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
    _failedStreams.remove(start.id);
    _errorReloads.remove(start.id);
    _syncSuggestionsWithQueue();
    _updateQueueBroadcast();
    mediaItem.add(start.toMediaItem());
    StorageService.instance.addToHistory(start);
    _warmCanvasForCurrent();
    _upgradeCoversAround();

    _userStopped = false;
    final loaded = _loadAndPlayCurrent(startSeconds: position.inMilliseconds / 1000);
    // Asked to stay paused: the load honours a pause that arrives meanwhile.
    if (!play) unawaited(pause());
    await loaded;
  }

  /// A controller changed the queue: the current song goes on playing.
  void adoptQueue(List<Song> songs, {String? currentId}) {
    _queue.adopt(songs, currentId: currentId);
    _syncSuggestionsWithQueue();
    _updateQueueBroadcast();
  }
}
