import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'player_style.dart';
import '../../../services/app_settings.dart';
import '../../../services/audio_handler.dart';
import '../../../services/ytmusic_service.dart';

/// Progress bar of the player: follows the position, and while it is being
/// dragged shows where the finger is instead.
class PlayerSeekBar extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final MediaItem mediaItem;

  const PlayerSeekBar({
    super.key,
    required this.audioHandler,
    required this.mediaItem,
  });

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  bool _isDragging = false;
  double? _dragValue;

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // The parent rebuilds this bar with every media item it publishes.
    final published = widget.mediaItem.duration ?? Duration.zero;
    final totalDuration = published > Duration.zero
        ? published
        : (widget.audioHandler.currentSong?.duration ?? Duration.zero);
    final maxMs = totalDuration.inMilliseconds.toDouble();
    final limit = maxMs > 0 ? maxMs : 1.0;
    final timeStyle = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
      color: playerInk.withValues(alpha: 0.72),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return ValueListenableBuilder<Duration>(
      valueListenable: widget.audioHandler.positionNotifier,
      builder: (context, position, _) {
        final curMs = position.inMilliseconds.toDouble().clamp(0.0, limit);
        final displayMs = (_isDragging && _dragValue != null)
            ? _dragValue!.clamp(0.0, limit)
            : curMs;

        final style = AppSettings.instance.seekBarStyle.value;
        final baseHeight = switch (style) {
          1 => 2.0,
          2 => 8.0,
          _ => 4.0,
        };
        final wavy = style == 3 && !_isDragging;
        final details = widget.audioHandler.currentStreamId == null
            ? null
            : YTMusicService.instance.streamDetails(widget.audioHandler.currentStreamId!);
        final format = [
          if (details?.codec != null)
            details!.codec!.startsWith('mp4a') ? 'AAC' : details.codec!.toUpperCase(),
          if (details?.bitrate != null) '${(details!.bitrate! / 1000).round()} kbps',
          if (details?.sampleRate != null) '${(details!.sampleRate! / 1000).toStringAsFixed(1)} kHz',
        ].join(' · ');
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: _isDragging ? baseHeight + 2 : baseHeight,
                trackShape: _SeekTrackShape(
                  wave: wavy ? position.inMilliseconds / 160 : null,
                ),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _isDragging ? 8 : (style == 1 ? 4.5 : 6),
                  elevation: 0,
                  pressedElevation: 0,
                ),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: playerInk,
                inactiveTrackColor: playerInk.withValues(alpha: 0.24),
                thumbColor: playerInk,
              ),
              child: SizedBox(
                height: 24,
                child: Slider(
                  value: displayMs,
                  max: limit,
                  onChangeStart: (val) {
                    setState(() {
                      _isDragging = true;
                      _dragValue = val;
                    });
                  },
                  onChanged: (val) {
                    setState(() => _dragValue = val);
                  },
                  onChangeEnd: (val) {
                    // The handler moves its position at once, so the
                    // thumb stays where it was released.
                    widget.audioHandler.seek(Duration(milliseconds: val.toInt()));
                    setState(() {
                      _isDragging = false;
                      _dragValue = null;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(Duration(milliseconds: displayMs.toInt())), style: timeStyle),
                if (AppSettings.instance.showCodec.value && format.isNotEmpty)
                  Text(format, style: timeStyle.copyWith(fontSize: 10.5)),
                Text(_fmt(totalDuration), style: timeStyle),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Track of the seek bar: it spans the whole width of the slider, so the
/// bar lines up with the title above and the times below.
class _SeekTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _SeekTrackShape({this.wave});

  /// The phase of the wave the played part is drawn as; null for a line.
  final double? wave;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 4;
    final top = offset.dy + (parentBox.size.height - height) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.height <= 0) return;
    final radius = Radius.circular(trackRect.height / 2);

    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = sliderTheme.inactiveTrackColor ?? Colors.white24,
    );

    final activeRight = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final activeRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      activeRight,
      trackRect.bottom,
    );
    if (activeRect.isEmpty) return;
    final phase = wave;
    if (phase == null) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        Paint()..color = sliderTheme.activeTrackColor ?? Colors.white,
      );
      return;
    }
    // The part already played as a wave that moves with the song.
    final middle = trackRect.center.dy;
    final path = Path()..moveTo(trackRect.left, middle);
    for (var x = trackRect.left; x <= activeRight; x += 1.5) {
      path.lineTo(x, middle + 3.2 * math.sin((x - trackRect.left) / 18 * 2 * math.pi - phase));
    }
    context.canvas.drawPath(
      path,
      Paint()
        ..color = sliderTheme.activeTrackColor ?? Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = trackRect.height * 0.8
        ..strokeCap = StrokeCap.round,
    );
  }
}
