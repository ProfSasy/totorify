import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'app_tokens.dart';

/// The colors a piece of artwork lends to the interface around it: the
/// player, the mini player, the header of a collection and their buttons.
@immutable
class AmbientPalette {
  /// Vivid color of the artwork, light enough to be a button or an active
  /// icon on a dark surface.
  final Color accent;

  /// Dark shade of the same hue: white text stays readable on it. Background
  /// of the player and of the mini player.
  final Color surface;

  /// Darker still, where a gradient that starts from [surface] ends.
  final Color deep;

  /// Whether the palette was extracted from real artwork (vs. the fallback
  /// built from the user's accent).
  final bool fromArtwork;

  const AmbientPalette({
    required this.accent,
    required this.surface,
    required this.deep,
    this.fromArtwork = false,
  });

  /// For artwork without a color of its own (black and white covers).
  static const AmbientPalette neutral = AmbientPalette(
    accent: Color(0xFFF2F2F2),
    surface: Color(0xFF3A3A3A),
    deep: Color(0xFF181818),
    fromArtwork: true,
  );

  /// Ink that stays readable on [accent].
  Color get onAccent => AppTheme.inkOn(accent);

  /// Shown while the artwork is being read: buttons in the user's accent on
  /// a surface without a color yet, so the real one blooms out of gray
  /// instead of replacing a wrong one.
  factory AmbientPalette.pending(Color accent) => AmbientPalette(
        accent: accent,
        surface: const Color(0xFF2C2C2C),
        deep: const Color(0xFF161616),
      );

  /// Used until the artwork is read, and when there is none: the user's
  /// accent, with a surface in its hue.
  factory AmbientPalette.fallback(Color accent) {
    final derived = AmbientPalette.fromColor(accent);
    return AmbientPalette(
      accent: accent,
      surface: derived.surface,
      deep: derived.deep,
    );
  }

  /// Builds the roles around one color of the artwork.
  factory AmbientPalette.fromColor(Color base, {bool fromArtwork = false}) {
    final hsl = HSLColor.fromColor(base);
    final saturation = hsl.saturation;
    // A color too dull to give a hue stays gray instead of turning red
    // (the hue of a gray is zero).
    if (saturation < 0.08) {
      return AmbientPalette(
        accent: neutral.accent,
        surface: neutral.surface,
        deep: neutral.deep,
        fromArtwork: fromArtwork,
      );
    }

    var accent = hsl
        .withSaturation(saturation.clamp(0.45, 0.92))
        .withLightness(0.58);
    // Blues and purples are dark at the same lightness: lift them until
    // they stand out on a black background.
    while (accent.toColor().computeLuminance() < 0.22 && accent.lightness < 0.86) {
      accent = accent.withLightness(accent.lightness + 0.03);
    }

    var surface = hsl
        .withSaturation(saturation.clamp(0.28, 0.62))
        .withLightness(0.27);
    // Yellows and greens are bright at the same lightness: lower them
    // until white text is comfortable to read.
    while (surface.toColor().computeLuminance() > 0.115 && surface.lightness > 0.12) {
      surface = surface.withLightness(surface.lightness - 0.02);
    }
    final surfaceColor = surface.toColor();

    return AmbientPalette(
      accent: accent.toColor(),
      surface: surfaceColor,
      deep: Color.lerp(surfaceColor, Colors.black, 0.62)!,
      fromArtwork: fromArtwork,
    );
  }

  static const int _hueBins = 24;

  /// Reads the palette from the pixels of an image ([rgba], four bytes per
  /// pixel). The color that covers the most area wins, weighted by how
  /// saturated it is: a cover is recognised by its color, not by its black.
  static AmbientPalette fromPixels(Uint8List rgba) {
    final weight = List<double>.filled(_hueBins, 0);
    final red = List<double>.filled(_hueBins, 0);
    final green = List<double>.filled(_hueBins, 0);
    final blue = List<double>.filled(_hueBins, 0);
    var pixels = 0;
    var colored = 0;

    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      pixels++;
      final high = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final low = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (high < 36) continue; // near black
      final value = high / 255;
      final saturation = (high - low) / high;
      if (saturation < 0.2) continue; // gray or white
      colored++;

      final delta = (high - low).toDouble();
      double hue;
      if (high == r) {
        hue = ((g - b) / delta) % 6;
      } else if (high == g) {
        hue = (b - r) / delta + 2;
      } else {
        hue = (r - g) / delta + 4;
      }
      final bin = (hue / 6 * _hueBins).floor() % _hueBins;
      final w = saturation * saturation * (0.3 + 0.7 * value);
      weight[bin] += w;
      red[bin] += w * r;
      green[bin] += w * g;
      blue[bin] += w * b;
    }

    if (pixels == 0 || colored < pixels * 0.04) return neutral;

    // Neighbouring hues belong to the same color of the cover.
    var best = 0;
    var bestScore = -1.0;
    for (var i = 0; i < _hueBins; i++) {
      final score = weight[i] +
          0.6 * (weight[(i + 1) % _hueBins] + weight[(i - 1 + _hueBins) % _hueBins]);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    var w = 0.0, r = 0.0, g = 0.0, b = 0.0;
    for (final offset in const [-1, 0, 1]) {
      final i = (best + offset + _hueBins) % _hueBins;
      w += weight[i];
      r += red[i];
      g += green[i];
      b += blue[i];
    }
    if (w <= 0) return neutral;
    return AmbientPalette.fromColor(
      Color.fromARGB(255, (r / w).round(), (g / w).round(), (b / w).round()),
      fromArtwork: true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AmbientPalette &&
          other.accent == accent &&
          other.surface == surface &&
          other.deep == deep &&
          other.fromArtwork == fromArtwork;

  @override
  int get hashCode => Object.hash(accent, surface, deep, fromArtwork);
}

/// Extracts and caches [AmbientPalette]s from artwork URLs.
///
/// The artwork is decoded once at thumbnail size and read pixel by pixel;
/// the result is kept in a small LRU cache.
class AmbientPaletteService {
  AmbientPaletteService._();

  static final AmbientPaletteService instance = AmbientPaletteService._();

  static const int _maxEntries = 60;
  static const int _sampleSize = 40;

  final Map<String, AmbientPalette> _cache = {};
  final Map<String, Future<AmbientPalette?>> _pending = {};

  /// Palette already resolved for [url], or null.
  AmbientPalette? getCached(String? url) =>
      (url == null || url.isEmpty) ? null : _cache[url];

  /// Reads the palette of the artwork at [url]. Null when the artwork
  /// cannot be loaded; several callers asking for the same artwork share
  /// one reading.
  Future<AmbientPalette?> load(String url) {
    final cached = _cache[url];
    if (cached != null) return Future.value(cached);
    return _pending[url] ??= _extract(url).then((palette) {
      _pending.remove(url);
      if (palette != null) {
        _cache[url] = palette;
        _evict();
      }
      return palette;
    });
  }

  void _evict() {
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<AmbientPalette?> _extract(String url) async {
    ImageInfo? info;
    try {
      info = await _load(
        ResizeImage(
          CachedNetworkImageProvider(url),
          width: _sampleSize,
          height: _sampleSize,
        ),
      ).timeout(const Duration(seconds: 8));
      final data = await info.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return AmbientPalette.fromPixels(data.buffer.asUint8List());
    } catch (_) {
      // Network down, artwork missing or decode error: keep the accent.
      return null;
    } finally {
      info?.dispose();
    }
  }

  Future<ImageInfo> _load(ImageProvider provider) {
    final completer = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (completer.isCompleted) {
          info.dispose();
        } else {
          completer.complete(info);
        }
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }
}

/// Resolves the ambient palette for [artworkUrl] and rebuilds [builder]
/// when the real colors arrive (or when the artwork changes).
class AmbientTint extends StatefulWidget {
  const AmbientTint({
    super.key,
    required this.artworkUrl,
    required this.fallback,
    required this.builder,
  });

  final String? artworkUrl;
  final Color fallback;
  final Widget Function(BuildContext context, AmbientPalette palette) builder;

  @override
  State<AmbientTint> createState() => _AmbientTintState();
}

class _AmbientTintState extends State<AmbientTint> {
  late AmbientPalette _palette;

  @override
  void initState() {
    super.initState();
    _palette = AmbientPalette.pending(widget.fallback);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant AmbientTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUrl != widget.artworkUrl ||
        oldWidget.fallback != widget.fallback) {
      // build() follows immediately; no setState needed.
      _resolve();
    }
  }

  void _resolve() {
    final url = widget.artworkUrl;
    final service = AmbientPaletteService.instance;
    if (url == null || url.isEmpty) {
      _palette = AmbientPalette.fallback(widget.fallback);
      return;
    }
    final cached = service.getCached(url);
    if (cached != null) {
      _palette = cached;
      return;
    }
    // Still to be read. The colors of the previous artwork stay meanwhile:
    // a change of track fades straight from one cover to the next.
    if (!_palette.fromArtwork) _palette = AmbientPalette.pending(widget.fallback);
    service.load(url).then((palette) {
      if (!mounted || widget.artworkUrl != url) return;
      setState(() => _palette = palette ?? AmbientPalette.fallback(widget.fallback));
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _palette);
}

/// A wash of the artwork's color that starts at the top of the screen and
/// fades into the background. It moves only when the artwork changes, so
/// it costs nothing while the content scrolls over it.
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({
    super.key,
    this.artworkUrl,
    this.fallback,
    this.intensity = 1.0,
    this.extent = 0.5,
  });

  final String? artworkUrl;

  /// Accent used until the artwork palette is ready.
  final Color? fallback;

  /// 0…1 strength of the color at the top edge.
  final double intensity;

  /// Fraction of the height the wash covers before it is gone.
  final double extent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: AmbientTint(
        artworkUrl: artworkUrl,
        fallback: fallback ?? cs.primary,
        builder: (context, palette) {
          // Without artwork the accent only hints at itself.
          final k = intensity.clamp(0.0, 1.0) * (palette.fromArtwork ? 1.0 : 0.55);
          return AnimatedContainer(
            duration: AppMotion.ambience,
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  palette.surface.withValues(alpha: k),
                  palette.surface.withValues(alpha: 0),
                ],
                stops: [0.0, extent.clamp(0.05, 1.0)],
              ),
            ),
          );
        },
      ),
    );
  }
}
