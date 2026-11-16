import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../../services/app_settings.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../app_navigation.dart';
import '../widgets/mini_player.dart';
import '../widgets/totorify_nav_bar.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import '../theme/app_route.dart';
import '../theme/app_theme.dart';
import '../theme/element_scale.dart';

/// The frame of the app: three tabs, each with its own stack of pages (kept
/// while the user is in another tab), and
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

  // The last song the mini player showed, kept while it slides away when
  // nothing plays any more (it would otherwise vanish at once).
  MediaItem? _lastMediaItem;
  bool _hasSong = false;

  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    AppNavigation.currentTab.value = 0;
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

  /// The theme of tab [index]: the app's, with the background and the
  /// accent chosen for that tab, if any.
  static ThemeData _tabTheme(ThemeData base, int index) {
    final colors = AppSettings.instance.tabColors(index);
    Color? chosen(Setting<int> c) => c.value == 0 ? null : Color(c.value);
    return AppTheme.forScreen(
      base,
      background: chosen(colors[0]),
      accent: chosen(colors[1]),
    );
  }

  /// Each tab can have a background and an accent of its own.
  Widget _tab(int index, Widget root) {
    final navigator = Navigator(
      key: AppNavigation.tabKeys[index],
      onGenerateRoute: (settings) => appRoute<void>(
        settings: settings,
        builder: (_) => root,
      ),
    );
    return ListenableBuilder(
      // The colors of a tab are among the choices about the look, which
      // also make a new theme of the app (read below with Theme.of).
      listenable: Listenable.merge(AppSettings.instance.appearance),
      // The navigator is the same one at every change (and has a global
      // key): only the theme above it is made again, its pages stay.
      child: navigator,
      builder: (context, child) => Theme(
        data: _tabTheme(Theme.of(context), index),
        child: child!,
      ),
    );
  }

  void _goToTab(int index) {
    if (index == TotorifyNavBar.createIndex) {
      // The library makes and keeps what is created: its menu opens there.
      PlaybackLogService.instance.log('UI', 'tab Crea');
      if (_currentIndex != 2) _goToTab(2);
      LibraryScreen.requestCreate();
      return;
    }
    if (index == _currentIndex) {
      AppNavigation.backToStart(index);
      return;
    }
    PlaybackLogService.instance.log('UI', 'tab ${_tabNames[index]}');
    FocusManager.instance.primaryFocus?.unfocus();
    AppNavigation.currentTab.value = index;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    // What is around the tabs (the fade under the tab bar, the tab bar,
    // what shows while a tab fades in) takes the colors of the tab on
    // screen: a background of its own would otherwise end in a band of the
    // app's. A change of these colors makes a new theme of the app, which
    // builds this again.
    final tabTheme = _tabTheme(Theme.of(context), _currentIndex);
    final cs = tabTheme.colorScheme;
    final bottomNavHeight = TotorifyNavBar.totalHeight(context);
    // The fade covers the mini player too, taller or lower as it is.
    final fade = 96 + BarSizes.miniExtra;

    return Scaffold(
      backgroundColor: tabTheme.scaffoldBackgroundColor,
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
            height: bottomNavHeight + fade,
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
                    stops: [0.0, 0.3, fade / (bottomNavHeight + fade)],
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
                final item = snapshot.data;
                final hasSong = item != null;
                _hasSong = hasSong;
                if (hasSong) _lastMediaItem = item;
                return AnimatedSlide(
                  offset: hasSong ? Offset.zero : const Offset(0, 1.5),
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  // Gone: the song it kept for its exit is let go.
                  onEnd: () {
                    if (!_hasSong && _lastMediaItem != null && mounted) {
                      setState(() => _lastMediaItem = null);
                    }
                  },
                  child: AnimatedOpacity(
                    opacity: hasSong ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    // While it leaves it still shows the last song, but a
                    // tap would open a player with nothing to play.
                    child: IgnorePointer(
                      ignoring: !hasSong,
                      child: MiniPlayer(
                        audioHandler: widget.audioHandler,
                        leaving: _lastMediaItem,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),

      // Its icons are drawn on the fade above, in the tab's colors.
      bottomNavigationBar: Theme(
        data: tabTheme,
        child: TotorifyNavBar(
          currentIndex: _currentIndex,
          onTap: _goToTab,
        ),
      ),
    );
  }
}
