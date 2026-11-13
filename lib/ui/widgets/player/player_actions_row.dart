import 'package:flutter/material.dart';
import '../../../services/audio_handler.dart';
import '../../theme/app_ambience.dart';
import '../../theme/app_icons.dart';
import '../devices_sheet.dart';
import 'player_style.dart';

/// Under the transport: where the music plays, the sleep timer when it is
/// set, the other sources, the lyrics and the queue.
class PlayerActionsRow extends StatelessWidget {
  const PlayerActionsRow({
    super.key,
    required this.audioHandler,
    required this.palette,
    required this.onSleepTimer,
    required this.onSources,
    required this.onLyrics,
    required this.onQueue,
  });

  final AudioPlayerHandler audioHandler;
  final AmbientPalette palette;
  final VoidCallback onSleepTimer;
  final VoidCallback onSources;
  final VoidCallback onLyrics;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final quiet = playerInk.withValues(alpha: 0.72);
    return Row(
      children: [
        // Where the music plays: here, or on another device
        // (its name then takes the room there is).
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: DevicesButton(
              remoteName: audioHandler.remoteNameNotifier,
              accent: palette.accent,
              idle: quiet,
            ),
          ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: audioHandler.sleepTimerNotifier,
          builder: (context, timerText, _) {
            if (timerText == null) return const SizedBox.shrink();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSleepTimer,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.sleepTimer,
                      size: 15, color: palette.accent),
                  const SizedBox(width: 4),
                  Text(
                    timerText,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: palette.accent,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Fonti audio alternative',
          onPressed: onSources,
          icon: Icon(AppIcons.sources, color: quiet, size: 23),
        ),
        IconButton(
          tooltip: 'Testo',
          onPressed: onLyrics,
          icon: Icon(AppIcons.lyrics, color: quiet, size: 23),
        ),
        IconButton(
          tooltip: 'Coda',
          padding: EdgeInsets.zero,
          alignment: Alignment.centerRight,
          onPressed: onQueue,
          icon: Icon(AppIcons.queue, color: quiet, size: 25),
        ),
      ],
    );
  }
}
