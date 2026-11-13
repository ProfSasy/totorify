import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'app_ambience.dart';

/// The colors of the cover of what is playing, for the app to take when
/// the user wants its colors to follow the music.
///
/// It only says which palette is current; whether the theme uses it is the
/// choice of the user (`AppSettings.dynamicColor`).
class DynamicColor {
  DynamicColor._();
  static final DynamicColor instance = DynamicColor._();

  /// The palette of the cover of the current song, or null when nothing
  /// plays, the cover cannot be read, or it has no color of its own.
  final ValueNotifier<AmbientPalette?> palette = ValueNotifier<AmbientPalette?>(null);

  StreamSubscription<MediaItem?>? _subscription;
  String? _url;

  /// Follows the songs published on [mediaItems].
  void follow(Stream<MediaItem?> mediaItems) {
    _subscription?.cancel();
    _subscription = mediaItems.listen((item) => show(item?.artUri?.toString()));
  }

  /// Takes the colors of the artwork at [url].
  void show(String? url) {
    if (url == _url) return;
    _url = url;
    if (url == null || url.isEmpty) {
      palette.value = null;
      return;
    }
    final cached = AmbientPaletteService.instance.getCached(url);
    if (cached != null) {
      palette.value = paletteToUse(cached);
      return;
    }
    // The colors of the previous song stay until those of the new one are
    // known: the app never flashes back to its own color in between.
    unawaited(AmbientPaletteService.instance.load(url).then((loaded) {
      if (_url != url) return;
      palette.value = paletteToUse(loaded);
    }));
  }

  /// A palette is used only when it comes from real artwork with a color:
  /// a black and white cover leaves the app its own color.
  @visibleForTesting
  static AmbientPalette? paletteToUse(AmbientPalette? palette) =>
      (palette == null ||
              !palette.fromArtwork ||
              palette.accent == AmbientPalette.neutral.accent)
          ? null
          : palette;
}
