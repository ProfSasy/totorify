import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'app_cover.dart';
import 'favorite_button.dart';
import 'player_sheet.dart';

/// The bar of what is playing, above the tab bar. It wears the color of the
/// cover: tap or swipe up to open the player, swipe sideways to change
/// track.
class MiniPlayer extends StatelessWidget {
  final AudioPlayerHandler audioHandler;

  const MiniPlayer({super.key, required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, mediaSnapshot) {
        final mediaItem = mediaSnapshot.data;
        if (mediaItem == null) return const SizedBox.shrink();

        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, playbackSnapshot) {
            final isPlaying = playbackSnapshot.data?.playing ?? false;
            final processingState = playbackSnapshot.data?.processingState ??
                AudioProcessingState.idle;
            final isLoading =
                processingState == AudioProcessingState.loading ||
                    processingState == AudioProcessingState.buffering;

            return AmbientTint(
              artworkUrl: mediaItem.artUri?.toString(),
              fallback: Theme.of(context).colorScheme.primary,
              builder: (context, palette) => _MiniPlayerBody(
                audioHandler: audioHandler,
                mediaItem: mediaItem,
                isPlaying: isPlaying,
                isLoading: isLoading,
                palette: palette,
              ),
            );
          },
        );
      },
    );
  }
}

class _MiniPlayerBody extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  final MediaItem mediaItem;
  final bool isPlaying;
  final bool isLoading;
  final AmbientPalette palette;

  const _MiniPlayerBody({
    required this.audioHandler,
    required this.mediaItem,
    required this.isPlaying,
    required this.isLoading,
    required this.palette,
  });

  static const Color _ink = Colors.white;

  void _open(BuildContext context) {
    PlaybackLogService.instance.log('UI', 'mini player: apri');
    PlayerSheet.show(context, audioHandler);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -150) _open(context);
      },
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -200) {
          HapticFeedback.mediumImpact();
          PlaybackLogService.instance.log('UI', 'mini swipe: next');
          audioHandler.skipToNext();
        } else if (velocity > 200) {
          HapticFeedback.mediumImpact();
          PlaybackLogService.instance.log('UI', 'mini swipe: prev');
          audioHandler.skipToPrevious();
        }
      },
      child: AnimatedContainer(
        duration: AppMotion.ambience,
        curve: Curves.easeOut,
        margin: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, 6),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: AppRadius.floating,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, 2, 6),
              child: Row(
                children: [
                  AppCover(url: mediaItem.artUri?.toString(), size: 40),
                  const SizedBox(width: 10),

                  // ── Title & Artist (marquee on overflow) ─────────────────
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MarqueeText(
                          mediaItem.title,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.1,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            ValueListenableBuilder<List<Song>>(
                              valueListenable:
                                  StorageService.instance.downloadsNotifier,
                              builder: (context, _, _) => StorageService.instance
                                      .isDownloaded(mediaItem.id)
                                  ? Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Icon(AppIcons.downloaded,
                                          size: 13, color: palette.accent),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            Expanded(
                              child: Text(
                                mediaItem.artist ?? 'Artista',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: _ink.withValues(alpha: 0.72),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  FavoriteButton(
                    song: () => audioHandler.currentSong,
                    activeColor: palette.accent,
                    size: 23,
                    source: 'mini',
                  ),

                  // ── Play / Pause ──────────────────────────────────────────
                  SizedBox(
                    width: 44,
                    height: 40,
                    child: isLoading
                        ? const Center(
                            child: CupertinoActivityIndicator(
                              color: _ink,
                              radius: 9,
                            ),
                          )
                        : IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: isPlaying ? 'Pausa' : 'Riproduci',
                            onPressed: () {
                              PlaybackLogService.instance.log(
                                'UI',
                                isPlaying ? 'mini: pausa' : 'mini: play',
                              );
                              isPlaying
                                  ? audioHandler.pause()
                                  : audioHandler.play();
                            },
                            icon: AnimatedSwitcher(
                              duration: AppMotion.fast,
                              transitionBuilder: (child, anim) =>
                                  ScaleTransition(scale: anim, child: child),
                              child: Icon(
                                isPlaying ? AppIcons.pause : AppIcons.play,
                                key: ValueKey<bool>(isPlaying),
                                color: _ink,
                                size: 30,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            _ProgressBar(audioHandler: audioHandler, mediaItem: mediaItem),
          ],
        ),
      ),
    );
  }
}

/// Isolated progress bar widget — rebuilds only on position/duration changes.
class _ProgressBar extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  final MediaItem mediaItem;

  const _ProgressBar({required this.audioHandler, required this.mediaItem});

  @override
  Widget build(BuildContext context) {
    final published = mediaItem.duration ?? Duration.zero;
    final total = published > Duration.zero
        ? published
        : (audioHandler.currentSong?.duration ?? Duration.zero);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: SizedBox(
          height: 2,
          child: ColoredBox(
            // Hairline track keeps the bar readable at 0%.
            color: Colors.white.withValues(alpha: 0.22),
            child: ValueListenableBuilder<Duration>(
              valueListenable: audioHandler.positionNotifier,
              builder: (context, position, _) {
                final progress = total.inMilliseconds > 0
                    ? (position.inMilliseconds / total.inMilliseconds)
                        .clamp(0.0, 1.0)
                    : 0.0;
                return FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: const ColoredBox(color: Colors.white),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText(this.text, {required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final overflow =
            (painter.width - constraints.maxWidth).clamp(0.0, double.infinity);
        painter.dispose();
        if (overflow <= 0) {
          _overflow = 0;
          _controller.stop();
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        if (_overflow != overflow && !_controller.isAnimating) {
          _overflow = overflow;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _overflow > 0) _controller.repeat(reverse: true);
          });
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(
                -_overflow * Curves.easeInOut.transform(_controller.value),
                0,
              ),
              child: child,
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              fit: OverflowBoxFit.deferToChild,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: widget.style,
              ),
            ),
          ),
        );
      },
    );
  }
}
