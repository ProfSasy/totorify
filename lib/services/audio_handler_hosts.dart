part of 'audio_handler.dart';

// What the parts of the playback in `playback/` ask of the handler: each
// host gives one of them the handler's state it needs, and nothing else.

class _CrossfadeHost implements CrossfadeHost {
  _CrossfadeHost(this._handler);

  final AudioPlayerHandler _handler;

  @override
  int get crossfadeSeconds => AppSettings.instance.crossfadeSeconds.value;

  @override
  bool get mayFadeToNext =>
      _handler._remote == null &&
      _handler._endGateOpen &&
      _handler._queue.repeat != PlaybackRepeat.one &&
      !_handler._sleepTimerEndOfTrack &&
      !_handler._userPaused;

  @override
  Duration get trackDuration => _handler._trackDuration;

  @override
  int? peekNext() => _handler._queue.peekNext();

  @override
  PlayerBackend? get player => _handler._player;

  @override
  double get playerVolume => _handler._playerVolume;

  @override
  void releasePlayerToFade() {
    _handler._endGateOpen = false;
    _handler._player = null;
  }

  @override
  void applyPlayerVolume() {
    final player = _handler._player;
    if (player != null) unawaited(player.setVolume(_handler._playerVolume).catchError((_) {}));
  }

  @override
  void playIndex(int index) => unawaited(_handler._playIndex(index));

  @override
  void disposePlayer(PlayerBackend player) => unawaited(_handler._disposeQuietly(player));
}

class _StreamOpenerHost implements StreamOpenerHost {
  _StreamOpenerHost(this._handler);

  final AudioPlayerHandler _handler;

  @override
  Song? get currentSong => _handler.currentSong;

  @override
  void updateSong(String id, Song Function(Song) update) =>
      _handler._queue.updateSong(id, update);

  @override
  bool get hasNext => _handler._queue.peekNext() != null;

  @override
  bool get isRemote => _handler._remote != null;

  @override
  bool get skipUnplayable => AppSettings.instance.skipUnplayable.value;

  @override
  bool get userPaused => _handler._userPaused;

  @override
  bool get userStopped => _handler._userStopped;

  @override
  set userStopped(bool value) => _handler._userStopped = value;

  @override
  double get playerVolume => _handler._playerVolume;

  @override
  double get speed => _handler._speed;

  @override
  double get positionSeconds => _handler._currentSeconds();

  @override
  double startOffsetSecondsOf(Song song) => _handler._startOffsetOf(song).inMilliseconds / 1000;

  @override
  String? knownVideoIdOf(Song song) => _handler._videoIdOf(song);

  @override
  void onLoadStarting(Duration start) {
    _handler._crossfade.onLoadStarting();
    _handler._endGateOpen = true;
    _handler._userPaused = false;
    _handler._seeking = false;
    _handler._seekGeneration++;
    _handler._pendingSeek = null;
    _handler._trackDuration = Duration.zero;
    _handler._segments = const [];
    _handler._segmentsPassed.clear();
    _handler.positionNotifier.value = start;
  }

  @override
  void publish({
    required AudioProcessingState processing,
    required bool playing,
    bool pollPosition = true,
  }) =>
      _handler._publish(processing: processing, playing: playing, pollPosition: pollPosition);

  @override
  void prepareExtras(String? videoId, int generation) =>
      _handler._prepareExtras(videoId, generation);

  @override
  void onLocalFilePlaying(Song song) {
    // A song downloaded before Canvas and lyrics were saved with it.
    unawaited(DownloadService.instance.saveExtras(song));
  }

  @override
  void prepareWhatFollows(Song song, int generation) =>
      _handler._prepareWhatFollows(song, generation);

  @override
  void onPlayerValue(PlayerBackend player) => _handler._onPlayerValue(player);

  @override
  Duration resolveTrackDuration(Duration reported, Duration? known) =>
      _handler._trackDuration = _handler._resolveDuration(reported, known, _handler.currentSong);

  @override
  Duration? takePendingSeek() {
    final pending = _handler._pendingSeek;
    _handler._pendingSeek = null;
    return pending;
  }

  @override
  void setPosition(Duration position, {bool announce = false}) =>
      _handler._setPosition(position, announce: announce);

  @override
  void publishCurrentMediaItem() => _handler._publishCurrentMediaItem();

  @override
  void showSource(String source) => _handler.sourceNotifier.value = source;

  @override
  Future<void> activateSession() => _handler._activateSession();

  @override
  void startFadeRampIfFading() {
    if (_handler._crossfade.isFading) _handler._crossfade.startRamp();
  }

  @override
  void finishCrossfade() => _handler._crossfade.finish();

  @override
  void reportError(String message) => _handler._errorController.add(message);

  @override
  void reportInfo(String message) => _handler._infoController.add(message);

  @override
  Future<void> reload({bool allowLocal = true, double? startSeconds, bool freshUrl = false}) =>
      _handler._loadAndPlayCurrent(
        allowLocal: allowLocal,
        startSeconds: startSeconds,
        freshUrl: freshUrl,
      );

  @override
  Future<void> skipToNext() => _handler.skipToNext();
}
