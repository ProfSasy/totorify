import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/app_settings.dart';
import 'package:kreate_ios/ui/theme/app_theme.dart';
import 'package:kreate_ios/ui/theme/app_tokens.dart';

void main() {
  tearDown(() => AppText.titleScale = 1.0);

  test('the big titles follow the size chosen, the small text does not', () {
    final cs = const ColorScheme.dark();
    final base = AppText.screenTitle(cs).fontSize!;
    final small = AppText.tileSubtitle(cs).fontSize!;
    AppText.titleScale = AppText.titleScales[3];
    expect(AppText.screenTitle(cs).fontSize, closeTo(base * 1.4, 0.001));
    expect(AppText.tileSubtitle(cs).fontSize, small);
  });

  test('the theme carries the title size and the density', () {
    final theme = AppTheme.getTheme(titleScale: 1.2, density: 0);
    expect(AppText.titleScale, 1.2);
    expect(theme.visualDensity, VisualDensity.compact);
    expect(AppTheme.getTheme().visualDensity, VisualDensity.standard);
  });

  test('by default nothing changes', () {
    final s = AppSettings.instance;
    expect(s.titleSize.value, 1);
    expect(s.uiDensity.value, 1);
    expect(s.boldText.value, isFalse);
    expect(AppText.titleScales[s.titleSize.value], 1.0);
  });
}
