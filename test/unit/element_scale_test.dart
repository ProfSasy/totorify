import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/app_settings.dart';
import 'package:kreate_ios/services/app_themes.dart';
import 'package:kreate_ios/ui/theme/app_tokens.dart';
import 'package:kreate_ios/ui/theme/element_scale.dart';
import 'package:kreate_ios/ui/widgets/cover_card.dart';

void main() {
  final settings = AppSettings.instance;

  // The settings are one instance for the whole file: each test starts and
  // ends with the designed values.
  Future<void> designed() async {
    for (final setting in settings.elementLayout) {
      await setting.set(setting.fallback);
    }
  }

  setUp(designed);
  tearDown(designed);

  group('the designed values change nothing', () {
    test('every text at its designed size, every spacing as it was', () {
      for (final setting in settings.elementLayout) {
        expect(setting.value, setting.fallback, reason: setting.key);
      }
      for (final setting in [
        settings.textSongTitle,
        settings.textSongSubtitle,
        settings.textCardTitle,
        settings.textPlayerTitle,
        settings.textPlayerArtist,
        settings.textMiniPlayer,
        settings.textNavLabels,
      ]) {
        expect(setting.fallback, ElementScale.designed, reason: setting.key);
        expect(ElementScale.of(setting), 1.0, reason: setting.key);
      }
      expect(PageSpacing.margin, 16);
      expect(PageSpacing.margin, AppSpacing.lg);
      expect(PageSpacing.sectionGap, AppSpacing.xl);
      expect(PageSpacing.cardGap, AppSpacing.lg);
    });

    test('a style at the designed size is the very same style', () {
      const style = TextStyle(fontSize: 15.5, letterSpacing: -0.1);
      expect(identical(ElementScale.scaled(style, 1.0), style), isTrue);
      expect(ElementScale.scaled(style, 1.25).fontSize, 15.5 * 1.25);
      // A style without a size is left as it is.
      const sizeless = TextStyle(letterSpacing: 1);
      expect(identical(ElementScale.scaled(sizeless, 1.25), sizeless), isTrue);
    });

    test('a row of cards keeps its height', () {
      expect(CoverCard.titleScale, 1.0);
      expect(CoverCard.heightFor(118), 118 + 32 + 19);
    });
  });

  group('levels', () {
    test('each level of text has its multiplier', () {
      expect(ElementScale.factors, [0.85, 0.93, 1.0, 1.1, 1.25]);
      expect(ElementScale.labels, hasLength(ElementScale.factors.length));
      for (var level = 0; level < ElementScale.factors.length; level++) {
        expect(ElementScale.factorAt(level), ElementScale.factors[level]);
      }
    });

    test('a level chosen is read from its setting', () async {
      await settings.textPlayerTitle.set(4);
      expect(ElementScale.of(settings.textPlayerTitle), 1.25);
      await settings.textSongSubtitle.set(0);
      expect(ElementScale.of(settings.textSongSubtitle), 0.85);
    });

    test('each level of spacing has its value', () {
      expect(PageSpacing.margins, [12, 16, 20, 28]);
      for (var level = 0; level < 4; level++) {
        expect(PageSpacing.marginAt(level), PageSpacing.margins[level]);
        expect(PageSpacing.sectionGapAt(level), PageSpacing.sectionGaps[level]);
        expect(PageSpacing.cardGapAt(level), PageSpacing.cardGaps[level]);
      }
      expect(PageSpacing.marginLabels, hasLength(PageSpacing.margins.length));
      expect(PageSpacing.gapLabels, hasLength(PageSpacing.sectionGaps.length));
      expect(PageSpacing.gapLabels, hasLength(PageSpacing.cardGaps.length));
    });

    test('a level out of range takes the nearest one', () async {
      expect(ElementScale.factorAt(-3), 0.85);
      expect(ElementScale.factorAt(99), 1.25);
      expect(PageSpacing.marginAt(-1), 12);
      expect(PageSpacing.marginAt(7), 28);
      expect(PageSpacing.sectionGapAt(10), PageSpacing.sectionGaps.last);
      expect(PageSpacing.cardGapAt(-10), PageSpacing.cardGaps.first);

      await settings.textCardTitle.set(42);
      expect(ElementScale.of(settings.textCardTitle), 1.25);
      await settings.pageMargin.set(-5);
      expect(PageSpacing.margin, 12);
    });

    test('a larger card title makes the row of cards taller, a smaller one does not', () async {
      await settings.textCardTitle.set(4);
      expect(CoverCard.heightFor(118), greaterThan(118 + 32 + 19));
      await settings.textCardTitle.set(0);
      expect(CoverCard.heightFor(118), 118 + 32 + 19);
    });
  });

  group('in the looks', () {
    test('the new choices are part of the look, each once', () {
      final keys = [for (final setting in settings.appearance) setting.key];
      expect(keys.toSet(), hasLength(keys.length));
      for (final setting in settings.elementLayout) {
        expect(keys, contains(setting.key));
      }
      expect(
        keys,
        containsAll([
          'text_song_title',
          'text_song_subtitle',
          'text_card_title',
          'text_player_title',
          'text_player_artist',
          'text_mini_player',
          'text_nav_labels',
          'page_margin',
          'section_gap',
          'card_gap',
        ]),
      );
      // They travel with a backup too.
      expect(settings.export().keys, containsAll(keys));
    });

    test('a saved look brings them back, and the designed look resets them', () async {
      await settings.textSongTitle.set(4);
      await settings.textNavLabels.set(0);
      await settings.pageMargin.set(3);
      await settings.cardGap.set(2);

      // What `AppThemes.capture` writes down: what differs from the design.
      final look = AppLook(name: 'Spazioso', values: {
        AppLook.accentKey: 0xFF1ED760,
        AppLook.amoledKey: false,
        for (final setting in settings.appearance)
          if ('${setting.value}' != '${setting.fallback}') setting.key: setting.value,
      });
      expect(look.values, containsPair('text_song_title', 4));
      expect(look.values, containsPair('page_margin', 3));
      expect(look.values, isNot(contains('section_gap')));

      final saved = AppLook.decode(look.encode())!;
      await designed();
      expect(PageSpacing.margin, 16);

      // What `AppThemes.apply` puts back.
      Future<void> apply(AppLook look) => settings.restore({
            for (final setting in settings.appearance)
              setting.key: look.values.containsKey(setting.key)
                  ? look.values[setting.key]
                  : setting.fallback,
          });

      await apply(saved);
      expect(settings.textSongTitle.value, 4);
      expect(settings.textNavLabels.value, 0);
      expect(settings.pageMargin.value, 3);
      expect(settings.cardGap.value, 2);
      expect(settings.sectionGap.value, 1);
      expect(PageSpacing.margin, 28);
      expect(ElementScale.of(settings.textSongTitle), 1.25);

      await apply(AppThemes.builtIn.first);
      for (final setting in settings.elementLayout) {
        expect(setting.value, setting.fallback, reason: setting.key);
      }
    });

    test('the ready-made looks leave text and spacing as designed', () {
      final keys = {for (final setting in settings.elementLayout) setting.key};
      for (final look in AppThemes.builtIn) {
        expect(look.values.keys.toSet().intersection(keys), isEmpty, reason: look.name);
      }
    });
  });
}
