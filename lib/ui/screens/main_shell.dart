import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../app_navigation.dart';
import '../widgets/mini_player.dart';
import '../widgets/totorify_nav_bar.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// The frame of the app: three tabs, each with its own stack of pages, and
/// the tab bar and the mini player that stay on screen above all of them.
class MainShell extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final VoidCallback onThemeChanged;

  const MainShell({
    super.key,
    required this.audioHandler,
    required this.onThemeChanged,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const List<String> _tabNames = ['home', 'cerca', 'libreria'];

  int _currentIndex = 0;

  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    AppNavigation.currentTab.value = 0;
    for (final tab in AppNavigation.tabRoutes) {
      tab.routes.clear();
    }
    AppNavigation.settingsBuilder = (_) => SettingsScreen(
          audioHandler: widget.audioHandler,
          onThemeChanged: widget.onThemeChanged,
        );
    _tabs = [
      _tab(0, HomeScreen(audioHandler: widget.audioHandler)),
      _tab(1, SearchScreen(audioHandler: widget.audioHandler)),
      _tab(2, LibraryScreen(audioHandler: widget.audioHandler)),
    ];
  }

  Widget _tab(int index, Widget root) => Navigator(
        key: AppNavigation.tabKeys[index],
        observers: [AppNavigation.tabRoutes[index]],
        onGenerateRoute: (settings) => CupertinoPageRoute<void>(
          settings: settings,
          builder: (_) => root,
        ),
      );

  void _goToTab(int index) {
    if (index == _currentIndex) {
      // Tapping the tab that is already open goes back to its first page.
      AppNavigation.tabKeys[index].currentState?.popUntil((route) => route.isFirst);
      return;
    }
    PlaybackLogService.instance.log('UI', 'tab ${_tabNames[index]}');
    FocusManager.instance.primaryFocus?.unfocus();
    // The tab being left goes back to its first page: coming back to it
    // must not show a page forgotten open there.
    final left = _currentIndex;
    AppNavigation.currentTab.value = index;
    setState(() => _currentIndex = index);
    AppNavigation.resetTab(left);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomNavHeight = TotorifyNavBar.totalHeight(context);

    return Scaffold(
      // Extend body behind the tab bar so content scrolls under it.
      extendBody: true,
      // The inner screens handle the keyboard inset themselves; resizing here
      // too would double-compensate and make the search field jump.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Hidden tabs keep their state but have their tickers paused; the
          // tab that comes on screen fades in.
          IndexedStack(
            index: _currentIndex,
            children: [
              for (var i = 0; i < _tabs.length; i++)
                AnimatedOpacity(
                  opacity: i == _currentIndex ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  child: TickerMode(
                    enabled: i == _currentIndex,
                    child: _tabs[i],
                  ),
                ),
            ],
          ),

          // The content dissolves into the background behind the mini
          // player and the tab bar, which have no surface of their own.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: bottomNavHeight + 96,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      cs.surfaceDim.withValues(alpha: 0),
                      cs.surfaceDim.withValues(alpha: 0.9),
                      cs.surfaceDim,
                    ],
                    // Solid from the top edge of the tab bar down.
                    stops: [0.0, 0.3, 96 / (bottomNavHeight + 96)],
                  ),
                ),
              ),
            ),
          ),

          // ── Mini Player ─────────────────────────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomNavHeight,
            child: StreamBuilder<MediaItem?>(
              stream: widget.audioHandler.mediaItem,
              builder: (context, snapshot) {
                final hasSong = snapshot.data != null;
                return AnimatedSlide(
                  offset: hasSong ? Offset.zero : const Offset(0, 1.5),
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: hasSong ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: MiniPlayer(audioHandler: widget.audioHandler),
                  ),
                );
              },
            ),
          ),
        ],
      ),

      bottomNavigationBar: TotorifyNavBar(
        currentIndex: _currentIndex,
        onTap: _goToTab,
      ),
    );
  }
}
