import 'package:flutter/cupertino.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'bounce_button.dart';

/// Round play / pause button. Its color is whatever the artwork around it
/// gives; the glyph picks the ink that reads on it.
class PlayButton extends StatelessWidget {
  const PlayButton({
    super.key,
    required this.color,
    required this.playing,
    required this.onPressed,
    this.size = 56,
    this.loading = false,
  });

  final Color color;
  final bool playing;
  final bool loading;
  final double size;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ink = AppTheme.inkOn(color);
    return Semantics(
      button: true,
      label: playing ? 'Pausa' : 'Riproduci',
      child: BounceButton(
        scaleDown: 0.93,
        onPressed: onPressed,
        child: AnimatedContainer(
          duration: AppMotion.ambience,
          curve: Curves.easeOut,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: onPressed == null ? color.withValues(alpha: 0.4) : color,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: loading
              ? CupertinoActivityIndicator(color: ink, radius: size * 0.17)
              : AnimatedSwitcher(
                  duration: AppMotion.fast,
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    playing ? AppIcons.pause : AppIcons.play,
                    key: ValueKey<bool>(playing),
                    size: size * 0.6,
                    color: ink,
                  ),
                ),
        ),
      ),
    );
  }
}
