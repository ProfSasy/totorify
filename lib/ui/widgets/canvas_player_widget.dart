import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/canvas_video_pool.dart';
import '../../services/playback_log_service.dart';

class CanvasPlayerWidget extends StatefulWidget {
  final String videoUrl;
  final bool isPlaying;

  /// Shown under the video until it is ready. Without one the widget is
  /// transparent meanwhile, and the owner decides what to show (see
  /// [onReady]).
  final Widget? placeholder;
  final double borderRadius;

  /// Called once the video can be shown: its first frame is decoded.
  final VoidCallback? onReady;

  /// Called when the video cannot be initialized/played, so the owner can
  /// refresh the URL and try again.
  final VoidCallback? onFailed;

  /// When it returns true on dispose, the (healthy) controller is handed
  /// back to [CanvasVideoPool] instead of being destroyed: reopening the
  /// player or re-enabling the canvas becomes instant. The owner decides —
  /// e.g. false once the track changed, so a stale video never stays warm.
  final bool Function()? keepWarmWhenDisposed;

  const CanvasPlayerWidget({
    super.key,
    required this.videoUrl,
    required this.isPlaying,
    this.placeholder,
    this.borderRadius = 22,
    this.onReady,
    this.onFailed,
    this.keepWarmWhenDisposed,
  });

  @override
  State<CanvasPlayerWidget> createState() => _CanvasPlayerWidgetState();
}

class _CanvasPlayerWidgetState extends State<CanvasPlayerWidget> {
  VideoPlayerController? _controller;
  bool _isReady = false;
  bool _failedNotified = false;

  
  @override
  void initState() {
    super.initState();
    final warmSync = CanvasVideoPool.instance.takeSync(widget.videoUrl);
    if (warmSync != null) {
      _controller = warmSync;
      _isReady = true;
      warmSync.addListener(_onControllerTick);
      try {
        if (widget.isPlaying) warmSync.play();
      } catch (_) {}
      // Not during the build that is creating this widget.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call();
      });
    } else {
      _initVideo();
    }
  }


  @override
  void didUpdateWidget(CanvasPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _disposeController();
      _failedNotified = false;
      _initVideo();
    } else if (_controller != null && _isReady) {
      if (widget.isPlaying && !_controller!.value.isPlaying) {
        _controller!.play();
      } else if (!widget.isPlaying && _controller!.value.isPlaying) {
        _controller!.pause();
      }
    }
  }

  /// Surfaces errors that happen after initialization (dead stream, stalled
  /// frames): the owner swaps in another candidate instead of leaving a
  /// frozen frame on screen.
  void _onControllerTick() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (controller.value.hasError && !_failedNotified) {
      _failedNotified = true;
      PlaybackLogService.instance.log('CANVAS', 'errore video a runtime');
      widget.onFailed?.call();
    }
  }

  void _adoptController(VideoPlayerController controller) {
    _controller = controller;
    controller.addListener(_onControllerTick);
  }

  Future<void> _initVideo() async {
    // Adopt the controller pre-warmed by the pool: the first frame is already
    // decoded, so the canvas appears instantly.
    final warm = await CanvasVideoPool.instance.take(widget.videoUrl);
    if (warm != null) {
      if (!mounted) {
        await warm.dispose();
        return;
      }
      _adoptController(warm);
      try {
        if (widget.isPlaying) await warm.play();
      } catch (_) {}
      if (mounted && identical(_controller, warm)) {
        setState(() => _isReady = true);
        widget.onReady?.call();
      }
      PlaybackLogService.instance.log('CANVAS', 'video mostrato (pool)');
      return;
    }

    if (Uri.tryParse(widget.videoUrl) == null) return;

    VideoPlayerController? controller;
    try {
      controller = CanvasVideoPool.controllerFor(widget.videoUrl);
      _adoptController(controller);

      await controller.initialize();
      if (!mounted || !identical(_controller, controller)) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(0.0); // Muta volume audio per riprodurre solo il visual video
      final size = controller.value.size;
      PlaybackLogService.instance.log(
        'CANVAS',
        'video pronto ${size.width.toInt()}x${size.height.toInt()}',
      );

      if (mounted) {
        if (widget.isPlaying) {
          await controller.play();
        }

        // Transizione morbida di dissolvenza (crossfade):
        // 1. Monta il widget nel tree a opacity 0.0
        setState(() {
          _isReady = false;
        });

        // 2. Al frame successivo anima a opacity 1.0 per una dissolvenza fluida sopra la copertina
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controller != null && _controller!.value.isInitialized) {
            setState(() {
              _isReady = true;
            });
            widget.onReady?.call();
          }
        });
      }
    } catch (e) {
      debugPrint('CanvasPlayerWidget error: $e');
      PlaybackLogService.instance.log('CANVAS', 'errore video: $e');
      if (mounted && controller != null && identical(_controller, controller)) {
        setState(() {
          _isReady = false;
        });
      }
      if (!_failedNotified) {
        _failedNotified = true;
        widget.onFailed?.call();
      }
    }
  }

  void _disposeController() {
    _isReady = false;
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_onControllerTick);
    controller?.pause();
    controller?.dispose();
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    _isReady = false;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      // Keep the decoded video warm when the owner says it is still the
      // current canvas: closing/reopening the player stays instant.
      if (widget.keepWarmWhenDisposed?.call() ?? false) {
        CanvasVideoPool.instance.release(widget.videoUrl, controller);
      } else {
        controller.pause();
        controller.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasInitialized =
        _controller != null && _controller!.value.isInitialized;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?widget.placeholder,

          // The video fades in over its placeholder; without one the owner
          // does the fading, and it is simply there.
          if (hasInitialized)
            AnimatedOpacity(
              opacity: _isReady ? 1.0 : 0.0,
              duration: widget.placeholder == null
                  ? Duration.zero
                  : const Duration(milliseconds: 500),
              curve: Curves.easeInOut,
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller!.value.size.width > 0
                        ? _controller!.value.size.width
                        : 16,
                    height: _controller!.value.size.height > 0
                        ? _controller!.value.size.height
                        : 9,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
