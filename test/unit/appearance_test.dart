import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/app_settings.dart';
import 'package:kreate_ios/services/font_library.dart';
import 'package:kreate_ios/ui/theme/app_ambience.dart';
import 'package:kreate_ios/ui/theme/app_theme.dart';
import 'package:kreate_ios/ui/theme/app_tokens.dart';
import 'package:kreate_ios/ui/theme/dynamic_color.dart';

void main() {
  group('FontLibrary', () {
    test('a font is known by the name of its file', () {
      expect(FontLibrary.familyOf('/var/mobile/Inter.ttf'), 'Inter');
      expect(FontLibrary.familyOf(r'C:\fonts\Playfair Display.OTF'), 'Playfair Display');
      expect(FontLibrary.familyOf('JetBrains.Mono.Bold.ttf'), 'JetBrains.Mono.Bold');
      expect(FontLibrary.familyOf('noextension'), 'noextension');
    });

    test('only .ttf and .otf files are fonts', () {
      expect(FontLibrary.isFontFile('a/Inter.ttf'), isTrue);
      expect(FontLibrary.isFontFile('a/Inter.OTF'), isTrue);
      expect(FontLibrary.isFontFile('a/Inter.woff2'), isFalse);
      expect(FontLibrary.isFontFile('a/song.mp3'), isFalse);
      expect(FontLibrary.isFontFile('ttf'), isFalse);
    });

    test('a file that is not a font is refused without being read', () async {
      expect(await FontLibrary.instance.importFile('/nowhere/notes.txt'), isNull);
      expect(FontLibrary.instance.imported.value, isEmpty);
    });

    test('the system families are there, each once', () {
      expect(FontLibrary.systemFamilies, isNotEmpty);
      expect(FontLibrary.systemFamilies.toSet(), hasLength(FontLibrary.systemFamilies.length));
    });
  });

  group('dynamic colors', () {
    const fromCover = AmbientPalette(
      accent: Color(0xFF4F8DFF),
      surface: Color(0xFF1B2F55),
      deep: Color(0xFF0B1424),
      fromArtwork: true,
    );

    test('the colors of a real cover are used', () {
      expect(DynamicColor.paletteToUse(fromCover), same(fromCover));
    });

    test('no cover, a fallback and a black and white cover leave the app its color', () {
      expect(DynamicColor.paletteToUse(null), isNull);
      expect(DynamicColor.paletteToUse(AmbientPalette.fallback(const Color(0xFF1ED760))), isNull);
      expect(DynamicColor.paletteToUse(AmbientPalette.neutral), isNull);
      expect(
        DynamicColor.paletteToUse(
            AmbientPalette.fromColor(const Color(0xFF808080), fromArtwork: true)),
        isNull,
      );
    });

    test('no song, no palette', () {
      DynamicColor.instance.show(null);
      expect(DynamicColor.instance.palette.value, isNull);
      DynamicColor.instance.show('');
      expect(DynamicColor.instance.palette.value, isNull);
    });
  });

  group('theme', () {
    test('without a tint the surfaces are the designed ones', () {
      final scheme = AppTheme.schemeFor(isAmoled: false);
      expect(scheme.surfaceDim, AppTheme.darkBg);
      expect(scheme.surface, AppTheme.darkSurface);
      expect(AppTheme.schemeFor(isAmoled: true).surfaceDim, AppTheme.amoledBg);
    });

    test('a tint colors the surfaces and keeps them dark', () {
      for (final tint in const [
        Color(0xFF1B2F55),
        Color(0xFF5A1020),
        Color(0xFF3C4A10),
        Color(0xFFEEEEAA),
      ]) {
        final plain = AppTheme.schemeFor(isAmoled: false);
        final tinted = AppTheme.schemeFor(isAmoled: false, tint: tint);
        expect(tinted.surfaceDim, isNot(plain.surfaceDim), reason: '$tint');
        for (final (colored, designed) in [
          (tinted.surfaceDim, plain.surfaceDim),
          (tinted.surface, plain.surface),
          (tinted.surfaceContainerHigh, plain.surfaceContainerHigh),
          (tinted.surfaceContainerHighest, plain.surfaceContainerHighest),
        ]) {
          // White text stays as readable as on the designed surface.
          expect(colored.computeLuminance(), lessThan(0.08), reason: '$tint');
          expect(
            HSLColor.fromColor(colored).lightness,
            lessThanOrEqualTo(HSLColor.fromColor(designed).lightness + 0.051),
            reason: '$tint',
          );
        }
      }
    });

    test('pure black stays pure black with a tint', () {
      final tinted = AppTheme.schemeFor(isAmoled: true, tint: const Color(0xFF1B2F55));
      expect(tinted.surfaceDim, AppTheme.amoledBg);
    });

    test('the accent is the one given, with readable ink on it', () {
      final light = AppTheme.schemeFor(isAmoled: false, customAccent: const Color(0xFFEEEEEE));
      expect(light.primary, const Color(0xFFEEEEEE));
      expect(light.onPrimary.computeLuminance(), lessThan(0.1));
      final dark = AppTheme.schemeFor(isAmoled: false, customAccent: const Color(0xFF2A2AFF));
      expect(dark.onPrimary, const Color(0xFFFFFFFF));
    });

    test('the font and the corners chosen are in the theme', () {
      final theme = AppTheme.getTheme(fontFamily: 'Georgia', cornerScale: 2.0);
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Georgia');
      expect(theme.textTheme.titleLarge!.fontFamily, 'Georgia');
      expect(theme.appBarTheme.titleTextStyle!.fontFamily, 'Georgia');
      expect(theme.extension<AppShape>()!.cornerScale, 2.0);
      expect(AppRadius.cover, BorderRadius.circular(AppRadius.xs * 2));
      expect(AppRadius.card, BorderRadius.circular(AppRadius.md * 2));

      // Back to the designed ones: no font of ours, corners as they were.
      final plain = AppTheme.getTheme(fontFamily: '');
      expect(plain.textTheme.bodyMedium!.fontFamily, isNot('Georgia'));
      expect(AppRadius.cover, BorderRadius.circular(AppRadius.xs));
    });

    test('square corners are square, and a theme with other corners is another theme', () {
      final square = AppTheme.getTheme(cornerScale: AppRadius.scales[0]);
      expect(AppRadius.cover, BorderRadius.zero);
      final round = AppTheme.getTheme(cornerScale: AppRadius.scales[3]);
      expect(square.extension<AppShape>(), isNot(round.extension<AppShape>()));
      AppTheme.getTheme();
      expect(AppRadius.scale, 1.0);
    });
  });

  group('settings', () {
    test('the look starts as designed', () {
      final settings = AppSettings.instance;
      expect(settings.fontFamily.value, '');
      expect(settings.textScale.value, 1.0);
      expect(settings.dynamicColor.value, 0);
      expect(settings.cornerStyle.value, 1);
      expect(AppRadius.scales[settings.cornerStyle.value], 1.0);
      expect(settings.playerCoverStyle.value, 0);
      expect(settings.playerTitleCentered.value, isFalse);
      expect(settings.playerShowSource.value, isTrue);
      expect(settings.playerShowModes.value, isTrue);
      expect(settings.playerHiddenActions.value, isEmpty);
    });

    test('the choices of the look travel with a backup', () {
      final exported = AppSettings.instance.export();
      expect(
        exported.keys,
        containsAll([
          'font_family',
          'text_scale',
          'dynamic_color',
          'corner_style',
          'player_cover_style',
          'player_title_centered',
          'player_show_source',
          'player_show_modes',
          'player_hidden_actions',
        ]),
      );
    });
  });
}
