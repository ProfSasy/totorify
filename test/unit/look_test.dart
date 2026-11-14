import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/app_settings.dart';
import 'package:kreate_ios/services/app_themes.dart';
import 'package:kreate_ios/ui/ordered_choice.dart';
import 'package:kreate_ios/ui/theme/app_theme.dart';
import 'package:kreate_ios/ui/widgets/cover_card.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('OrderedChoice', () {
    const choice = OrderedChoice(['a', 'b', 'c', 'd'], alwaysShown: {'a'});

    test('nothing chosen: as designed', () {
      expect(choice.order(const []), ['a', 'b', 'c', 'd']);
      expect(choice.visible(const [], const []), ['a', 'b', 'c', 'd']);
    });

    test('the order chosen is kept, unknown and repeated names dropped', () {
      expect(choice.order(['d', 'x', 'c', 'd', 'b', 'a']), ['d', 'c', 'b', 'a']);
    });

    test('items the saved order does not know go where the design put them', () {
      expect(choice.order(['c', 'a']), ['b', 'c', 'a', 'd']);
    });

    test('hidden items are left out, but not those always shown', () {
      expect(choice.visible(const [], ['a', 'c']), ['a', 'b', 'd']);
    });

    test('moving an item, with the indices of a reorderable list', () {
      // Dropped below the third row.
      expect(choice.moved(const [], 0, 3), ['b', 'c', 'a', 'd']);
      // Dragged to the top.
      expect(choice.moved(const [], 3, 0), ['d', 'a', 'b', 'c']);
      // To the very end.
      expect(choice.moved(const [], 1, 4), ['a', 'c', 'd', 'b']);
      expect(choice.moved(const [], 9, 0), ['a', 'b', 'c', 'd']);
    });

    test('the bar always has the Home, and every tab and button has a name', () {
      expect(NavLayout.tabs.visible(const [], NavLayout.tabs.designed), [NavLayout.home]);
      expect(NavLayout.labels.keys.toSet(), NavLayout.tabs.designed.toSet());
      expect(PlayerActions.labels.keys.toSet(), PlayerActions.buttons.designed.toSet());
      expect(PlayerActions.buttons.visible(const [], PlayerActions.buttons.designed), isEmpty);
    });
  });

  group('colors chosen one by one', () {
    test('nothing chosen: the designed scheme', () {
      final scheme = AppTheme.schemeFor(isAmoled: false);
      expect(scheme.onSurface, Colors.white);
      expect(scheme.onSurfaceVariant, const Color(0xFFB3B3B3));
      expect(scheme.brightness, Brightness.dark);
    });

    test('a light background brings dark text and a light theme', () {
      const paper = Color(0xFFF4F1EA);
      final scheme = AppTheme.schemeFor(isAmoled: false, background: paper);
      expect(scheme.surfaceDim, paper);
      expect(scheme.brightness, Brightness.light);
      expect(contrast(scheme.onSurface, scheme.surfaceDim), greaterThan(7));
      expect(contrast(scheme.onSurfaceVariant, scheme.surfaceDim), greaterThan(3));
      // The surfaces step away from the background, and stay readable.
      expect(scheme.surface, isNot(paper));
      expect(contrast(scheme.onSurface, scheme.surfaceContainerHighest), greaterThan(7));
    });

    test('a dark background keeps light text', () {
      final scheme = AppTheme.schemeFor(isAmoled: false, background: const Color(0xFF101830));
      expect(scheme.brightness, Brightness.dark);
      expect(contrast(scheme.onSurface, scheme.surfaceDim), greaterThan(7));
    });

    test('each color chosen is used as it is', () {
      final scheme = AppTheme.schemeFor(
        isAmoled: true,
        background: const Color(0xFF102030),
        surfaceColor: const Color(0xFF203040),
        text: const Color(0xFFFFE0B0),
        textSecondary: const Color(0xFF90A0B0),
      );
      expect(scheme.surfaceDim, const Color(0xFF102030));
      expect(scheme.surface, const Color(0xFF203040));
      expect(scheme.onSurface, const Color(0xFFFFE0B0));
      expect(scheme.onSurfaceVariant, const Color(0xFF90A0B0));
      expect(scheme.surfaceContainerHigh, isNot(scheme.surface));
    });

    test('a text color alone gives a secondary text between it and the background', () {
      final scheme = AppTheme.schemeFor(isAmoled: false, text: const Color(0xFFFFD27F));
      expect(scheme.onSurface, const Color(0xFFFFD27F));
      expect(scheme.onSurfaceVariant, isNot(const Color(0xFFB3B3B3)));
      expect(
        contrast(scheme.onSurfaceVariant, scheme.surfaceDim),
        lessThan(contrast(scheme.onSurface, scheme.surfaceDim)),
      );
    });

    test('any other choice about the look makes another theme', () {
      final a = AppTheme.getTheme(revision: 1);
      final b = AppTheme.getTheme(revision: 2);
      expect(a.extension<AppShape>(), isNot(b.extension<AppShape>()));
      expect(AppTheme.getTheme(revision: 1).extension<AppShape>(), a.extension<AppShape>());
    });
  });

  group('looks', () {
    test('a look survives being written down and read back', () {
      const look = AppLook(name: 'Mio', values: {
        AppLook.accentKey: 0xFF123456,
        AppLook.amoledKey: true,
        'font_family': 'Georgia',
        'text_scale': 1.15,
        'player_hidden_actions': ['devices', 'queue'],
      });
      final back = AppLook.decode(look.encode())!;
      expect(back.name, 'Mio');
      expect(back.values[AppLook.accentKey], 0xFF123456);
      expect(back.values[AppLook.amoledKey], isTrue);
      expect(back.values['text_scale'], 1.15);
      expect(back.values['player_hidden_actions'], ['devices', 'queue']);
      expect(back.builtIn, isFalse);
    });

    test('what is not a look is not read as one', () {
      expect(AppLook.decode('not json'), isNull);
      expect(AppLook.decode('{"name": 3, "values": {}}'), isNull);
      expect(AppLook.decode('{"name": "x"}'), isNull);
      expect(AppLook.decode('[]'), isNull);
    });

    test('the ready-made looks name only settings that exist, with values of their kind', () {
      final byKey = {for (final setting in AppSettings.instance.appearance) setting.key: setting};
      expect(AppThemes.builtIn.map((look) => look.name).toSet(), hasLength(AppThemes.builtIn.length));
      for (final look in AppThemes.builtIn) {
        expect(look.builtIn, isTrue);
        expect(look.values[AppLook.accentKey], isA<int>(), reason: look.name);
        expect(look.values[AppLook.amoledKey], isA<bool>(), reason: look.name);
        for (final entry in look.values.entries) {
          if (entry.key == AppLook.accentKey || entry.key == AppLook.amoledKey) continue;
          final setting = byKey[entry.key];
          expect(setting, isNotNull, reason: '${look.name}: ${entry.key}');
          expect(
            entry.value.runtimeType.toString().replaceAll('<String>', '<dynamic>'),
            anyOf(
              setting!.fallback.runtimeType.toString().replaceAll('<String>', '<dynamic>'),
              // A whole number where a size is expected.
              setting.fallback is double ? 'int' : 'never',
            ),
            reason: '${look.name}: ${entry.key}',
          );
        }
      }
    });

    test('the first ready-made look is the designed one', () {
      final designed = AppThemes.builtIn.first;
      expect(designed.values.keys.toSet(), {AppLook.accentKey, AppLook.amoledKey});
      expect(designed.values[AppLook.amoledKey], isFalse);
    });

    test('every choice about the look is in the list the theme listens to, once', () {
      final keys = [for (final setting in AppSettings.instance.appearance) setting.key];
      expect(keys.toSet(), hasLength(keys.length));
      expect(
        keys,
        containsAll([
          'font_family',
          'color_background',
          'list_density',
          'nav_tabs',
          'mini_player_style',
          'player_action_order',
          'home_sections',
          'motion_speed',
        ]),
      );
      // The saved looks are not part of a look.
      expect(keys, isNot(contains('saved_themes')));
    });
  });

  group('cards', () {
    test('a row of cards is as tall as its cards, text included', () {
      expect(CoverCard.rowSize(118), 118);
      expect(CoverCard.heightFor(118), 118 + 32 + 19);
      expect(CoverCard.heightFor(150, subtitleLines: 2), 150 + 32 + 38);
    });
  });
}
