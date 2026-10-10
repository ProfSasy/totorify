import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'app_tokens.dart';

/// Totorify visual language.
///
/// Neutral, almost black surfaces carry the content; color comes from the
/// music: the accent chosen by the user for the app's own actions, and the
/// cover of what is playing for the player (see `app_ambience.dart`). All
/// "on" colors are derived from luminance, which keeps buttons readable
/// with any accent, Pure White included.
class AppTheme {
  AppTheme._();

  // ── Core palette ────────────────────────────────────────────────────────
  static const Color darkBg = Color(0xFF121212);
  static const Color amoledBg = Color(0xFF000000);
  static const Color darkSurface = Color(0xFF1A1A1A);
  static const Color darkSurfaceHigh = Color(0xFF242424);
  static const Color darkSurfaceHighest = Color(0xFF2E2E2E);
  static const Color amoledSurface = Color(0xFF101010);
  static const Color amoledSurfaceHigh = Color(0xFF1C1C1C);
  static const Color amoledSurfaceHighest = Color(0xFF262626);

  // Used only when no accent is passed; the app always passes the user's.
  static const Color accentColor = Color(0xFF1ED760);

  // Preset Colors for User Customization
  static const List<(String, Color)> presetColors = [
    ('Verde', Color(0xFF1ED760)),
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
          ? const Color(0xFF0B0B0B)
          : const Color(0xFFFFFFFF);

  /// Lightens [color] toward white, used for hints and pressed states.
  static Color lift(Color color, double amount) =>
      Color.lerp(color, Colors.white, amount)!;

  /// Builds the full Material color scheme for the current settings.
  static ColorScheme schemeFor({required bool isAmoled, Color? customAccent}) {
    final primary = customAccent ?? accentColor;
    final bg = isAmoled ? amoledBg : darkBg;
    final surface = isAmoled ? amoledSurface : darkSurface;
    final surfaceHigh = isAmoled ? amoledSurfaceHigh : darkSurfaceHigh;
    final surfaceHighest = isAmoled ? amoledSurfaceHighest : darkSurfaceHighest;
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
      error: const Color(0xFFF15E6C),
      onError: Colors.white,
      errorContainer: const Color(0xFF3A1218),
      onErrorContainer: const Color(0xFFFFB3BB),
      surface: surface,
      onSurface: Colors.white,
      onSurfaceVariant: const Color(0xFFB3B3B3),
      outline: Colors.white.withValues(alpha: 0.30),
      outlineVariant: Colors.white.withValues(alpha: 0.08),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: const Color(0xFFEAEAEA),
      onInverseSurface: const Color(0xFF141414),
      inversePrimary: lift(primary, 0.5),
      surfaceTint: Colors.transparent,
    ).copyWith(
      surfaceDim: bg,
      surfaceBright: surfaceHigh,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHighest,
    );
  }

  static ThemeData getTheme({bool isAmoled = false, Color? customAccent}) {
    final cs = schemeFor(isAmoled: isAmoled, customAccent: customAccent);
    final bg = cs.surfaceDim;
    // The text styles given to components below replace the ones of the
    // theme instead of building on them: they are given the platform's font
    // here, like every other text.
    final fontFamily = Typography.material2021(platform: defaultTargetPlatform)
        .white
        .labelLarge
        ?.fontFamily;
    TextStyle label(double size) => TextStyle(
          fontFamily: fontFamily,
          fontSize: size,
          fontWeight: FontWeight.w700,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      // Touches answer with a quiet highlight, never with a ripple.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.white.withValues(alpha: 0.06),
      // NOTE: no custom PageTransitionsTheme: iOS already defaults to the
      // Cupertino transition, and the builder class name differs across
      // Flutter releases (CI runs a newer stable than some dev machines).
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppText.screenTitle(cs).copyWith(fontFamily: fontFamily),
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
          shape: const StadiumBorder(),
          textStyle: label(15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.onSurface,
          side: BorderSide(color: cs.outline),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 8),
          minimumSize: const Size(0, 34),
          shape: const StadiumBorder(),
          textStyle: label(13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.onSurface,
          textStyle: label(14),
        ),
      ),
      iconTheme: IconThemeData(color: cs.onSurface),
      chipTheme: ChipThemeData(
        backgroundColor: cs.surfaceContainerHighest,
        selectedColor: cs.primary,
        disabledColor: cs.surfaceContainerHigh,
        labelStyle: TextStyle(
          fontFamily: fontFamily,
          color: cs.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: TextStyle(
          fontFamily: fontFamily,
          color: cs.onPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.chip),
        showCheckmark: false,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3.5,
        activeTrackColor: cs.onSurface,
        inactiveTrackColor: cs.onSurface.withValues(alpha: 0.22),
        thumbColor: cs.onSurface,
        overlayColor: cs.onSurface.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 5.5,
          elevation: 1,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cs.inverseSurface,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: cs.onInverseSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
        // Above the mini player, which floats over the tab bar.
        insetPadding: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, 72),
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: cs.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: cs.onSurfaceVariant,
          fontSize: 14,
          height: 1.4,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        modalBarrierColor: Colors.black.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.sheet),
        showDragHandle: false,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cs.surfaceContainerHighest,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: TextStyle(fontFamily: fontFamily, color: cs.onSurface, fontSize: 14),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurfaceVariant,
        textColor: cs.onSurface,
        titleTextStyle: AppText.tileTitle(cs).copyWith(fontFamily: fontFamily),
        subtitleTextStyle: AppText.tileSubtitle(cs)
            .copyWith(fontFamily: fontFamily, height: 1.35),
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
        textStyle: TextStyle(fontFamily: fontFamily, color: cs.onSurface, fontSize: 12),
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
