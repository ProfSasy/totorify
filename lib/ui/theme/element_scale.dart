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
