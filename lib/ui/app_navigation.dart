import 'package:flutter/widgets.dart';

/// Remembers the pages open in one tab, so they can be closed all at once.
class TabRoutes extends NavigatorObserver {
  final List<Route<dynamic>> routes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) routes[index] = newRoute;
  }
}

/// The tabs of the app each keep their own stack of pages, so the tab bar
/// and the mini player stay on screen while the user goes deeper.
///
/// A tab keeps its pages only while it is on screen: the button of a tab
/// always leads to that tab's first page, never to whatever was left open
/// in it. What does not belong to any tab (the Settings) opens above them.
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

  /// Pages open in each tab; given to the tab's navigator as an observer.
  static final List<TabRoutes> tabRoutes =
      List.generate(tabCount, (_) => TabRoutes());

  static final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

  /// Builds the Settings page; set by the shell, which owns what it needs.
  static WidgetBuilder? settingsBuilder;

  static NavigatorState? get _current => tabKeys[currentTab.value].currentState;

  /// Pushes [route] on the tab that is on screen (or on the navigator of
  /// [context] when the tabs are not there, as during the login).
  static Future<T?> push<T>(BuildContext context, Route<T> route) =>
      (_current ?? Navigator.of(context)).push(route);

  /// Closes every page open in the tab at [index], leaving its first one.
  /// Nothing is animated: the tab is not on screen when this is called.
  static void resetTab(int index) {
    final navigator = tabKeys[index].currentState;
    if (navigator == null) return;
    for (final route in tabRoutes[index].routes.skip(1).toList()) {
      if (route.navigator == navigator && route.isActive) {
        navigator.removeRoute(route);
      }
    }
  }
}
