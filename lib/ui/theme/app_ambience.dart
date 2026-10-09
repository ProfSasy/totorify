import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'app_tokens.dart';

/// A small color story resolved from one piece of artwork (or from the
/// user's accent when no artwork is available).
@immutable
class AmbientPalette {
  /// Main artwork hue, already lifted so it reads well on dark surfaces.
  final Color primary;

  /// Complementary hue used for gradient ends.
  final Color secondary;

  /// Soft highlight used for glows and top-left ambience.
  final Color glow;

  /// Whether the palette was extracted from real artwork (vs. accent fallback).
  final bool fromArtwork;

  const AmbientPalette({
    required this.primary,
    required this.secondary,
    required this.glow,
    this.fromArtwork = false,
  });

  factory AmbientPalette.fallback(Color accent) => AmbientPalette(
        primary: accent,
        secondary: Color.lerp(accent, const Color(0xFF5B8CFF), 0.4)!,
        glow: AppTheme.lift(accent, 0.3),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AmbientPalette &&
          other.primary == primary &&
          other.secondary == secondary &&
          other.glow == glow &&
          other.fromArtwork == fromArtwork;

  @override
  int get hashCode => Object.hash(primary, secondary, glow, fromArtwork);
}

/// Extracts and caches [AmbientPalette]s from artwork URLs.
///
/// Uses Flutter's built-in `ColorScheme.fromImageProvider` (Material color
/// utilities, no extra dependency). Extraction happens once per artwork and
/// the result is kept in a small LRU cache; callers get the accent fallback
/// immediately and the real palette via [onReady].
class AmbientPaletteService {
  AmbientPaletteService._();

  static final AmbientPaletteService instance = AmbientPaletteService._();

  static const int _maxEntries = 40;

  final Map<String, AmbientPalette> _cache = {};
  final Map<String, Future<AmbientPalette?>> _pending = {};

  /// Palette already resolved for [url], or null.
  AmbientPalette? getCached(String? url) =>
      (url == null || url.isEmpty) ? null : _cache[url];

  /// Returns the best known palette for [url] synchronously and schedules
  /// extraction if needed. [onReady] fires on the UI isolate once the real
  /// palette is available; the caller must check it still wants it.
  AmbientPalette resolve(
    String? url,
    Color fallback, {
    void Function(AmbientPalette palette)? onReady,
  }) {
    final cached = getCached(url);
    if (cached != null) return cached;

    if (url != null && url.isNotEmpty && !_pending.containsKey(url)) {
      final future = _extract(url);
      _pending[url] = future;
      future.then((palette) {
        _pending.remove(url);
        if (palette == null) return;
        _cache[url] = palette;
        _evict();
        onReady?.call(palette);
      });
    }
    return AmbientPalette.fallback(fallback);
  }

  void _evict() {
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<AmbientPalette?> _extract(String url) async {
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(url),
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
      ).timeout(const Duration(seconds: 8));

      final primary = _lift(scheme.primary);
      final secondary = _lift(scheme.tertiary);
      return AmbientPalette(
        primary: primary,
        secondary: secondary,
        glow: AppTheme.lift(primary, 0.35),
        fromArtwork: true,
      );
    } catch (_) {
      // Network down, artwork missing or decode error: keep the accent.
      return null;
    }
  }

  /// Artwork hues can come out very dark; lift them so glows stay visible
  /// over the near-black canvas.
  Color _lift(Color color) => color.computeLuminance() < 0.28
      ? Color.lerp(color, Colors.white, 0.35)!
      : color;
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
    _palette = AmbientPaletteService.instance.resolve(
      url,
      widget.fallback,
      onReady: (palette) {
        if (!mounted || widget.artworkUrl != url) return;
        setState(() => _palette = palette);
      },
    );
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _palette);
}

/// The signature Totorify backdrop: three soft color blobs (artwork palette
/// when available, accent otherwise) that slowly breathe behind the content
/// and cross-fade whenever the track changes.
///
/// This widget paints only translucent gradients, so it can sit either on
/// the raw background or on top of a Canvas video.
class AmbientBackdrop extends StatefulWidget {
  const AmbientBackdrop({
    super.key,
    this.artworkUrl,
    this.fallback,
    this.intensity = 1.0,
    this.animate = true,
  });

  final String? artworkUrl;

  /// Accent used until the artwork palette is ready.
  final Color? fallback;

  /// 0…1 multiplier on every blob: lower it to let a Canvas video breathe
  /// through, raise it to full ambience when the video is hidden.
  final double intensity;

  /// Disable the slow breathing (e.g. in tests or when off-screen).
  final bool animate;

  @override
  State<AmbientBackdrop> createState() => _AmbientBackdropState();
}

class _AmbientBackdropState extends State<AmbientBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AmbientBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!widget.animate && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: IgnorePointer(
        child: AmbientTint(
          artworkUrl: widget.artworkUrl,
          fallback: widget.fallback ?? cs.primary,
          builder: (context, palette) => AnimatedSwitcher(
            duration: AppMotion.ambience,
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _AmbientLayer(
              key: ValueKey<AmbientPalette>(palette),
              palette: palette,
              intensity: widget.intensity,
              breath: _breath,
            ),
          ),
        ),
      ),
    );
  }
}

class _AmbientLayer extends StatelessWidget {
  const _AmbientLayer({
    super.key,
    required this.palette,
    required this.intensity,
    required this.breath,
  });

  final AmbientPalette palette;
  final double intensity;
  final Animation<double> breath;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final k = intensity.clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: breath,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(breath.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            // Main hue, top-left, breathing outward.
            Align(
              alignment: const Alignment(-1.25, -1.05),
              child: Transform.scale(
                scale: 1.0 + 0.10 * t,
                child: _Blob(
                  size: width * 1.25,
                  color: palette.primary,
                  opacity: 0.34 * k,
                ),
              ),
            ),
            // Complementary hue, right side, counter-phase.
            Align(
              alignment: const Alignment(1.35, -0.45),
              child: Transform.scale(
                scale: 1.08 - 0.08 * t,
                child: _Blob(
                  size: width * 1.0,
                  color: palette.secondary,
                  opacity: 0.24 * k,
                ),
              ),
            ),
            // Soft highlight, bottom-left, deepest of the three.
            Align(
              alignment: const Alignment(-0.85, 1.25),
              child: Transform.scale(
                scale: 1.04 + 0.06 * (1 - t),
                child: _Blob(
                  size: width * 1.05,
                  color: palette.glow,
                  opacity: 0.14 * k,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({
    required this.size,
    required this.color,
    required this.opacity,
  });

  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    if (opacity <= 0.001) return const SizedBox.shrink();
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}
