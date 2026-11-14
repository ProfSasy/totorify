import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../../services/playback_log_service.dart';
import '../../theme/app_ambience.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_tokens.dart';
import 'player_style.dart';

/// Pill that switches between the Canvas video and the cover.
class CanvasToggle extends StatelessWidget {
  const CanvasToggle({
    super.key,
    required this.palette,
    required this.showCanvas,
    required this.enabled,
    required this.isLoading,
    required this.canvasShown,
    required this.onToggle,
  });

  final AmbientPalette palette;

  /// The user wants the Canvas rather than the cover.
  final bool showCanvas;

  /// The track has a Canvas.
  final bool enabled;

  /// The Canvas is being looked up.
  final bool isLoading;

  /// The Canvas is on screen in place of the cover.
  final bool canvasShown;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // Looking the Canvas up, or waiting for its first frame.
    final waiting = isLoading || (showCanvas && enabled && !canvasShown);
    final tint = showCanvas && enabled ? palette.accent : playerInk;
    return Semantics(
      button: true,
      label: showCanvas
          ? 'Mostra copertina invece del Canvas'
          : 'Mostra Canvas invece della copertina',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled && !isLoading
            ? () {
                HapticFeedback.lightImpact();
                PlaybackLogService.instance.log(
                    'UI', showCanvas ? 'player: canvas off' : 'player: canvas on');
                onToggle();
              }
            : null,
        child: Padding(
          // Extra transparent padding widens the touch target beyond the pill.
          padding: const EdgeInsets.all(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: PlayerStyle.shade.withValues(alpha: 0.38),
              borderRadius: AppRadius.chip,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (waiting)
                  Padding(
                    padding: EdgeInsets.only(right: 1),
                    child: CupertinoActivityIndicator(radius: 6, color: playerInk),
                  )
                else
                  Icon(
                    showCanvas ? AppIcons.canvas : AppIcons.cover,
                    size: 15,
                    color: tint,
                  ),
                const SizedBox(width: 5),
                Text(
                  showCanvas || isLoading ? 'Canvas' : 'Copertina',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: tint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
