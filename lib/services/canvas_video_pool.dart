import 'dart:collection';
import 'dart:io';

import 'package:video_player/video_player.dart';

import 'playback_log_service.dart';

/// Keeps up to four Canvas video controllers warm (initialized but paused):
/// the current track, the one before and the two that follow. The player
/// sheet, the skip transitions and the close/reopen cycle then show the
/// video instantly instead of paying the AVPlayer startup cost every time.
class CanvasVideoPool {
  CanvasVideoPool._();
  static final CanvasVideoPool instance = CanvasVideoPool._();

  static const int _maxWarmVideos = 4;

  /// Player for a Canvas, which is either on Spotify's servers or a file
  /// saved with a download.
  static VideoPlayerController controllerFor(String url) {
    // No mixWithOthers: the option applies to the whole audio session, which
    // the music player shares, and would hide the lock-screen controls.
    final uri = Uri.parse(url);
    return uri.isScheme('file')
        ? VideoPlayerController.file(File.fromUri(uri))
        : VideoPlayerController.networkUrl(uri);
  }

  // Insertion-ordered: the first key is the oldest controller, evicted first
  // when the pool is full.
  final LinkedHashMap<String, VideoPlayerController> _controllers =
      LinkedHashMap<String, VideoPlayerController>();
  final Map<String, Future<void>> _warming = {};

  /// Pre-initializes [url] in the background. While paused the controller
  /// only holds the metadata and first frame: no audio, no visible UI.
  Future<void> warm(String url) {
    if (url.isEmpty) return Future.value();

    final existing = _controllers[url];
    if (existing != null) {
      if (!existing.value.hasError) {
        return _warming[url] ?? Future.value();
      }
      // A warm controller that errored must not be served later.
      _controllers.remove(url);
      _warming.remove(url);
      try {
        existing.dispose();
      } catch (_) {}
    }

    while (_controllers.length >= _maxWarmVideos) {
      final oldestKey = _controllers.keys.first;
      final oldest = _controllers.remove(oldestKey);
      _warming.remove(oldestKey);
      try {
        oldest?.dispose();
      } catch (_) {}
    }

    final controller = controllerFor(url);
    _controllers[url] = controller;

    final future = () async {
      try {
        await controller.initialize();
        if (!identical(_controllers[url], controller)) {
          await controller.dispose();
          return;
        }
        await controller.setLooping(true);
        await controller.setVolume(0);
        final size = controller.value.size;
        PlaybackLogService.instance.log(
          'CANVAS',
          'video caldo ${size.width.toInt()}x${size.height.toInt()}',
        );
      } catch (e) {
        if (identical(_controllers[url], controller)) {
          _controllers.remove(url);
        }
        try {
          await controller.dispose();
        } catch (_) {}
        PlaybackLogService.instance.error('CANVAS', 'warm fallito: $e');
      }
    }();
    _warming[url] = future;
    return future.whenComplete(() {
      if (identical(_warming[url], future)) _warming.remove(url);
    });
  }

  /// A controller that is already warm for [url], without waiting: null
  /// while it is still warming up or when there is none.
  VideoPlayerController? takeSync(String url) {
    if (_warming[url] != null) return null;
    final controller = _controllers[url];
    if (controller != null) {
      final value = controller.value;
      if (value.isInitialized && !value.hasError) {
        _controllers.remove(url);
        return controller;
      }
    }
    return null;
  }

  /// Hands a warm controller to the player widget, awaiting an in-flight
  /// warm-up if necessary. Returns null when no healthy controller matches
  /// [url].
  Future<VideoPlayerController?> take(String url) async {
    final pending = _warming[url];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final controller = _controllers.remove(url);
    _warming.remove(url);
    if (controller == null) return null;
    final value = controller.value;
    if (value.isInitialized && !value.hasError) return controller;
    try {
      await controller.dispose();
    } catch (_) {}
    return null;
  }

  /// Puts a still-healthy controller back after its widget unmounts (player
  /// sheet closed, canvas toggled off), so reopening is instant. Broken
  /// controllers are disposed instead.
  void release(String url, VideoPlayerController controller) {
    final value = controller.value;
    if (url.isEmpty || !value.isInitialized || value.hasError) {
      try {
        controller.dispose();
      } catch (_) {}
      return;
    }
    if (_controllers.containsKey(url)) {
      try {
        controller.dispose();
      } catch (_) {}
      return;
    }
    while (_controllers.length >= _maxWarmVideos) {
      final oldestKey = _controllers.keys.first;
      final oldest = _controllers.remove(oldestKey);
      _warming.remove(oldestKey);
      try {
        oldest?.dispose();
      } catch (_) {}
    }
    try {
      controller.pause();
    } catch (_) {}
    _controllers[url] = controller;
    PlaybackLogService.instance.log('CANVAS', 'video restituito al pool');
  }
}
