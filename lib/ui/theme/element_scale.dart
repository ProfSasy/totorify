import 'package:flutter/painting.dart';

import '../../services/app_settings.dart';
import 'app_tokens.dart';

/// How large the text of one element is (a title in the lists, the artist
/// in the player…), on top of the size of the text of the whole app.
///
/// Each element has a level, 0 to 4; [designed] leaves it as it was drawn.
class ElementScale {
  ElementScale._();

  /// The multiplier of each level.
  static const List<double> factors = [0.85, 0.93, 1.0, 1.1, 1.25];

  /// The level of the designed size.
  static const int designed = 2;

  static const List<String> labels = [
    'Molto piccolo',
    'Piccolo',
    'Predefinito',
    'Grande',
    'Molto grande',
  ];

  /// The multiplier of [level]; a level out of range takes the nearest one.
  static double factorAt(int level) => factors[level.clamp(0, factors.length - 1)];

  /// The multiplier chosen in [setting].
  static double of(Setting<int> setting) => factorAt(setting.value);

  /// [style] with its size times [factor]: the very same style at 1.
  static TextStyle scaled(TextStyle style, double factor) {
    final size = style.fontSize;
    if (factor == 1.0 || size == null) return style;
    return style.copyWith(fontSize: size * factor);
  }
}

/// The room around the content of the pages: the side margin, the space
/// above a section and between the cards of a row. Each is a level; the
/// designed one is level 1, the value the app always had.
class PageSpacing {
  PageSpacing._();

  /// The level of the designed spacing.
  static const int designed = 1;

  /// The side margin of the pages.
  static const List<double> margins = [12, AppSpacing.lg, 20, 28];
  static const List<String> marginLabels = ['Stretto', 'Predefinito', 'Largo', 'Molto largo'];

  /// The space above the title of a section.
  static const List<double> sectionGaps = [12, AppSpacing.xl, 32, 44];

  /// The space between two cards of a row that scrolls sideways.
  static const List<double> cardGaps = [8, AppSpacing.lg, 22, 30];

  static const List<String> gapLabels = ['Stretta', 'Predefinita', 'Larga', 'Molto larga'];

  static double _at(List<double> values, int level) =>
      values[level.clamp(0, values.length - 1)];

  static double marginAt(int level) => _at(margins, level);
  static double sectionGapAt(int level) => _at(sectionGaps, level);
  static double cardGapAt(int level) => _at(cardGaps, level);

  /// The values chosen now. Widgets reading them are drawn again with the
  /// theme, which is made again when one of them changes.
  static double get margin => marginAt(AppSettings.instance.pageMargin.value);
  static double get sectionGap => sectionGapAt(AppSettings.instance.sectionGap.value);
  static double get cardGap => cardGapAt(AppSettings.instance.cardGap.value);
}

/// How tall the tab bar and the mini player are. Each is a level; the
/// designed one is level 1, the height they always had.
class BarSizes {
  BarSizes._();

  /// The level of the designed heights.
  static const int designed = 1;

  static const List<String> navLabels = ['Compatta', 'Predefinita', 'Ampia', 'Molto ampia'];
  static const List<String> miniLabels = ['Compatto', 'Predefinito', 'Ampio', 'Molto ampio'];

  // ── Tab bar ─────────────────────────────────────────────────────────────

  /// The tab bar, without the safe area under it.
  static const List<double> navHeights = [48, 56, 64, 72];

  /// The icons of the tabs.
  static const List<double> navIcons = [24, 26, 28, 30];

  /// The space between an icon and its name.
  static const List<double> navGaps = [2, 4, 5, 6];

  // ── Mini player ─────────────────────────────────────────────────────────

  /// The cover, and the boxes of play and of previous / next.
  /// The lowest is as tall as title and artist at the designed size of the
  /// text: lower, they would hold the row up anyway.
  static const List<double> miniRows = [36, 40, 54, 62];

  /// The room above and under the row.
  static const List<double> miniTops = [6, 8, 10, 12];
  static const List<double> miniBottoms = [4, 6, 8, 10];

  /// The play / pause icon.
  static const List<double> miniPlayIcons = [27, 30, 33, 36];

  /// The row as drawn: the heart, with its tap area, is taller than the
  /// cover (measured: the mini player is 70 high, 22 of them around the
  /// row). The other levels hold every button to their own row.
  static const double miniDesignedRow = 48;

  static double _at(List<double> values, int level) =>
      values[level.clamp(0, values.length - 1)];

  static double navHeightAt(int level) => _at(navHeights, level);
  static double navIconAt(int level) => _at(navIcons, level);
  static double navGapAt(int level) => _at(navGaps, level);
  static double miniRowAt(int level) => _at(miniRows, level);
  static double miniTopAt(int level) => _at(miniTops, level);
  static double miniBottomAt(int level) => _at(miniBottoms, level);
  static double miniPlayIconAt(int level) => _at(miniPlayIcons, level);

  /// The height the buttons of the mini player are held to at [level]:
  /// none at the designed one, which keeps them as they were.
  static double? miniButtonBoxAt(int level) =>
      level.clamp(0, miniRows.length - 1) == designed ? null : miniRowAt(level);

  /// How much taller (or lower, when negative) the mini player is at
  /// [level] than as designed.
  static double miniExtraAt(int level) {
    final row = level.clamp(0, miniRows.length - 1) == designed
        ? miniDesignedRow
        : miniRowAt(level);
    return (miniTopAt(level) - miniTopAt(designed)) +
        (miniBottomAt(level) - miniBottomAt(designed)) +
        (row - miniDesignedRow);
  }

  /// What a list leaves free at its end, so that its last row can scroll
  /// above the mini player and the tab bar: exactly
  /// [AppSpacing.bottomContentInset] at the designed heights.
  static double bottomInsetAt(int nav, int mini) =>
      AppSpacing.bottomContentInset +
      (navHeightAt(nav) - navHeightAt(designed)) +
      miniExtraAt(mini);

  /// The values chosen now. Widgets reading them are drawn again with the
  /// theme, which is made again when one of them changes.
  static int get _nav => AppSettings.instance.navBarHeight.value;
  static int get _mini => AppSettings.instance.miniPlayerHeight.value;

  static double get navHeight => navHeightAt(_nav);
  static double get navIcon => navIconAt(_nav);
  static double get navGap => navGapAt(_nav);
  static double get miniExtra => miniExtraAt(_mini);
  static double get bottomInset => bottomInsetAt(_nav, _mini);
}
