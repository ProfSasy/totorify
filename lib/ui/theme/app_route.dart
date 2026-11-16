import 'package:flutter/cupertino.dart';

import '../../services/app_settings.dart';

/// The route every screen is opened with, in the transition the user chose.
Route<T> appRoute<T>({required WidgetBuilder builder, RouteSettings? settings}) {
  final style = AppSettings.instance.pageTransition.value;
  if (style == 0) {
    return CupertinoPageRoute<T>(builder: builder, settings: settings);
  }
  if (style == 4) {
    return PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (context, a, b) => builder(context),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }
  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (context, a, b) => builder(context),
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      switch (style) {
        case 2:
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              child: child,
            ),
          );
        case 3:
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(curved),
            child: child,
          );
        default:
          return FadeTransition(opacity: curved, child: child);
      }
    },
  );
}

/// Scrolling in the way the user chose.
class AppScrollBehavior extends ScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      switch (AppSettings.instance.scrollFeel.value) {
        1 => const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        2 => const BouncingScrollPhysics(
            decelerationRate: ScrollDecelerationRate.fast,
            parent: AlwaysScrollableScrollPhysics(),
          ),
        _ => const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      };

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
