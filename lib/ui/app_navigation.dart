import 'package:flutter/widgets.dart';

/// The tabs of the app each keep their own stack of pages, so the tab bar
/// and the mini player stay on screen while the user goes deeper.
///
/// Pages opened from inside a tab find their navigator on their own. What
/// is opened from a sheet (the player, a song's menu) lives above the tabs
/// and uses [push] to land in the tab that is on screen.
class AppNavigation {
  AppNavigation._();

  static const int tabCount = 3;

  static final List<GlobalKey<NavigatorState>> tabKeys = List.generate(
    tabCount,
    (index) => GlobalKey<NavigatorState>(debugLabel: 'tab $index'),
  );

  static final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

  /// Builds the Settings page; set by the shell, which owns what it needs.
  static WidgetBuilder? settingsBuilder;

  static NavigatorState? get _current => tabKeys[currentTab.value].currentState;

  /// Pushes [route] on the tab that is on screen (or on the navigator of
  /// [context] when the tabs are not there, as during the login).
  static Future<T?> push<T>(BuildContext context, Route<T> route) =>
      (_current ?? Navigator.of(context)).push(route);
}
