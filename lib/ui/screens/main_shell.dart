import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/totorify_nav_bar.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

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
  int _currentIndex = 0;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      HomeScreen(audioHandler: widget.audioHandler),
      SearchScreen(
        audioHandler: widget.audioHandler,
        onGoHome: () => _goToTab(0),
      ),
      LibraryScreen(audioHandler: widget.audioHandler),
      SettingsScreen(
        audioHandler: widget.audioHandler,
        onThemeChanged: widget.onThemeChanged,
      ),
    ];
  }

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    PlaybackLogService.instance.log('UI', 'bottom nav tab=$index');
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    // Floating nav bar height (safe area included).
    final bottomNavHeight = TotorifyNavBar.totalHeight(context);

    return Scaffold(
      // Extend body behind the floating nav bar so content scrolls under it.
      extendBody: true,
      // The inner screens handle the keyboard inset themselves; resizing here
      // too would double-compensate and make the search field jump.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Current Tab Screen — content scrolls under mini player.
          // Hidden tabs have their tickers paused: the ambient Home backdrop
          // keeps breathing only while it is actually visible.
          IndexedStack(
            index: _currentIndex,
            children: [
              for (var i = 0; i < _screens.length; i++)
                TickerMode(
                  enabled: i == _currentIndex,
                  child: _screens[i],
                ),
            ],
          ),

          // ── Mini Player ─────────────────────────────────────────────────
          // Floats right above the glass nav bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomNavHeight,
            child: StreamBuilder<MediaItem?>(
              stream: widget.audioHandler.mediaItem,
              builder: (context, snapshot) {
                // The mini player is always visible while a song is loaded,
                // except in Settings (tab 3) where it would cover the rows.
                final hasSong = _currentIndex != 3 &&
                    snapshot.hasData &&
                    snapshot.data != null;
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

      // ── Bottom Navigation (floating glass) ─────────────────────────────
      bottomNavigationBar: TotorifyNavBar(
        currentIndex: _currentIndex,
        onTap: _goToTab,
      ),
    );
  }
}
