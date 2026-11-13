import 'dart:async';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/song.dart';
import '../../services/app_settings.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/canvas_service.dart';
import '../../services/canvas_video_pool.dart';
import '../screens/artist_screen.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'alternative_sources_sheet.dart';
import 'app_sheet.dart';
import 'canvas_player_widget.dart';
import 'lyrics_view.dart';
import 'player_cards.dart';
import 'song_options_sheet.dart';
import 'player/player_style.dart';
import 'player/player_header.dart';
import 'player/player_cover.dart';
import 'player/player_title_row.dart';
import 'player/player_seek_bar.dart';
import 'player/player_controls.dart';
import 'player/player_actions_row.dart';
import 'player/canvas_toggle.dart';
import 'player/player_queue_tab.dart';
import 'player/track_details.dart';
import 'player/player_background.dart';

/// Full-screen now-playing sheet with three tabs: player, lyrics, queue.
/// Its background, its play button and what is switched on in it take their
/// colors from the cover of the track, and cross-fade when the track changes.
class PlayerSheet extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const PlayerSheet({super.key, required this.audioHandler});

  /// True while the sheet is on screen. It covers the whole screen, snack
  /// bars included, so it shows playback messages itself.
  static bool isOpen = false;

  /// Whether choosing a song opens the player over the page. On a phone it
  /// does; where the player has a bar of its own always in sight (the
  /// computer app) the page stays, and the player opens when asked.
  static bool opensOnPlay = true;

  /// For the pages, after starting a song.
  static void showOnPlay(BuildContext context, AudioPlayerHandler audioHandler) {
    if (opensOnPlay) show(context, audioHandler);
  }

  static void show(BuildContext context, AudioPlayerHandler audioHandler) {
    PlaybackLogService.instance.log('UI', 'player: apri');
    showModalBottomSheet(
      context: context,
      // Above the tabs, which keep their own stacks of pages.
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      showDragHandle: false,
      enableDrag: true,
      useSafeArea: false,
      // The sheet keeps its own MediaQuery: using the caller's would inherit
      // any SafeArea padding already consumed by the launching screen and
      // break the status-bar inset of the player header.
      builder: (ctx) => PlayerSheet(audioHandler: audioHandler),
    );
  }

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late final AnimationController _enterController;
  late final Animation<double> _enterCurve;
  String? _lastLoadedSongId;

  StreamSubscription<String>? _errorSub;
  StreamSubscription<String>? _infoSub;
  int _lastTabIndex = 0;

  // Canvas state
  bool _showCanvas = true;

  // Whether the main tab has been scrolled down to its cards: the Canvas
  // switch, which floats over the cover, then gets out of the way.
  final ValueNotifier<bool> _scrolledToCards = ValueNotifier<bool>(false);
  String? _currentCanvasUrl;
  bool _isLoadingCanvas = false;
  int _canvasLoadGeneration = 0;
  // One automatic retry per song when the video fails to initialize.
  String? _canvasRetriedFor;
  int _canvasAttempt = 0;
  // Identity of the Canvas video whose first frame is ready. Until then the
  // cover stays where it is, and then gives way to the video: the player
  // never shows a blown-up cover while a video loads.
  String? _readyCanvasKey;

  String? get _canvasKey {
    final url = _currentCanvasUrl;
    if (url == null) return null;
    return 'fullscreen_canvas_${widget.audioHandler.currentSong?.id}_${url}_$_canvasAttempt';
  }

  /// True when the Canvas takes the place of the cover.
  bool get _canvasShown =>
      _showCanvas && _currentCanvasUrl != null && _readyCanvasKey == _canvasKey;

  // Short message shown over the player (a failed track, a timer set).
  String? _notice;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    PlayerSheet.isOpen = true;
    _enterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _enterCurve = CurvedAnimation(
      parent: _enterController,
      curve: Curves.easeOutCubic,
    );
    _enterController.forward();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!mounted || _tabController.index == _lastTabIndex) return;
      PlaybackLogService.instance.log(
        'UI',
        'player: tab=${_tabController.index == 0 ? 'player' : _tabController.index == 1 ? 'testi' : 'coda'}',
      );
      setState(() => _lastTabIndex = _tabController.index);
      if (_tabController.index != 0) _scrolledToCards.value = false;
    });

    final current = widget.audioHandler.currentSong;
    if (current != null) {
      _loadCanvas(current);
    }
    CanvasService.instance.isCanvasEnabledNotifier.addListener(_onCanvasSettingChanged);

    _errorSub = widget.audioHandler.errorStream.listen(_showNotice);
    _infoSub = widget.audioHandler.infoStream.listen(_showNotice);
  }

  void _showNotice(String message) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void dispose() {
    _scrolledToCards.dispose();
    CanvasService.instance.isCanvasEnabledNotifier.removeListener(_onCanvasSettingChanged);
    _errorSub?.cancel();
    _infoSub?.cancel();
    _noticeTimer?.cancel();
    PlayerSheet.isOpen = false;
    PlaybackLogService.instance.log('UI', 'player: chiudi');
    _enterController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onCanvasSettingChanged() {
    if (mounted) {
      _loadCanvas(widget.audioHandler.currentSong);
    }
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final haptics = AppSettings.instance.haptics.value;
    if (velocity < -200) {
      if (haptics) HapticFeedback.mediumImpact();
      widget.audioHandler.skipToNext();
    } else if (velocity > 200) {
      if (haptics) HapticFeedback.mediumImpact();
      widget.audioHandler.skipToPrevious();
    }
  }

  Future<void> _loadCanvas(Song? song) async {
    final generation = ++_canvasLoadGeneration;
    if (song == null || !CanvasService.instance.isCanvasEnabledNotifier.value) {
      if (mounted && (_currentCanvasUrl != null || _isLoadingCanvas)) {
        setState(() {
          _currentCanvasUrl = null;
          _isLoadingCanvas = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _isLoadingCanvas = true);
    }
    String? canvasUrl;
    try {
      canvasUrl = await CanvasService.instance.getCanvasUrl(song);
    } catch (error) {
      debugPrint('PlayerSheet._loadCanvas: $error');
    }
    if (mounted &&
        generation == _canvasLoadGeneration &&
        widget.audioHandler.currentSong?.id == song.id) {
      setState(() {
        _currentCanvasUrl = canvasUrl;
        _isLoadingCanvas = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: widget.audioHandler.mediaItem,
      builder: (context, mediaSnapshot) {
        final mediaItem = mediaSnapshot.data;
        final colorScheme = Theme.of(context).colorScheme;
        if (mediaItem == null) {
          // The sheet can be opened a moment before the first media item is
          // published: show a loading state instead of an invisible modal.
          return Container(
            height: MediaQuery.sizeOf(context).height,
            color: colorScheme.surfaceDim,
            child: Center(
              child: CupertinoActivityIndicator(
                radius: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }

        final currentSong = widget.audioHandler.currentSong;
        if (currentSong != null && currentSong.id != _lastLoadedSongId) {
          _lastLoadedSongId = currentSong.id;
          _canvasRetriedFor = null;

          final hasCached = CanvasService.instance.hasCachedResult(currentSong.id);
          if (hasCached) {
            _currentCanvasUrl = CanvasService.instance.getCachedCanvasUrlSync(currentSong.id);
            _isLoadingCanvas = false;
          } else {
            _currentCanvasUrl = null;
            _isLoadingCanvas = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _loadCanvas(currentSong);
            });
          }

        }

        // The modal sheet strips padding AND viewPadding from the ambient
        // MediaQuery, so the FlutterView is the only reliable source for the
        // status bar / Dynamic Island inset.
        final flutterView = View.of(context);
        final topInset =
            flutterView.viewPadding.top / flutterView.devicePixelRatio;
        final bottomInset =
            flutterView.viewPadding.bottom / flutterView.devicePixelRatio;

        // Everything in the player takes its colors from the cover.
        return AmbientTint(
          artworkUrl: mediaItem.artUri?.toString(),
          fallback: colorScheme.primary,
          builder: (context, palette) => SizedBox(
            height: MediaQuery.sizeOf(context).height,
            child: StreamBuilder<PlaybackState>(
              stream: widget.audioHandler.playbackState,
              builder: (context, playbackSnapshot) {
                final isPlaying = playbackSnapshot.data?.playing ?? false;
                final canvasAvailable =
                    _showCanvas && _currentCanvasUrl != null;
                // Already warm (the track was prepared ahead, or the player
                // is being reopened): shown from the first frame.
                if (canvasAvailable &&
                    _readyCanvasKey != _canvasKey &&
                    CanvasVideoPool.instance.isWarm(_currentCanvasUrl!)) {
                  _readyCanvasKey = _canvasKey;
                }
                final canvasVisible = _canvasShown && _tabController.index == 0;

                final background = AppSettings.instance.playerBackground.value;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (background == 2)
                      const ColoredBox(color: Colors.black)
                    else if (background == 1 && mediaItem.artUri != null)
                      BlurredCover(url: mediaItem.artUri.toString(), palette: palette)
                    else
                    // The cover's color, from its dark shade down to black.
                    AnimatedContainer(
                      duration: AppMotion.ambience,
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            palette.surface,
                            palette.deep,
                            Color.lerp(palette.deep, Colors.black, 0.55)!,
                          ],
                          stops: const [0.0, 0.62, 1.0],
                        ),
                      ),
                    ),
                    // The Canvas stays mounted (and paused) behind the
                    // lyrics and the queue, so coming back to it is instant.
                    if (canvasAvailable)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: canvasVisible ? 1 : 0,
                            duration: playerCanvasFade,
                            curve: Curves.easeOut,
                            child: _buildFullscreenCanvas(isPlaying),
                          ),
                        ),
                      ),
                    // Scrim that keeps the header and the controls readable
                    // over the video; it comes and goes with it.
                    if (canvasAvailable)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: canvasVisible ? 1 : 0,
                            duration: playerCanvasFade,
                            curve: Curves.easeOut,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.5),
                                    Colors.black.withValues(alpha: 0.08),
                                    Colors.black.withValues(alpha: 0.86),
                                  ],
                                  stops: const [0.0, 0.42, 1.0],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.only(top: topInset),
                      child: Column(
                        children: [
                          PlayerHeader(
                            tabIndex: _tabController.index,
                            currentSong: currentSong,
                            mediaItem: mediaItem,
                            onBackToPlayer: () => _tabController.animateTo(0),
                            onMenu: _showMenu,
                          ),
                          Expanded(
                            child: TabBarView(
                              controller: _tabController,
                              physics: const NeverScrollableScrollPhysics(),
                              children: [
                                _buildMainPlayerTab(
                                  mediaItem,
                                  playbackSnapshot.data,
                                  palette,
                                  bottomInset,
                                ),
                                LyricsView(
                                  audioHandler: widget.audioHandler,
                                  palette: palette,
                                  bottomInset: bottomInset,
                                  visible: _tabController.index == 1,
                                ),
                                PlayerQueueTab(
                                  audioHandler: widget.audioHandler,
                                  palette: palette,
                                  bottomInset: bottomInset,
                                  notify: _showNotice,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Must be the last Stack child so it stays above the header
                    // and the TabBarView and can actually receive taps.
                    if (_tabController.index == 0 &&
                        (_currentCanvasUrl != null || _isLoadingCanvas))
                      Positioned(
                        top: topInset + 58,
                        right: AppSpacing.md,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _scrolledToCards,
                          builder: (context, away, child) => IgnorePointer(
                            ignoring: away,
                            child: AnimatedOpacity(
                              opacity: away ? 0 : 1,
                              duration: AppMotion.fast,
                              child: child,
                            ),
                          ),
                          child: CanvasToggle(
                            palette: palette,
                            showCanvas: _showCanvas,
                            enabled: _currentCanvasUrl != null,
                            isLoading: _isLoadingCanvas,
                            canvasShown: _canvasShown,
                            onToggle: () => setState(() => _showCanvas = !_showCanvas),
                          ),
                        ),
                      ),
                    if (_notice != null)
                      Positioned(
                        left: 20,
                        right: 20,
                        // Below the header and the Canvas toggle.
                        top: topInset + 108,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.inverseSurface,
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              child: Text(
                                _notice!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colorScheme.onInverseSurface,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Animates the whole player block when the sheet opens.
  Widget _buildMainPlayerTab(
    MediaItem mediaItem,
    PlaybackState? playback,
    AmbientPalette palette,
    double bottomInset,
  ) {
    return FadeTransition(
      opacity: _enterCurve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(_enterCurve),
        child: _buildMainPlayerTabContent(mediaItem, playback, palette, bottomInset),
      ),
    );
  }

  Widget _buildMainPlayerTabContent(
    MediaItem mediaItem,
    PlaybackState? playback,
    AmbientPalette palette,
    double bottomInset,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isShortScreen = constraints.maxHeight < 620;
        final gap = isShortScreen ? 6.0 : 14.0;
        final hasCanvas = _canvasShown;
        // Room for the Canvas / cover switch, which floats over this tab.
        final hasSwitch = _currentCanvasUrl != null || _isLoadingCanvas;
        final isPlaying = playback?.playing ?? false;
        final isLoading =
            playback?.processingState == AudioProcessingState.loading ||
                playback?.processingState == AudioProcessingState.buffering;

        final song = widget.audioHandler.currentSong;
        final page = Column(
            children: [
              Expanded(
                child: PlayerCover(
                  mediaItem: mediaItem,
                  hasCanvas: hasCanvas,
                  hasSwitch: hasSwitch,
                  isPlaying: isPlaying,
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  gap,
                  AppSpacing.xl,
                  // Clear of the home indicator, but closer to the edge
                  // than the full safe area would put the controls.
                  math.max(isShortScreen ? 10.0 : 16.0, bottomInset - 10),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PlayerTitleRow(
                      audioHandler: widget.audioHandler,
                      mediaItem: mediaItem,
                      palette: palette,
                      onArtist: _openArtist,
                    ),
                    SizedBox(height: gap),
                    PlayerSeekBar(
                      audioHandler: widget.audioHandler,
                      mediaItem: mediaItem,
                    ),
                    SizedBox(height: isShortScreen ? 0 : 6),

                    PlayerTransportControls(
                      audioHandler: widget.audioHandler,
                      playback: playback,
                      palette: palette,
                      isPlaying: isPlaying,
                      isLoading: isLoading,
                      notify: _showNotice,
                    ),
                    SizedBox(height: isShortScreen ? 2 : 8),

                    PlayerActionsRow(
                      audioHandler: widget.audioHandler,
                      palette: palette,
                      onSleepTimer: _showSleepTimerDialog,
                      onSources: _showSources,
                      onLyrics: () => _tabController.animateTo(1),
                      onQueue: () => _tabController.animateTo(2),
                    ),
                  ],
                ),
              ),
            ],
          );
        // As Spotify's: the player fills the screen and scrolls up to the
        // lyrics, the artist, what plays next and the credits. Pulled down
        // from the top it closes, as the sheet does.
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: _handleHorizontalSwipe,
          child: PullToClose(
            onClose: () => Navigator.maybePop(context),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0) {
                  _scrolledToCards.value = notification.metrics.pixels > 24;
                }
                return false;
              },
              child: CustomScrollView(
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(height: constraints.maxHeight, child: page),
                ),
                if (song != null)
                  SliverToBoxAdapter(
                    child: PlayerCards(
                      audioHandler: widget.audioHandler,
                      song: song,
                      palette: palette,
                      onLyrics: () => _tabController.animateTo(1),
                      onQueue: () => _tabController.animateTo(2),
                      onArtist: _openArtist,
                      onDetails: () => showTrackDetails(context, widget.audioHandler),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottomInset + AppSpacing.xxl)),
              ],
            ),
            ),
          ),
        );
      },
    );
  }

  /// Fullscreen Canvas for the current track. Reuses pooled decoders and
  /// hands the controller back when the sheet closes, so the video is
  /// already warm when the player reopens.
  Widget _buildFullscreenCanvas(bool isPlaying) {
    final url = _currentCanvasUrl!;
    final key = _canvasKey!;
    return CanvasPlayerWidget(
      key: ValueKey<String>(key),
      videoUrl: url,
      isPlaying: isPlaying && _tabController.index == 0,
      borderRadius: 0,
      onReady: () {
        if (!mounted || _canvasKey != key || _readyCanvasKey == key) return;
        setState(() => _readyCanvasKey = key);
      },
      // Reopening the player or re-enabling the canvas must be instant; a
      // stale track's video is never kept warm.
      keepWarmWhenDisposed: () => _currentCanvasUrl == url,
      onFailed: () {
        final song = widget.audioHandler.currentSong;
        if (song == null || !mounted) return;
        if (_canvasRetriedFor == song.id) {
          // The replacement failed as well: the normal cover comes back,
          // instead of the enlarged one that stands in for a video.
          PlaybackLogService.instance
              .log('CANVAS', 'nessun video riproducibile per "${song.title}", mostro la copertina');
          CanvasService.instance.giveUp(song.id);
          setState(() {
            _currentCanvasUrl = null;
            _isLoadingCanvas = false;
          });
          return;
        }
        _canvasRetriedFor = song.id;
        _canvasAttempt++;
        PlaybackLogService.instance
            .log('CANVAS', 'retry video "${song.title}"');
        // Ban the failed video for this session and hide it right away:
        // the retry resolves a different candidate while the cover bridges
        // the gap (no broken video re-mounted in between).
        CanvasService.instance.invalidate(song.id);
        setState(() {
          _currentCanvasUrl = null;
          _isLoadingCanvas = true;
        });
        _loadCanvas(song);
      },
    );
  }

  /// Closes the player and opens the page of the artist being played.
  void _openArtist() {
    final song = widget.audioHandler.currentSong;
    if (song == null || song.artist.trim().isEmpty) return;
    PlaybackLogService.instance.log('UI', 'player: apri artista "${song.artist}"');
    final navigator = Navigator.of(context);
    final rootContext = navigator.context;
    navigator.pop();
    ArtistScreen.open(rootContext, widget.audioHandler, song: song);
  }

  // ── Menus ────────────────────────────────────────────────────────────────

  void _showSources() {
    final song = widget.audioHandler.currentSong;
    if (song == null) return;
    AlternativeSourcesSheet.show(
      context,
      song: song,
      audioHandler: widget.audioHandler,
    );
  }

  /// The menu of the song being played, with the two things that belong to
  /// the player: speed and sleep timer.
  void _showMenu() {
    final song = widget.audioHandler.currentSong;
    if (song == null) return;
    final timer = widget.audioHandler.sleepTimerNotifier.value;
    showSongOptions(
      context,
      song: song,
      audioHandler: widget.audioHandler,
      notify: _showNotice,
      // The artist page opens in the tabs, under the player.
      beforeNavigation: () => Navigator.of(context).pop(),
      extras: [
        SongMenuExtra(
          icon: AppIcons.speed,
          label: 'Velocità di riproduzione',
          onTap: _showSpeedDialog,
        ),
        SongMenuExtra(
          icon: AppIcons.sleepTimer,
          label: 'Timer di spegnimento',
          subtitle: timer == null ? null : 'Attivo: $timer',
          onTap: _showSleepTimerDialog,
        ),
        SongMenuExtra(
          icon: AppIcons.info,
          label: 'Dettagli del brano',
          subtitle: 'Sorgente, formato, volume',
          onTap: () => showTrackDetails(context, widget.audioHandler),
        ),
      ],
    );
  }

  Future<void> _showSpeedDialog() async {
    final speed = await showChoiceSheet<double>(
      context,
      title: 'Velocità di riproduzione',
      options: [
        for (final speed in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          (speed, speed == 1.0 ? 'Normale' : '$speed×'),
      ],
      selected: widget.audioHandler.playbackState.value.speed,
    );
    if (speed == null) return;
    PlaybackLogService.instance.log('UI', 'player: velocità ${speed}x');
    widget.audioHandler.setSpeed(speed);
  }

  // What the sleep timer sheet can answer besides a number of minutes.
  static const int _timerEndOfTrack = -1;
  static const int _timerOff = 0;

  Future<void> _showSleepTimerDialog() async {
    final choice = await showChoiceSheet<int>(
      context,
      title: 'Timer di spegnimento',
      subtitle: 'La musica si ferma da sola',
      options: [
        for (final minutes in const [15, 30, 45, 60, 90]) (minutes, '$minutes minuti'),
        (_timerEndOfTrack, 'Alla fine del brano'),
        if (widget.audioHandler.isSleepTimerActive) (_timerOff, 'Disattiva il timer'),
      ],
    );
    if (choice == null) return;
    switch (choice) {
      case _timerOff:
        PlaybackLogService.instance.log('UI', 'player: sleep timer annullato');
        widget.audioHandler.cancelSleepTimer();
      case _timerEndOfTrack:
        PlaybackLogService.instance.log('UI', 'player: sleep timer fine brano');
        widget.audioHandler.setSleepTimer(null, endOfTrack: true);
        _showNotice('La musica si fermerà alla fine del brano');
      default:
        PlaybackLogService.instance.log('UI', 'player: sleep timer $choice min');
        widget.audioHandler.setSleepTimer(Duration(minutes: choice));
        _showNotice('La musica si fermerà tra $choice minuti');
    }
  }
}
