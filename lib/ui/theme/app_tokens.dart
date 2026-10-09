import 'package:flutter/material.dart';

/// Shared spacing scale. Every screen should compose paddings and gaps
/// from these steps so the rhythm stays consistent.
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Bottom clearance for scrollables: floating nav bar + floating mini
  /// player + home indicator.
  static const double bottomContentInset = 184;
}

/// One radius ladder for the whole app. Cards sit at [md],
/// floating chrome (mini player, nav bar) at [xl]; everything interactive
/// that is not a surface is a [pill].
class AppRadius {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get floating => BorderRadius.circular(xl);
  static BorderRadius get chip => BorderRadius.circular(pill);
  static BorderRadius get sheet =>
      const BorderRadius.vertical(top: Radius.circular(xl));
}

/// Motion language. One set of durations and curves so every transition
/// in the app feels like it belongs to the same product.
class AppMotion {
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 240);

  /// Palette cross-fades and ambient breathing.
  static const Duration ambience = Duration(milliseconds: 900);

  static const Curve standard = Curves.easeOutCubic;
}

/// Typography tokens. They always resolve colors from the active
/// [ColorScheme] so AMOLED, dark and custom accents stay coherent.
class AppText {
  /// Largest editorial voice, used sparingly (login, hero titles).
  static TextStyle display(ColorScheme cs) => TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.0,
        height: 1.2,
        color: cs.onSurface,
      );

  static TextStyle screenTitle(ColorScheme cs) => TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        color: cs.onSurface,
      );

  static TextStyle sectionTitle(ColorScheme cs) => TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: cs.onSurface,
      );

  static TextStyle tileTitle(ColorScheme cs) => TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      );

  static TextStyle tileSubtitle(ColorScheme cs) => TextStyle(
        fontSize: 13,
        color: cs.onSurfaceVariant,
      );

  static TextStyle caption(ColorScheme cs) => TextStyle(
        fontSize: 12,
        color: cs.onSurfaceVariant,
      );

  static TextStyle overline(ColorScheme cs) => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
        color: cs.onSurfaceVariant,
      );

  static TextStyle action(ColorScheme cs) => TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: cs.primary,
      );
}
