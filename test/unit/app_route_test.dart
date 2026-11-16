import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/app_settings.dart';
import 'package:kreate_ios/ui/theme/app_route.dart';

void main() {
  final style = AppSettings.instance.pageTransition;

  tearDown(() => style.value = 0);

  test('by default screens open with the iOS slide', () {
    expect(appRoute<void>(builder: (_) => const SizedBox()), isA<CupertinoPageRoute<void>>());
  });

  test('every other style has its own route, and none has no duration', () {
    for (final v in [1, 2, 3]) {
      style.value = v;
      final route = appRoute<void>(builder: (_) => const SizedBox()) as PageRouteBuilder<void>;
      expect(route.transitionDuration, greaterThan(Duration.zero));
    }
    style.value = 4;
    final none = appRoute<void>(builder: (_) => const SizedBox()) as PageRouteBuilder<void>;
    expect(none.transitionDuration, Duration.zero);
  });
}
