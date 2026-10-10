import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:audio_service/audio_service.dart';

import '../../services/audio_handler.dart';
import '../../services/auth_service.dart';
import '../../services/playback_log_service.dart';
import '../app_navigation.dart';
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';
import 'app_cover.dart';

/// The color of what is playing (or a hint of the accent, in silence),
/// washing down from the top of a tab: browsing stays connected to the
/// music.
class NowPlayingBackdrop extends StatelessWidget {
  const NowPlayingBackdrop({
    super.key,
    required this.audioHandler,
    this.intensity = 0.9,
    this.extent = 0.4,
  });

  final AudioPlayerHandler audioHandler;
  final double intensity;
  final double extent;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      initialData: audioHandler.mediaItem.value,
      builder: (context, snapshot) => AmbientBackdrop(
        artworkUrl: snapshot.data?.artUri?.toString(),
        intensity: intensity,
        extent: extent,
      ),
    );
  }
}

/// Header pinned at the top of a tab. It is transparent while the page is
/// at its top, so the color behind shows through, and turns solid as soon
/// as content scrolls under it.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.solid,
    required this.child,
    this.bottom,
    this.backdrop,
  });

  static const double height = 54;

  /// Height the bar takes on screen, status bar included.
  static double extent(BuildContext context, {double bottom = 0}) =>
      MediaQuery.paddingOf(context).top + height + bottom;

  /// Tells the bar when the page under it is no longer at its top. Use it
  /// as the `onNotification` of a [NotificationListener] around the page.
  static bool Function(ScrollNotification) watch(ValueNotifier<bool> solid) =>
      (notification) {
        if (notification.metrics.axis == Axis.vertical && notification.depth == 0) {
          solid.value = notification.metrics.pixels > 4;
        }
        return false;
      };

  final ValueListenable<bool> solid;
  final Widget child;

  /// A second row (filter chips), with its own height.
  final Widget? bottom;

  /// The wash painted behind the whole page (the same widget, built again):
  /// the solid bar repeats its top part, so the bar and the page under it
  /// stay one surface.
  final Widget? backdrop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.sizeOf(context).height;
    return ClipRect(
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: screenHeight,
            child: ValueListenableBuilder<bool>(
              valueListenable: solid,
              builder: (context, isSolid, surface) => AnimatedOpacity(
                opacity: isSolid ? 1 : 0,
                duration: AppMotion.fast,
                child: surface,
              ),
              child: ColoredBox(color: cs.surfaceDim, child: backdrop),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: child,
                  ),
                ),
                ?bottom,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The user's picture (or initial): opens the Settings.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key, this.size = 34});

  final double size;

  static void openSettings(BuildContext context) {
    final builder = AppNavigation.settingsBuilder;
    if (builder == null) return;
    PlaybackLogService.instance.log('UI', 'apri impostazioni');
    // Above the tabs: the Settings belong to none of them, and must not be
    // found again inside the tab they were opened from.
    Navigator.of(context, rootNavigator: true)
        .push(CupertinoPageRoute<void>(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Profilo e impostazioni',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openSettings(context),
        child: ListenableBuilder(
          listenable: AuthService.instance,
          builder: (context, _) {
            final user = AuthService.instance.currentUser;
            final photo = user?.photoUrl;
            if (photo != null && photo.isNotEmpty) {
              return AppCover(url: photo, size: size, circle: true);
            }
            final name = user?.displayName?.trim() ?? '';
            return Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
              child: Text(
                name.isEmpty ? 'T' : name.characters.first.toUpperCase(),
                style: TextStyle(
                  color: cs.onPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: size * 0.44,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
