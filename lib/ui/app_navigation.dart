import 'package:flutter/widgets.dart';

/// The tabs of the app each keep their own stack of pages, so the tab bar
/// and the mini player stay on screen while the user goes deeper.
///
/// A tab remembers the page it was left on. The button of the tab that is
/// already open goes back to its first page, and then to the top of it.
/// What does not belong to any tab (the Settings) opens above them.
///
/// Pages opened from inside a tab find their navigator on their own. What
/// is opened from a sheet (the player, a song's menu) lives above the tabs
/// and uses [push] to land in the tab that is on screen.
class AppNavigation {
  AppNavigation._();

  static const int homeTab = 0;
  static const int searchTab = 1;
  static const int libraryTab = 2;
  static const int tabCount = 3;

  static final List<GlobalKey<NavigatorState>> tabKeys = List.generate(
    tabCount,
    (index) => GlobalKey<NavigatorState>(debugLabel: 'tab $index'),
  );

  /// Scroll position of the first page of each tab.
  static final List<ScrollController> rootScrollers =
      List.generate(tabCount, (_) => ScrollController());

  static final ValueNotifier<int> currentTab = ValueNotifier<int>(0);

  /// Builds the Settings page; set by the shell, which owns what it needs.
  static WidgetBuilder? settingsBuilder;

  static NavigatorState? get _current => tabKeys[currentTab.value].currentState;

  /// Pushes [route] on the tab that is on screen (or on the navigator of
  /// [context] when the tabs are not there, as during the login).
  static Future<T?> push<T>(BuildContext context, Route<T> route) =>
      (_current ?? Navigator.of(context)).push(route);

  /// What the button of the open tab does: back to the tab's first page,
  /// or to the top of that page when it is already there.
  static void backToStart(int index) {
    final navigator = tabKeys[index].currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    final scroller = rootScrollers[index];
    if (scroller.hasClients && scroller.offset > 0) {
      scroller.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }
}
