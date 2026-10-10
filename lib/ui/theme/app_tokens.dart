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

  /// Bottom clearance for scrollables: tab bar + mini player + home
  /// indicator.
  static const double bottomContentInset = 176;
}

/// One radius ladder for the whole app. Covers sit at [xs], cards and the
/// mini player at [md]; everything interactive that is not a surface is a
/// [pill].
class AppRadius {
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;

  static BorderRadius get cover => BorderRadius.circular(xs);
  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get floating => BorderRadius.circular(md);
  static BorderRadius get chip => BorderRadius.circular(pill);
  static BorderRadius get sheet =>
      const BorderRadius.vertical(top: Radius.circular(xl));
}

/// Motion language. One set of durations and curves so every transition
/// in the app feels like it belongs to the same product.
class AppMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 220);

  /// Cross-fade of the colors taken from a cover.
  static const Duration ambience = Duration(milliseconds: 600);

  static const Curve standard = Curves.easeOutCubic;
}

/// Typography tokens. They always resolve colors from the active
/// [ColorScheme] so AMOLED, dark and custom accents stay coherent.
class AppText {
  /// Largest editorial voice, used sparingly (login, hero titles).
  static TextStyle display(ColorScheme cs) => TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.0,
        height: 1.15,
        color: cs.onSurface,
      );

  static TextStyle screenTitle(ColorScheme cs) => TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        color: cs.onSurface,
      );

  static TextStyle sectionTitle(ColorScheme cs) => TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
        color: cs.onSurface,
      );

  static TextStyle tileTitle(ColorScheme cs) => TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.1,
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
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: cs.onSurfaceVariant,
      );

  static TextStyle action(ColorScheme cs) => TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      );
}
