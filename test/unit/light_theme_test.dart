import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/app_settings.dart';
import 'package:kreate_ios/ui/theme/app_ambience.dart';
import 'package:kreate_ios/ui/theme/app_theme.dart';
import 'package:kreate_ios/ui/widgets/player/player_style.dart';
import 'package:kreate_ios/ui/widgets/player_sheet.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const cover = AmbientPalette(
    accent: Color(0xFF5E9BFF),
    surface: Color(0xFF1B2F55),
    deep: Color(0xFF0B1424),
    fromArtwork: true,
  );
  final dark = AppTheme.schemeFor(isAmoled: false);
  final light = AppTheme.schemeFor(isAmoled: false, background: const Color(0xFFF4F1EA));

  group('the player in the colors of the theme', () {
    test('its surfaces are the theme\'s', () {
      final palette = PlayerSheet.themedPalette(cover, light);
      expect(palette.surface, light.surfaceContainerHigh);
      expect(palette.deep, light.surfaceDim);
      expect(palette.fromArtwork, isTrue);
    });

    test('on a light theme the color of the cover is darkened to be read', () {
      final palette = PlayerSheet.themedPalette(cover, light);
      expect(palette.accent, isNot(cover.accent));
      expect(
        contrast(palette.accent, light.surfaceDim),
        greaterThan(contrast(cover.accent, light.surfaceDim)),
      );
    });

    test('on a dark theme the color of the cover stays', () {
      expect(PlayerSheet.themedPalette(cover, dark).accent, cover.accent);
    });

    test('the dark player has white ink on black shade', () {
      PlayerStyle.ink = Colors.red;
      PlayerStyle.shade = Colors.red;
      PlayerStyle.dark();
      expect(playerInk, Colors.white);
      expect(PlayerStyle.shade, Colors.black);
    });
  });

  group('the wash of the cover behind a page', () {
    test('dark theme: the dark shade of the cover', () {
      expect(cover.washFor(dark), cover.surface);
    });

    test('light theme: light, with the text of the theme readable on it', () {
      final wash = cover.washFor(light);
      expect(wash, isNot(cover.surface));
      expect(contrast(light.onSurface, wash), greaterThan(4.5));
    });

    test('turned off: nothing is laid over the page', () async {
      await AppSettings.instance.pageWash.set(false);
      expect(cover.washFor(dark).a, 0);
      expect(cover.washFor(light).a, 0);
      await AppSettings.instance.pageWash.set(true);
    });
  });
}
