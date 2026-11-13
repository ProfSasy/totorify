import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../../../services/app_settings.dart';
import '../../theme/app_tokens.dart';
import '../app_cover.dart';
import 'player_style.dart';

/// The cover of the track. It fades out as the Canvas fades in behind it.
class PlayerCover extends StatelessWidget {
  const PlayerCover({
    super.key,
    required this.mediaItem,
    required this.hasCanvas,
    required this.hasSwitch,
    required this.isPlaying,
  });

  final MediaItem mediaItem;

  /// True when the Canvas takes the place of the cover.
  final bool hasCanvas;

  /// True when room is left for the Canvas / cover switch above the cover.
  final bool hasSwitch;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    // Redrawn when the user changes the shape of the cover.
    return ValueListenableBuilder<int>(
      valueListenable: AppSettings.instance.playerCoverStyle,
      builder: (context, style, _) => _cover(context, style),
    );
  }

  /// [style] is 0 as designed, 1 a disc, 2 smaller.
  Widget _cover(BuildContext context, int style) {
    final disc = style == 1;
    return AnimatedSwitcher(
      duration: playerCanvasFade,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, ?currentChild],
      ),
      child: hasCanvas
        ? const SizedBox.expand(key: ValueKey('canvas_space'))
        : Padding(
            key: const ValueKey('cover_space'),
            padding: EdgeInsets.fromLTRB(
              AppSpacing.xl,
              hasSwitch ? 46 : AppSpacing.sm,
              AppSpacing.xl,
              AppSpacing.sm,
            ),
            child: LayoutBuilder(
              builder: (context, cover) {
                final room = math.min(cover.maxWidth, cover.maxHeight);
                if (room < 120) return const SizedBox.shrink();
                final dimension = style == 2 ? room * 0.76 : room;
                return Center(
                  child: AnimatedScale(
                    scale: isPlaying ? 1 : 0.93,
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: DecoratedBox(
                        key: ValueKey('player_cover_${mediaItem.id}'),
                        decoration: BoxDecoration(
                          shape: disc ? BoxShape.circle : BoxShape.rectangle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.45),
                              blurRadius: 36,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: AppCover(
                          url: mediaItem.artUri?.toString(),
                          size: dimension,
                          radius: AppRadius.md,
                          circle: disc,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
    );
  }
}
