import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/ui/theme/app_theme.dart';
import 'package:kreate_ios/ui/theme/app_tokens.dart';

void main() {
  const navy = Color(0xFF101830);
  const paper = Color(0xFFF4F1EA);
  const coral = Color(0xFFFF2A54);

  group('colors of one screen', () {
    test('with nothing chosen the theme of the app itself', () {
      final base = AppTheme.getTheme(customAccent: AppTheme.presetColors.first.$2);
      expect(identical(AppTheme.forScreen(base), base), isTrue);
    });

    test('a background of its own: scaffold, surfaces and app bar follow it', () {
      final base = AppTheme.getTheme();
      final screen = AppTheme.forScreen(base, background: navy);
      expect(screen.scaffoldBackgroundColor, navy);
      expect(screen.colorScheme.surfaceDim, navy);
      expect(screen.appBarTheme.backgroundColor, navy);
      expect(screen.canvasColor, navy);
      // The boxes are made from the new background, not the old one.
      expect(screen.colorScheme.surface, isNot(base.colorScheme.surface));
      expect(screen.cardTheme.color, screen.colorScheme.surface);
      expect(screen.dialogTheme.backgroundColor, screen.colorScheme.surfaceContainerHigh);
      expect(screen.bottomSheetTheme.backgroundColor, screen.colorScheme.surfaceContainerHigh);
      // The accent stays the app's.
      expect(screen.colorScheme.primary, base.colorScheme.primary);
    });

    test('an accent of its own: primary and what is drawn with it', () {
      final base = AppTheme.getTheme(customAccent: AppTheme.presetColors.first.$2);
      final screen = AppTheme.forScreen(base, accent: coral);
      expect(screen.colorScheme.primary, coral);
      expect(screen.colorScheme.onPrimary, AppTheme.inkOn(coral));
      expect(screen.filledButtonTheme.style!.backgroundColor!.resolve({}), coral);
      expect(screen.chipTheme.selectedColor, coral);
      expect(screen.textSelectionTheme.cursorColor, coral);
      expect(screen.progressIndicatorTheme.color, coral);
      // The background stays the app's.
      expect(screen.scaffoldBackgroundColor, base.scaffoldBackgroundColor);
    });

    test('a light background: light brightness and dark ink everywhere', () {
      final base = AppTheme.getTheme();
      expect(base.brightness, Brightness.dark);
      final screen = AppTheme.forScreen(base, background: paper);
      final cs = screen.colorScheme;
      expect(screen.brightness, Brightness.light);
      expect(cs.brightness, Brightness.light);
      expect(cs.onSurface, AppTheme.inkOn(paper));
      expect(cs.onSurface.computeLuminance(), lessThan(0.05));
      // The text baked into the sub-themes follows, not only the scheme.
      expect(screen.textTheme.bodyMedium!.color, cs.onSurface);
      expect(screen.textTheme.titleLarge!.color, cs.onSurface);
      expect(screen.appBarTheme.titleTextStyle!.color, cs.onSurface);
      expect(screen.appBarTheme.iconTheme!.color, cs.onSurface);
      expect(screen.iconTheme.color, cs.onSurface);
      expect(screen.listTileTheme.textColor, cs.onSurface);
      expect(screen.sliderTheme.activeTrackColor, cs.onSurface);
      expect(screen.dividerTheme.color, cs.outlineVariant);
      expect(
        screen.outlinedButtonTheme.style!.foregroundColor!.resolve({}),
        cs.onSurface,
      );
    });

    test('the cover tint of the app is kept when only the accent changes', () {
      final base = AppTheme.getTheme(tint: const Color(0xFF1B2F55));
      final screen = AppTheme.forScreen(base, accent: coral);
      expect(screen.colorScheme.surfaceDim, base.colorScheme.surfaceDim);
      expect(screen.colorScheme.surface, base.colorScheme.surface);
      expect(screen.colorScheme.primary, coral);
    });

    test('font, corners and look of the app stay', () {
      final base = AppTheme.getTheme(fontFamily: 'Georgia', cornerScale: 2.0, density: 0);
      final screen = AppTheme.forScreen(base, background: navy, accent: coral);
      expect(screen.textTheme.bodyMedium!.fontFamily, 'Georgia');
      expect(screen.visualDensity, VisualDensity.compact);
      expect(screen.extension<AppShape>(), base.extension<AppShape>());
      expect(screen.cardTheme.shape, base.cardTheme.shape);
    });

    test('the shared radius and title scale are left alone', () {
      final base = AppTheme.getTheme(cornerScale: 2.0, titleScale: 1.2);
      // Something else in between: forScreen must not write them back.
      AppRadius.scale = 0.5;
      AppText.titleScale = 0.9;
      AppTheme.forScreen(base, background: paper, accent: coral);
      expect(AppRadius.scale, 0.5);
      expect(AppText.titleScale, 0.9);
      AppTheme.getTheme();
    });
  });
}
