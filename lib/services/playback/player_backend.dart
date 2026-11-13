import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// What a player says about itself at a given moment.
class PlayerValue {
  const PlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.duration = Duration.zero,
    this.errorDescription,
  });

  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;

  /// The length the player reports. Not always the real one: see
  /// `AudioPlayerHandler._resolveDuration`.
  final Duration duration;
  final String? errorDescription;

  bool get hasError => errorDescription != null;
}

/// Where a player reads its audio from.
class PlayerSource {
  const PlayerSource.file(this.location)
      : isFile = true,
        isHls = false;

  const PlayerSource.network(this.location, {this.isHls = false}) : isFile = false;

  /// A path for a file, a URL otherwise.
  final String location;
  final bool isFile;

  /// True for an HLS playlist, which the player cannot tell from its URL.
  final bool isHls;
}

/// The player, reduced to what the audio handler asks of it. The real one
/// is [VideoPlayerBackend]; the tests use a fake.
abstract class PlayerBackend {
  PlayerValue get value;
  Future<Duration?> get position;

  /// [listener] is called whenever [value] changes.
  void addListener(VoidCallback listener);

  /// Opens the source; completes when it can play, throws when it cannot.
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setPlaybackSpeed(double speed);
  Future<void> dispose();
}

typedef PlayerBackendFactory = PlayerBackend Function(PlayerSource source);

/// The native player (AVPlayer on iOS), through `video_player`.
class VideoPlayerBackend implements PlayerBackend {
  VideoPlayerBackend(PlayerSource source)
      : _controller = source.isFile
            ? VideoPlayerController.file(File(source.location), videoPlayerOptions: _audioOptions)
            : VideoPlayerController.networkUrl(
                Uri.parse(source.location),
                formatHint: source.isHls ? VideoFormat.hls : null,
                videoPlayerOptions: _audioOptions,
              );

  // Background playback must be allowed explicitly: by default the plugin
  // pauses its players when the app leaves the foreground. On Android each
  // ExoPlayer would also ask for the audio focus on its own, taking it from
  // the app's audio session (and from the other player of a crossfade):
  // the session lost it and paused the music as it started. There the
  // session alone holds the focus, as on iOS.
  static final VideoPlayerOptions _audioOptions = VideoPlayerOptions(
    allowBackgroundPlayback: true,
    mixWithOthers: Platform.isAndroid,
  );

  final VideoPlayerController _controller;

  @override
  PlayerValue get value {
    final value = _controller.value;
    return PlayerValue(
      isInitialized: value.isInitialized,
      isPlaying: value.isPlaying,
      isBuffering: value.isBuffering,
      isCompleted: value.isCompleted,
      duration: value.duration,
      errorDescription: value.errorDescription,
    );
  }

  @override
  Future<Duration?> get position => _controller.position;

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);

  @override
  Future<void> setVolume(double volume) => _controller.setVolume(volume);

  @override
  Future<void> setPlaybackSpeed(double speed) => _controller.setPlaybackSpeed(speed);

  @override
  Future<void> dispose() => _controller.dispose();
}
