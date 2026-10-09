import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/storage_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'player_sheet.dart';

/// Floating glass mini player. Its border, glow and progress bar are tinted
/// with the ambient palette extracted from the current artwork, so the bar
/// "wears" the colors of the track that is playing.
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.lg);

    return GestureDetector(
      onTap: () {
        PlaybackLogService.instance.log('UI', 'mini player: apri');
        PlayerSheet.show(context, audioHandler);
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
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: 0.82),
          borderRadius: radius,
          border: Border.all(
            color: palette.primary.withValues(alpha: 0.35),
          ),
          boxShadow: [
            BoxShadow(
              color: palette.glow.withValues(alpha: 0.22),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg - 1),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
                  child: Row(
                    children: [
                      // ── Artwork ──────────────────────────────────────────
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: mediaItem.artUri?.toString() ?? '',
                          width: 46,
                          height: 46,
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 300),
                          fadeOutDuration: const Duration(milliseconds: 150),
                          placeholder: (_, _) => _coverFallback(cs),
                          errorWidget: (_, _, _) => _coverFallback(cs),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // ── Title & Artist (marquee on overflow) ─────────────
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _MarqueeText(
                              mediaItem.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                ValueListenableBuilder(
                                  valueListenable: StorageService
                                      .instance.downloadsNotifier,
                                  builder: (context, _, _) {
                                    if (StorageService.instance
                                        .isDownloaded(mediaItem.id)) {
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 5),
                                        child: Icon(
                                          CupertinoIcons
                                              .arrow_down_circle_fill,
                                          size: 12,
                                          color: palette.primary,
                                        ),
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                ),
                                Expanded(
                                  child: Text(
                                    mediaItem.artist ?? 'Artista',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // ── Favorite ─────────────────────────────────────────
                      ValueListenableBuilder(
                        valueListenable:
                            StorageService.instance.favoritesNotifier,
                        builder: (context, _, _) {
                          final isFav = StorageService.instance
                              .isFavorite(mediaItem.id);
                          return IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: Icon(
                              isFav
                                  ? CupertinoIcons.heart_fill
                                  : CupertinoIcons.heart,
                              color: isFav
                                  ? palette.primary
                                  : cs.onSurfaceVariant,
                              size: 20,
                            ),
                            onPressed: () {
                              PlaybackLogService.instance
                                  .log('UI', 'mini: preferito');
                              final currentSong = audioHandler.currentSong;
                              if (currentSong != null) {
                                StorageService.instance
                                    .toggleFavorite(currentSong);
                              }
                            },
                          );
                        },
                      ),

                      // ── Play / Pause (gradient capsule) ──────────────────
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: isLoading
                            ? Center(
                                child: CupertinoActivityIndicator(
                                  color: cs.onSurface,
                                  radius: 10,
                                ),
                              )
                            : Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: AppTheme.primaryGradient(cs),
                                  boxShadow: [
                                    BoxShadow(
                                      color: cs.primary
                                          .withValues(alpha: 0.35),
                                      blurRadius: 14,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
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
                                        ScaleTransition(
                                      scale: anim,
                                      child: child,
                                    ),
                                    child: Icon(
                                      isPlaying
                                          ? CupertinoIcons.pause_fill
                                          : CupertinoIcons.play_fill,
                                      key: ValueKey<bool>(isPlaying),
                                      color: cs.onPrimary,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                      ),

                      // ── Next ─────────────────────────────────────────────
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        icon: Icon(
                          CupertinoIcons.forward_fill,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                        onPressed: () {
                          PlaybackLogService.instance.log('UI', 'mini: next');
                          audioHandler.skipToNext();
                        },
                      ),
                    ],
                  ),
                ),

                // ── Progress Bar (ambient gradient) ────────────────────────
                _ProgressBar(
                  audioHandler: audioHandler,
                  mediaItem: mediaItem,
                  palette: palette,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _coverFallback(ColorScheme cs) => Container(
        width: 46,
        height: 46,
        color: cs.surfaceContainerHigh,
        child: Icon(
          CupertinoIcons.music_note,
          color: cs.onSurfaceVariant,
          size: 20,
        ),
      );
}

/// Isolated progress bar widget — rebuilds only on position/duration changes.
class _ProgressBar extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  final MediaItem mediaItem;
  final AmbientPalette palette;

  const _ProgressBar({
    required this.audioHandler,
    required this.mediaItem,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, itemSnapshot) {
        final published = (itemSnapshot.data ?? mediaItem).duration ?? Duration.zero;
        final total = published > Duration.zero
            ? published
            : (audioHandler.currentSong?.duration ?? Duration.zero);

        return ValueListenableBuilder<Duration>(
          valueListenable: audioHandler.positionNotifier,
          builder: (context, pos, _) {

            double progress = 0.0;
            if (total.inMilliseconds > 0) {
              progress =
                  (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
            }

            return ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(AppRadius.lg - 1),
              ),
              child: SizedBox(
                height: 2.5,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Hairline track keeps the bar readable at 0%.
                    ColoredBox(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.16),
                    ),
                    ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (rect) => LinearGradient(
                        colors: [palette.primary, palette.secondary],
                      ).createShader(rect),
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                        minHeight: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
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
        )..layout();
        final overflow =
            (painter.width - constraints.maxWidth).clamp(0.0, double.infinity);
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
            child: Text(widget.text, maxLines: 1, style: widget.style),
          ),
        );
      },
    );
  }
}
