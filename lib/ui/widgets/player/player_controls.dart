import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/app_settings.dart';
import '../../../services/audio_handler.dart';
import '../../../services/playback_log_service.dart';
import '../../theme/app_ambience.dart';
import '../../theme/app_icons.dart';
import '../play_button.dart';
import 'player_style.dart';

/// Shuffle, previous, play / pause, next, repeat.
class PlayerTransportControls extends StatelessWidget {
  const PlayerTransportControls({
    super.key,
    required this.audioHandler,
    required this.playback,
    required this.palette,
    required this.isPlaying,
    required this.isLoading,
    required this.notify,
  });

  final AudioPlayerHandler audioHandler;
  final PlaybackState? playback;
  final AmbientPalette palette;
  final bool isPlaying;
  final bool isLoading;

  /// Shows a short message over the player.
  final void Function(String message) notify;

  @override
  Widget build(BuildContext context) {
    // Redrawn when the user shows or hides shuffle and repeat.
    return ValueListenableBuilder<bool>(
      valueListenable: AppSettings.instance.playerShowModes,
      builder: (context, showModes, _) => _row(context, showModes),
    );
  }

  Widget _row(BuildContext context, bool showModes) {
    return Row(
      mainAxisAlignment:
          showModes ? MainAxisAlignment.spaceBetween : MainAxisAlignment.spaceEvenly,
      children: [
        if (showModes)
        ValueListenableBuilder<bool>(
          valueListenable: audioHandler.smartShuffleNotifier,
          builder: (context, smart, _) {
            final shuffled = playback?.shuffleMode ==
                    AudioServiceShuffleMode.all ||
                playback?.shuffleMode == AudioServiceShuffleMode.group;
            return ToggleGlyph(
              icon: AppIcons.shuffle,
              active: shuffled || smart,
              badge: smart ? AppIcons.smart : null,
              color: palette.accent,
              tooltip: smart
                  ? 'Disattiva Smart Shuffle'
                  : (shuffled ? 'Attiva Smart Shuffle' : 'Attiva casuale'),
              onPressed: () {
                // Cycle: off -> shuffle -> Smart Shuffle -> off.
                if (smart) {
                  PlaybackLogService.instance.log('UI', 'player: shuffle off');
                  audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
                  notify('Riproduzione casuale disattivata');
                } else if (shuffled) {
                  PlaybackLogService.instance.log('UI', 'player: smart shuffle on');
                  audioHandler.setSmartShuffle(true);
                  notify('Smart Shuffle: aggiunge brani consigliati alla coda');
                } else {
                  PlaybackLogService.instance.log('UI', 'player: shuffle on');
                  audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
                }
              },
            );
          },
        ),
        IconButton(
          tooltip: 'Brano precedente',
          iconSize: 44,
          padding: EdgeInsets.zero,
          onPressed: () {
            HapticFeedback.selectionClick();
            PlaybackLogService.instance.log('UI', 'player: prev');
            audioHandler.skipToPrevious();
          },
          icon: Icon(AppIcons.previous, color: playerInk),
        ),
        // White with a dark icon, as Spotify's: the colour of
        // the song stays on the background.
        PlayButton(
          color: playerInk,
          size: 68,
          playing: isPlaying,
          loading: isLoading,
          onPressed: () {
            HapticFeedback.selectionClick();
            PlaybackLogService.instance
                .log('UI', isPlaying ? 'player: pausa' : 'player: play');
            isPlaying
                ? audioHandler.pause()
                : audioHandler.play();
          },
        ),
        IconButton(
          tooltip: 'Brano successivo',
          iconSize: 44,
          padding: EdgeInsets.zero,
          onPressed: () {
            HapticFeedback.selectionClick();
            PlaybackLogService.instance.log('UI', 'player: next');
            audioHandler.skipToNext();
          },
          icon: Icon(AppIcons.next, color: playerInk),
        ),
        if (showModes)
        Builder(
          builder: (context) {
            final mode =
                playback?.repeatMode ?? AudioServiceRepeatMode.none;
            return ToggleGlyph(
              icon: mode == AudioServiceRepeatMode.one
                  ? AppIcons.repeatOne
                  : AppIcons.repeat,
              active: mode != AudioServiceRepeatMode.none,
              color: palette.accent,
              tooltip: 'Ripeti',
              onPressed: () {
                PlaybackLogService.instance
                    .log('UI', 'player: repeat toggle');
                final nextMode = mode == AudioServiceRepeatMode.none
                    ? AudioServiceRepeatMode.all
                    : (mode == AudioServiceRepeatMode.all
                        ? AudioServiceRepeatMode.one
                        : AudioServiceRepeatMode.none);
                audioHandler.setRepeatMode(nextMode);
              },
            );
          },
        ),
      ],
    );
  }
}

/// Shuffle and repeat: a glyph that lights up in the cover's color, with a
/// dot under it, while its mode is on.
class ToggleGlyph extends StatelessWidget {
  const ToggleGlyph({
    super.key,
    required this.icon,
    required this.active,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.badge,
  });

  final IconData icon;
  final bool active;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  /// Small glyph over the corner (Smart Shuffle).
  final IconData? badge;

  @override
  Widget build(BuildContext context) {
    final tint = active ? color : playerInk;
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onPressed: () {
        HapticFeedback.selectionClick();
        onPressed();
      },
      icon: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 26, color: tint),
            if (badge != null)
              Positioned(
                right: 0,
                top: 2,
                child: Icon(badge, size: 13, color: tint),
              ),
            if (active)
              Positioned(
                bottom: 0,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
