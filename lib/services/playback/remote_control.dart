import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../connect/connect_protocol.dart';
import '../playback_log_service.dart';
import '../playback_queue.dart';

/// What controlling another device needs from the audio handler.
abstract interface class RemoteControlHost {
  PlaybackQueue get queue;

  /// The YouTube video this device plays for [song], when known.
  String? knownSourceOf(Song song);

  ValueNotifier<Duration> get positionNotifier;
  ValueNotifier<double> get outputVolumeNotifier;

  /// How loud this device plays by itself.
  double get outputVolume;
  double get speed;

  Duration get trackDuration;
  set trackDuration(Duration value);

  set userPaused(bool value);
  set userStopped(bool value);

  /// Where play() starts from after the playback came back paused.
  set resumeAt(Duration? value);

  bool get isPlaying;
  AudioProcessingState get processingState;

  /// The length shown for the current song.
  Duration? get shownDuration;

  void publish({
    required AudioProcessingState processing,
    required bool playing,
    bool pollPosition = true,
  });

  /// Nothing plays here any more: a load in progress is dropped and the
  /// player is closed.
  Future<void> stopLocalPlayback();

  /// Shows [song] as the current one.
  void showSong(Song song);

  /// [song] started on the other device: it goes in the history, and its
  /// Canvas is prepared.
  void onSongStarted(Song song);

  void publishCurrentMediaItem();
  void syncSuggestions();

  /// Tells the interface (and the other device, unless the change came
  /// from it) that the queue has changed.
  void broadcastQueue();

  Future<void> setShuffle(bool enabled);
  Future<void> setRepeat(String mode);

  Future<void> loadAndPlayCurrent({double? startSeconds});
}

/// The playback handed to another device running Totorify. While it is,
/// nothing plays here: every command goes to that device, which reports
/// what it is doing, and the handler shows it, so the whole interface works
/// as its remote.
class RemoteControl {
  RemoteControl(this._host);

  final RemoteControlHost _host;

  /// The device that is playing instead of this one, when there is one.
  RemoteOutput? get remote => _remote;
  RemoteOutput? _remote;

  /// True while a change that came from that device is applied here: it
  /// must not be sent back to it.
  bool get following => _following;
  bool _following = false;

  // Where the other device said it was, and when: the position shown moves
  // on from there between its reports.
  ({Duration position, DateTime at, bool playing})? _anchor;
  Timer? _ticker;

  /// Name of the device that is playing instead of this one, or null.
  final ValueNotifier<String?> nameNotifier = ValueNotifier<String?>(null);

  // When the volume of the other device was last set from here: its
  // reports are not allowed to move the slider back while it is dragged.
  DateTime? _volumeSetAt;

  /// The volume of the other device was just set from here.
  void markVolumeSet() => _volumeSetAt = DateTime.now();

  Song? get _currentSong => _host.queue.current;
  Duration get _position => _host.positionNotifier.value;

  /// [song] with the YouTube video this device plays for it, when known, so
  /// that the other device plays the same recording without matching it
  /// again (and the position means the same thing on both).
  Song withSource(Song song) {
    if (song.youtubeVideoId != null && song.youtubeVideoId!.isNotEmpty) return song;
    final source = _host.knownSourceOf(song);
    return (source == null || source.isEmpty) ? song : song.copyWith(youtubeVideoId: source);
  }

  /// Tells the other device to play the current song from [position], with
  /// the whole queue.
  void sendLoad(Duration position) {
    final remote = _remote;
    if (remote == null || _currentSong == null) return;
    _host.userPaused = false;
    _host.userStopped = false;
    _host.trackDuration = Duration.zero;
    remote.send(ConnectProtocol.load, {
      'songs': ConnectProtocol.encodeSongs(_host.queue.items.map(withSource)),
      'index': _host.queue.index,
      'positionMs': position.inMilliseconds,
      'play': true,
      'shuffle': _host.queue.shuffle,
      'repeat': _host.queue.repeat.name,
    });
    _anchor = (position: position, at: DateTime.now(), playing: false);
    _host.positionNotifier.value = position;
    _host.publish(
      processing: AudioProcessingState.buffering,
      playing: true,
      pollPosition: false,
    );
  }

  void sendModes() {
    if (_following) return;
    _remote?.send(ConnectProtocol.mode, {
      'shuffle': _host.queue.shuffle,
      'repeat': _host.queue.repeat.name,
    });
  }

  /// Shows at once what a command is about to do on the other device; its
  /// next report confirms or corrects it.
  void expect({bool? playing, Duration? position}) {
    final shown = position ?? _position;
    final isPlaying = playing ?? _host.isPlaying;
    _anchor = (position: shown, at: DateTime.now(), playing: isPlaying);
    _host.positionNotifier.value = shown;
    _host.publish(
      processing: _host.processingState,
      playing: isPlaying,
      pollPosition: false,
    );
  }

  /// Hands the playback to [remote]: what is playing here stops, and
  /// continues there from the same point. With nothing loaded here, or when
  /// [takeTheirs] is true, what [remote] is playing ([theirQueue],
  /// [theirState]) is taken up instead, and this device becomes its remote.
  Future<void> attach(
    RemoteOutput remote, {
    List<Song> theirQueue = const [],
    ConnectState? theirState,
    bool takeTheirs = false,
  }) async {
    final song = takeTheirs && theirQueue.isNotEmpty ? null : _currentSong;
    final at = _position;
    PlaybackLogService.instance.log(
      'CONNECT',
      song == null
          ? 'controllo quello che suona "${remote.name}"'
          : 'passo la riproduzione a "${remote.name}": "${song.title}" da ${at.inSeconds}s',
    );

    // Nothing plays here any more; a load in progress is dropped.
    await _host.stopLocalPlayback();

    _remote = remote;
    nameNotifier.value = remote.name;
    _volumeSetAt = null;
    _host.outputVolumeNotifier.value = theirState?.volume ?? 1.0;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final anchor = _anchor;
      if (anchor == null || !anchor.playing) return;
      var shown = anchor.position + DateTime.now().difference(anchor.at) * _host.speed;
      final trackDuration = _host.trackDuration;
      if (trackDuration > Duration.zero && shown > trackDuration) shown = trackDuration;
      _host.positionNotifier.value = shown;
    });

    if (song != null) {
      sendLoad(at);
    } else if (theirQueue.isNotEmpty) {
      applyQueue(theirQueue, currentId: theirState?.songId);
      if (theirState != null) applyState(theirState);
    }
  }

  /// The connection to the device that is playing was opened again.
  void replace(RemoteOutput remote) {
    if (_remote != null) _remote = remote;
  }

  /// Takes the playback back from the other device. With [resumeAt] the
  /// current song continues here from that point: at once when [play] is
  /// true, at the next play() otherwise.
  Future<void> detach({Duration? resumeAt, bool play = false}) async {
    final remote = _remote;
    if (remote == null) return;
    PlaybackLogService.instance.log(
      'CONNECT',
      'riprendo la riproduzione da "${remote.name}"'
      '${resumeAt == null ? '' : ' a ${resumeAt.inSeconds}s'}',
    );
    _remote = null;
    _anchor = null;
    _ticker?.cancel();
    _ticker = null;
    nameNotifier.value = null;
    _host.outputVolumeNotifier.value = _host.outputVolume;

    final at = resumeAt ?? _position;
    if (_currentSong == null) {
      _host.publish(processing: AudioProcessingState.idle, playing: false);
      return;
    }
    if (play) {
      _host.userStopped = false;
      await _host.loadAndPlayCurrent(startSeconds: at.inMilliseconds / 1000);
      return;
    }
    // Paused: nothing is loaded until the user asks for it.
    _host.userStopped = true;
    _host.resumeAt = at;
    _host.positionNotifier.value = at;
    _host.publish(processing: AudioProcessingState.ready, playing: false);
  }

  /// The other device reports what it is doing.
  void applyState(ConnectState state) {
    if (_remote == null) return;
    final queue = _host.queue;
    final items = queue.items;
    var index = state.index;
    if (index < 0 || index >= items.length || items[index].id != state.songId) {
      index = state.songId == null ? -1 : items.indexWhere((s) => s.id == state.songId);
    }
    if (index != -1 && index != queue.index) {
      queue.moveTo(index);
      final song = _currentSong!;
      _host.showSong(song);
      _host.onSongStarted(song);
    }

    final volumeSetAt = _volumeSetAt;
    if (volumeSetAt == null ||
        DateTime.now().difference(volumeSetAt) > const Duration(milliseconds: 1500)) {
      _host.outputVolumeNotifier.value = state.volume;
    }

    _host.trackDuration = state.duration;
    final shown = _host.shownDuration ?? Duration.zero;
    if (state.duration > Duration.zero &&
        (shown - state.duration).abs() > const Duration(seconds: 1)) {
      _host.publishCurrentMediaItem();
    }

    if (state.shuffle != queue.shuffle || state.repeat != queue.repeat.name) {
      _following = true;
      try {
        unawaited(_host.setShuffle(state.shuffle));
        unawaited(_host.setRepeat(state.repeat));
      } finally {
        _following = false;
      }
    }

    _anchor = (
      position: state.position,
      at: DateTime.now(),
      playing: state.playing && !state.loading,
    );
    _host.positionNotifier.value = state.position;
    _host.publish(
      processing: state.loading ? AudioProcessingState.buffering : AudioProcessingState.ready,
      playing: state.playing,
      pollPosition: false,
    );
  }

  /// The other device sends its queue (it grew by itself at the end, or
  /// another controller changed it).
  void applyQueue(List<Song> songs, {String? currentId}) {
    if (_remote == null) return;
    final queue = _host.queue;
    final mine = queue.items;
    final same = mine.length == songs.length &&
        [for (var i = 0; i < songs.length; i++) i].every(
          (i) => mine[i].id == songs[i].id && mine[i].thumbnailUrl == songs[i].thumbnailUrl,
        );
    if (same) return;
    final hadCurrent = _currentSong?.id;
    queue.adopt(songs, currentId: currentId ?? hadCurrent);
    _host.syncSuggestions();
    _following = true;
    try {
      _host.broadcastQueue();
    } finally {
      _following = false;
    }
    final song = _currentSong;
    if (song != null && song.id != hadCurrent) _host.showSong(song);
  }
}
