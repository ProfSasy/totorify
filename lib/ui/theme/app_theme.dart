import 'package:flutter/material.dart';
import 'app_tokens.dart';

/// Totorify visual language — "Ambient".
///
/// A single accent seeds the whole color scheme, while surfaces follow a
/// fixed ladder of depth ([ColorScheme.surfaceDim] →
/// [ColorScheme.surfaceContainerHighest]) so every screen shares the same
/// rhythm. All "on" colors are derived from luminance, which keeps buttons
/// readable with any accent — including Pure White.
class AppTheme {
  AppTheme._();

  // ── Core palette ────────────────────────────────────────────────────────
  static const Color darkBg = Color(0xFF0D0D12); // Deep cinematic canvas
  static const Color amoledBg = Color(0xFF000000); // True OLED black
  static const Color darkSurface = Color(0xFF16161D);
  static const Color darkSurfaceHigh = Color(0xFF1F1F29);
  static const Color amoledSurface = Color(0xFF0F0F14);
  static const Color amoledSurfaceHigh = Color(0xFF191920);

  // Used only when no accent is passed; the app always passes the user's.
  static const Color accentColor = Color(0xFFFF2A54);

  // Preset Colors for User Customization
  static const List<(String, Color)> presetColors = [
    ('Coral', Color(0xFFFF2A54)),
    ('Cyan Sky', Color(0xFF00B4D8)),
    ('Electric Blue', Color(0xFF2A75FF)),
    ('Royal Purple', Color(0xFF9D4EDD)),
    ('Sunset Orange', Color(0xFFFF6B35)),
    ('Sun Gold', Color(0xFFFFB703)),
    ('Pure White', Color(0xFFEEEEEE)),
  ];

  /// Ink (near-black or near-white) that stays readable on [background].
  ///
  /// The 0.30 luminance threshold guarantees at least ~3.6:1 contrast for
  /// every preset accent (Pure White gets dark ink, coral keeps white).
  static Color inkOn(Color background) =>
      background.computeLuminance() > 0.30
          ? const Color(0xFF121216)
          : const Color(0xFFF7F7FA);

  /// Lightens [color] toward white, used for gradient ends and hints.
  static Color lift(Color color, double amount) =>
      Color.lerp(color, Colors.white, amount)!;

  /// Builds the full Material color scheme for the current settings.
  static ColorScheme schemeFor({required bool isAmoled, Color? customAccent}) {
    final primary = customAccent ?? accentColor;
    final bg = isAmoled ? amoledBg : darkBg;
    final surface = isAmoled ? amoledSurface : darkSurface;
    final surfaceHigh = isAmoled ? amoledSurfaceHigh : darkSurfaceHigh;
    final secondary = Color.lerp(primary, const Color(0xFF7C6BFF), 0.35)!;
    final tertiary = Color.lerp(primary, const Color(0xFF3ED6C4), 0.45)!;

    return ColorScheme.dark(
      primary: primary,
      onPrimary: inkOn(primary),
      primaryContainer: primary.withValues(alpha: 0.24),
      onPrimaryContainer: lift(primary, 0.55),
      secondary: secondary,
      onSecondary: inkOn(secondary),
      secondaryContainer: secondary.withValues(alpha: 0.22),
      onSecondaryContainer: lift(secondary, 0.55),
      tertiary: tertiary,
      onTertiary: inkOn(tertiary),
      error: const Color(0xFFFF5D6C),
      onError: Colors.white,
      errorContainer: const Color(0xFF3A1218),
      onErrorContainer: const Color(0xFFFFB3BB),
      surface: surface,
      onSurface: const Color(0xFFF5F5F8),
      onSurfaceVariant: const Color(0xFFA3A3B2),
      outline: Colors.white.withValues(alpha: 0.28),
      outlineVariant: Colors.white.withValues(alpha: 0.08),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: const Color(0xFFEAEAEF),
      onInverseSurface: const Color(0xFF141419),
      inversePrimary: lift(primary, 0.5),
      surfaceTint: Colors.transparent,
    ).copyWith(
      surfaceDim: bg,
      surfaceBright: surfaceHigh,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: lift(surfaceHigh, 0.04),
    );
  }

  /// Brand gradient used by primary CTAs and active elements.
  static LinearGradient primaryGradient(ColorScheme cs) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [cs.primary, lift(cs.primary, 0.28)],
      );

  static ThemeData getTheme({bool isAmoled = false, Color? customAccent}) {
    final cs = schemeFor(isAmoled: isAmoled, customAccent: customAccent);
    final bg = cs.surfaceDim;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashColor: cs.primary.withValues(alpha: 0.08),
      highlightColor: cs.primary.withValues(alpha: 0.04),
      // NOTE: no custom PageTransitionsTheme: iOS already defaults to the
      // Cupertino transition, and the builder class name differs across
      // Flutter releases (CI runs a newer stable than some dev machines).
      appBarTheme: AppBarTheme(
        backgroundColor: bg.withValues(alpha: 0.92),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppText.screenTitle(cs),
        iconTheme: IconThemeData(color: cs.onSurface, size: 22),
      ),
      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.card),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          disabledBackgroundColor: cs.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor: cs.onSurfaceVariant,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: 14,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: cs.primary),
      ),
      iconTheme: IconThemeData(color: cs.onSurface),
      chipTheme: ChipThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        selectedColor: cs.primaryContainer,
        disabledColor: cs.surfaceContainerHigh,
        labelStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.chip),
        showCheckmark: false,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3.5,
        activeTrackColor: cs.primary,
        inactiveTrackColor: cs.onSurface.withValues(alpha: 0.16),
        thumbColor: cs.primary,
        overlayColor: cs.primary.withValues(alpha: 0.16),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 5.5,
          elevation: 1,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cs.surfaceContainerHighest,
        contentTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(
          color: cs.onSurfaceVariant,
          fontSize: 14,
          height: 1.4,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        modalBarrierColor: Colors.black.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.sheet),
        showDragHandle: false,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cs.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: TextStyle(color: cs.onSurface, fontSize: 14),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurfaceVariant,
        textColor: cs.onSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: cs.primary,
        selectionColor: cs.primary.withValues(alpha: 0.3),
        selectionHandleColor: cs.primary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: cs.primary,
        linearTrackColor: cs.onSurface.withValues(alpha: 0.14),
        circularTrackColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? cs.onPrimary
              : cs.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? cs.primary
              : cs.surfaceContainerHighest,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        textStyle: TextStyle(color: cs.onSurface, fontSize: 12),
      ),
      textTheme: _textTheme(cs),
    );
  }

  static TextTheme _textTheme(ColorScheme cs) => TextTheme(
        displaySmall: AppText.display(cs),
        headlineMedium: AppText.screenTitle(cs),
        titleLarge: AppText.sectionTitle(cs),
        titleMedium: AppText.tileTitle(cs),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: cs.onSurface,
          height: 1.35,
        ),
        bodySmall: AppText.caption(cs),
        labelLarge: AppText.tileTitle(cs),
        labelSmall: AppText.overline(cs),
      );
}
