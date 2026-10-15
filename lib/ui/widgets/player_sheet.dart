import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
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
import '../../services/storage_service.dart';
import '../../services/ytmusic_service.dart';
import '../screens/artist_screen.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'alternative_sources_sheet.dart';
import 'app_cover.dart';
import 'app_sheet.dart';
import 'canvas_player_widget.dart';
import 'devices_sheet.dart';
import 'favorite_button.dart';
import 'lyrics_view.dart';
import 'play_button.dart';
import 'song_options_sheet.dart';
import 'song_tile.dart';

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
  // The player is always dark, whatever the cover: its text is white.
  static const Color _ink = Colors.white;
  static const Duration _canvasFade = Duration(milliseconds: 380);

  late TabController _tabController;
  late final AnimationController _enterController;
  late final Animation<double> _enterCurve;
  String? _lastLoadedSongId;

  StreamSubscription<String>? _errorSub;
  StreamSubscription<String>? _infoSub;
  int _lastTabIndex = 0;

  // Canvas state
  bool _showCanvas = true;
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
                      _BlurredCover(url: mediaItem.artUri.toString(), palette: palette)
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
                            duration: _canvasFade,
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
                            duration: _canvasFade,
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
                          _buildPlayerHeader(context, currentSong, mediaItem, palette),
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
                                _buildQueueTab(palette, bottomInset),
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
                        child: _buildCanvasToggle(context, palette),
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

  Widget _buildPlayerHeader(
    BuildContext context,
    Song? currentSong,
    MediaItem mediaItem,
    AmbientPalette palette,
  ) {
    final onMainTab = _tabController.index == 0;
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            tooltip: onMainTab ? 'Chiudi player' : 'Torna al player',
            icon: Icon(
              onMainTab ? AppIcons.collapse : AppIcons.back,
              color: _ink,
              size: onMainTab ? 32 : 20,
            ),
            onPressed: () {
              if (onMainTab) {
                Navigator.maybePop(context);
              } else {
                _tabController.animateTo(0);
              }
            },
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _tabController.index == 1
                      ? 'TESTO'
                      : _tabController.index == 2
                          ? 'CODA'
                          : 'IN RIPRODUZIONE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                    color: _ink.withValues(alpha: 0.72),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  onMainTab
                      ? ((currentSong?.album?.isNotEmpty ?? false)
                          ? currentSong!.album!
                          : (mediaItem.artist ?? 'Totorify'))
                      : mediaItem.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Altre opzioni',
            icon: const Icon(AppIcons.more, color: _ink, size: 26),
            onPressed: _showMenu,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
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
        final quiet = _ink.withValues(alpha: 0.72);

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: _handleHorizontalSwipe,
          child: Column(
            children: [
              Expanded(
                // The cover fades out as the Canvas fades in behind it.
                child: AnimatedSwitcher(
                  duration: _canvasFade,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    fit: StackFit.expand,
                    children: [...previousChildren, ?currentChild],
                  ),
                  child: hasCanvas
                    ? const SizedBox.expand(key: ValueKey('canvas_space'))
                    : Padding(
                        key: const ValueKey('cover_space'),
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.xl,
                          hasSwitch ? 46 : AppSpacing.sm,
                          AppSpacing.xl,
                          AppSpacing.sm,
                        ),
                        child: LayoutBuilder(
                          builder: (context, cover) {
                            final dimension =
                                math.min(cover.maxWidth, cover.maxHeight);
                            if (dimension < 120) return const SizedBox.shrink();
                            return Center(
                              child: AnimatedScale(
                                scale: isPlaying ? 1 : 0.93,
                                duration: const Duration(milliseconds: 320),
                                curve: Curves.easeOutCubic,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 300),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  child: DecoratedBox(
                                    key: ValueKey('player_cover_${mediaItem.id}'),
                                    decoration: BoxDecoration(
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.45),
                                          blurRadius: 36,
                                          offset: const Offset(0, 16),
                                        ),
                                      ],
                                    ),
                                    child: AppCover(
                                      url: mediaItem.artUri?.toString(),
                                      size: dimension,
                                      radius: AppRadius.md,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
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
                    // ── Title, artist, favourite ─────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 280),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            layoutBuilder: (currentChild, previousChildren) =>
                                Stack(
                              alignment: Alignment.centerLeft,
                              children: [
                                ...previousChildren,
                                ?currentChild,
                              ],
                            ),
                            child: Column(
                              key: ValueKey('player_title_${mediaItem.id}'),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  mediaItem.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.5,
                                    color: _ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    ValueListenableBuilder<List<Song>>(
                                      valueListenable:
                                          StorageService.instance.downloadsNotifier,
                                      builder: (context, _, _) => StorageService
                                              .instance
                                              .isDownloaded(mediaItem.id)
                                          ? Padding(
                                              padding:
                                                  const EdgeInsets.only(right: 6),
                                              child: Icon(AppIcons.downloaded,
                                                  size: 17, color: palette.accent),
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                    Flexible(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _openArtist,
                                        child: Text(
                                          mediaItem.artist ?? 'Artista',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 16, color: quiet),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        FavoriteButton(
                          song: () => widget.audioHandler.currentSong,
                          activeColor: palette.accent,
                          size: 28,
                          source: 'player',
                        ),
                      ],
                    ),
                    SizedBox(height: gap),
                    _SeekerBar(
                      audioHandler: widget.audioHandler,
                      mediaItem: mediaItem,
                    ),
                    SizedBox(height: isShortScreen ? 0 : 6),

                    // ── Transport ────────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: widget.audioHandler.smartShuffleNotifier,
                          builder: (context, smart, _) {
                            final shuffled = playback?.shuffleMode ==
                                    AudioServiceShuffleMode.all ||
                                playback?.shuffleMode == AudioServiceShuffleMode.group;
                            return _ToggleGlyph(
                              icon: AppIcons.shuffle,
                              active: shuffled || smart,
                              badge: smart ? AppIcons.smart : null,
                              color: palette.accent,
                              tooltip: smart
                                  ? 'Disattiva Smart Shuffle'
                                  : (shuffled ? 'Attiva Smart Shuffle' : 'Attiva casuale'),
                              onPressed: () {
                                // Cycle: off -> shuffle -> Smart Shuffle -> off.
                                if (smart) {
                                  PlaybackLogService.instance.log('UI', 'player: shuffle off');
                                  widget.audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
                                  _showNotice('Riproduzione casuale disattivata');
                                } else if (shuffled) {
                                  PlaybackLogService.instance.log('UI', 'player: smart shuffle on');
                                  widget.audioHandler.setSmartShuffle(true);
                                  _showNotice('Smart Shuffle: aggiunge brani consigliati alla coda');
                                } else {
                                  PlaybackLogService.instance.log('UI', 'player: shuffle on');
                                  widget.audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
                                }
                              },
                            );
                          },
                        ),
                        IconButton(
                          tooltip: 'Brano precedente',
                          iconSize: 44,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            PlaybackLogService.instance.log('UI', 'player: prev');
                            widget.audioHandler.skipToPrevious();
                          },
                          icon: const Icon(AppIcons.previous, color: _ink),
                        ),
                        PlayButton(
                          color: palette.accent,
                          size: 68,
                          playing: isPlaying,
                          loading: isLoading,
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            PlaybackLogService.instance
                                .log('UI', isPlaying ? 'player: pausa' : 'player: play');
                            isPlaying
                                ? widget.audioHandler.pause()
                                : widget.audioHandler.play();
                          },
                        ),
                        IconButton(
                          tooltip: 'Brano successivo',
                          iconSize: 44,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            PlaybackLogService.instance.log('UI', 'player: next');
                            widget.audioHandler.skipToNext();
                          },
                          icon: const Icon(AppIcons.next, color: _ink),
                        ),
                        Builder(
                          builder: (context) {
                            final mode =
                                playback?.repeatMode ?? AudioServiceRepeatMode.none;
                            return _ToggleGlyph(
                              icon: mode == AudioServiceRepeatMode.one
                                  ? AppIcons.repeatOne
                                  : AppIcons.repeat,
                              active: mode != AudioServiceRepeatMode.none,
                              color: palette.accent,
                              tooltip: 'Ripeti',
                              onPressed: () {
                                PlaybackLogService.instance
                                    .log('UI', 'player: repeat toggle');
                                final nextMode = mode == AudioServiceRepeatMode.none
                                    ? AudioServiceRepeatMode.all
                                    : (mode == AudioServiceRepeatMode.all
                                        ? AudioServiceRepeatMode.one
                                        : AudioServiceRepeatMode.none);
                                widget.audioHandler.setRepeatMode(nextMode);
                              },
                            );
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: isShortScreen ? 2 : 8),

                    // ── Sources, sleep timer, lyrics, queue ──────────────
                    Row(
                      children: [
                        // Where the music plays: here, or on another device
                        // (its name then takes the room there is).
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: DevicesButton(
                              remoteName: widget.audioHandler.remoteNameNotifier,
                              accent: palette.accent,
                              idle: quiet,
                            ),
                          ),
                        ),
                        ValueListenableBuilder<String?>(
                          valueListenable: widget.audioHandler.sleepTimerNotifier,
                          builder: (context, timerText, _) {
                            if (timerText == null) return const SizedBox.shrink();
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _showSleepTimerDialog,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(AppIcons.sleepTimer,
                                      size: 15, color: palette.accent),
                                  const SizedBox(width: 4),
                                  Text(
                                    timerText,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: palette.accent,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        IconButton(
                          tooltip: 'Fonti audio alternative',
                          onPressed: _showSources,
                          icon: Icon(AppIcons.sources, color: quiet, size: 23),
                        ),
                        IconButton(
                          tooltip: 'Testo',
                          onPressed: () => _tabController.animateTo(1),
                          icon: Icon(AppIcons.lyrics, color: quiet, size: 23),
                        ),
                        IconButton(
                          tooltip: 'Coda',
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerRight,
                          onPressed: () => _tabController.animateTo(2),
                          icon: Icon(AppIcons.queue, color: quiet, size: 25),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
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

  /// Pill that switches between the Canvas video and the cover.
  Widget _buildCanvasToggle(BuildContext context, AmbientPalette palette) {
    final enabled = _currentCanvasUrl != null;
    // Looking the Canvas up, or waiting for its first frame.
    final waiting = _isLoadingCanvas || (_showCanvas && enabled && !_canvasShown);
    final tint = _showCanvas && enabled ? palette.accent : _ink;
    return Semantics(
      button: true,
      label: _showCanvas
          ? 'Mostra copertina invece del Canvas'
          : 'Mostra Canvas invece della copertina',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled && !_isLoadingCanvas
            ? () {
                HapticFeedback.lightImpact();
                PlaybackLogService.instance.log(
                    'UI', _showCanvas ? 'player: canvas off' : 'player: canvas on');
                setState(() => _showCanvas = !_showCanvas);
              }
            : null,
        child: Padding(
          // Extra transparent padding widens the touch target beyond the pill.
          padding: const EdgeInsets.all(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.38),
              borderRadius: AppRadius.chip,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (waiting)
                  const Padding(
                    padding: EdgeInsets.only(right: 1),
                    child: CupertinoActivityIndicator(radius: 6, color: _ink),
                  )
                else
                  Icon(
                    _showCanvas ? AppIcons.canvas : AppIcons.cover,
                    size: 15,
                    color: tint,
                  ),
                const SizedBox(width: 5),
                Text(
                  _showCanvas || _isLoadingCanvas ? 'Canvas' : 'Copertina',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: tint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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

  Widget _buildQueueTab(AmbientPalette palette, double bottomInset) {
    final quiet = _ink.withValues(alpha: 0.72);
    // Rebuild whenever the real queue changes (reorder, dismiss, radio adds).
    return StreamBuilder<List<MediaItem>>(
      stream: widget.audioHandler.queue,
      builder: (context, _) {
        final playlist = widget.audioHandler.currentPlaylist;
        final currentSong = widget.audioHandler.currentSong;
        final suggestedIds = widget.audioHandler.suggestedIdsNotifier.value;
        final isPlaying = widget.audioHandler.playbackState.value.playing;

        if (playlist.isEmpty) {
          return Center(
            child: Text('La coda è vuota', style: TextStyle(color: quiet)),
          );
        }

        return ReorderableListView.builder(
          // Extra bottom padding keeps the last queue item clear of the home
          // indicator now that the root no longer applies the bottom safe area.
          padding: EdgeInsets.only(top: AppSpacing.sm, bottom: bottomInset + AppSpacing.xl),
          itemCount: playlist.length,
          // Rows are moved by their handle; a long press is not needed.
          buildDefaultDragHandles: false,
          header: _QueueActions(
            audioHandler: widget.audioHandler,
            ink: _ink,
            notify: _showNotice,
          ),
          // Recommended next tracks, reloaded when the song or queue changes.
          footer: _QueueSuggestions(
            key: ValueKey('suggest_${currentSong?.id}_${playlist.length}'),
            audioHandler: widget.audioHandler,
            accent: palette.accent,
          ),
          proxyDecorator: (child, index, animation) => Material(
            color: Color.lerp(palette.surface, Colors.white, 0.08),
            elevation: 8,
            shadowColor: Colors.black,
            child: child,
          ),
          onReorder: (oldIndex, newIndex) {
            PlaybackLogService.instance
                .log('UI', 'coda: riordino $oldIndex -> $newIndex');
            widget.audioHandler.reorderQueue(oldIndex, newIndex);
          },
          itemBuilder: (context, index) {
            final song = playlist[index];
            final isCurrent = song.id == currentSong?.id;

            return Dismissible(
              key: ValueKey('queue_${song.id}_$index'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: AppSpacing.xl),
                color: Theme.of(context).colorScheme.error,
                child: const Icon(AppIcons.trash, color: Colors.white),
              ),
              onDismissed: (_) {
                PlaybackLogService.instance
                    .log('UI', 'coda: rimuovo indice $index');
                widget.audioHandler.removeFromQueue(index);
              },
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () {
                    PlaybackLogService.instance
                        .log('UI', 'coda: tap "${song.title}"');
                    // By position: the queue stays as it is, and a song queued
                    // twice plays the copy that was tapped.
                    widget.audioHandler.skipToQueueItem(index);
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 7, AppSpacing.sm, 7),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            AppCover(url: song.thumbnailUrl, size: 46),
                            if (isCurrent)
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    borderRadius: AppRadius.cover,
                                  ),
                                  child: isPlaying
                                      ? PlayingBars(color: palette.accent, height: 16)
                                      : Icon(AppIcons.pause,
                                          color: palette.accent, size: 22),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: isCurrent ? palette.accent : _ink,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: quiet, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        // Added by Smart Shuffle, not by the user.
                        if (suggestedIds.contains(song.id))
                          Padding(
                            padding: const EdgeInsets.only(left: AppSpacing.sm),
                            child: Icon(AppIcons.smart,
                                color: palette.accent, size: 16),
                          ),
                        ReorderableDragStartListener(
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            child: Icon(AppIcons.dragHandle, color: quiet, size: 24),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
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

/// Above the queue: mix what is left, keep it as a playlist, empty it.
class _QueueActions extends StatelessWidget {
  const _QueueActions({required this.audioHandler, required this.ink, required this.notify});

  final AudioPlayerHandler audioHandler;
  final Color ink;
  final void Function(String message) notify;

  Future<void> _save(BuildContext context) async {
    final songs = audioHandler.currentPlaylist;
    if (songs.isEmpty) return;
    final name = await askPlaylistName(context);
    if (name == null) return;
    PlaybackLogService.instance.log('UI', 'coda: salvo come playlist "$name"');
    final storage = StorageService.instance;
    final playlist = await storage.createPlaylist(name);
    for (final song in songs) {
      await storage.addSongToPlaylist(playlist.id, song);
    }
    notify('Coda salvata in "$name"');
  }

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: ActionChip(
            avatar: Icon(icon, size: 16, color: ink),
            label: Text(label, style: TextStyle(color: ink, fontSize: 13)),
            backgroundColor: ink.withValues(alpha: 0.10),
            side: BorderSide.none,
            shape: const StadiumBorder(),
            onPressed: onTap,
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            action(AppIcons.shuffle, 'Mescola', () {
              audioHandler.shuffleUpcoming();
              notify('Coda mescolata');
            }),
            action(AppIcons.save, 'Salva', () => _save(context)),
            action(AppIcons.trash, 'Svuota', () {
              audioHandler.clearQueue();
              notify('Coda svuotata');
            }),
          ],
        ),
      ),
    );
  }
}

/// What is known of the track playing: where it comes from, its format,
/// how loud it is (what other players call "nerd stats").
Future<void> showTrackDetails(BuildContext context, AudioPlayerHandler handler) {
  final song = handler.currentSong;
  if (song == null) return Future.value();
  final videoId = handler.currentStreamId;
  final details = videoId == null ? null : YTMusicService.instance.streamDetails(videoId);
  String kb(int bytes) => bytes > 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';
  final gain = handler.normalizationGain;
  final rows = <(String, String)>[
    ('Sorgente', handler.sourceNotifier.value ?? 'sconosciuta'),
    if (videoId != null) ('Video di YouTube', videoId),
    if (details?.codec != null) ('Codec', details!.codec!),
    if (details?.bitrate != null) ('Bitrate', '${(details!.bitrate! / 1000).round()} kbps'),
    if (details?.sampleRate != null) ('Frequenza', '${details!.sampleRate} Hz'),
    if (details?.channels != null) ('Canali', details!.channels == 2 ? 'Stereo' : '${details.channels}'),
    if (details?.contentLength != null) ('Dimensione', kb(details!.contentLength!)),
    if (details?.loudnessDb != null)
      ('Volume misurato', '${details!.loudnessDb!.toStringAsFixed(1)} dB rispetto al riferimento'),
    ('Normalizzazione', gain >= 0.999 ? 'nessuna riduzione' : '−${(-20 * math.log(gain) / math.ln10).toStringAsFixed(1)} dB'),
    ('Velocità', '${handler.playbackState.value.speed}×'),
  ];
  return showAppSheet<void>(
    context,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle('Dettagli del brano', subtitle: '${song.title} — ${song.artist}'),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: Text(label, style: AppText.caption(cs)),
                  ),
                  Expanded(
                    child: SelectableText(value, style: AppText.tileTitle(cs).copyWith(fontSize: 14)),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// Shuffle and repeat: a glyph that lights up in the cover's color, with a
/// dot under it, while its mode is on.
class _ToggleGlyph extends StatelessWidget {
  const _ToggleGlyph({
    required this.icon,
    required this.active,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.badge,
  });

  final IconData icon;
  final bool active;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  /// Small glyph over the corner (Smart Shuffle).
  final IconData? badge;

  @override
  Widget build(BuildContext context) {
    final tint = active ? color : Colors.white;
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onPressed: () {
        HapticFeedback.selectionClick();
        onPressed();
      },
      icon: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 26, color: tint),
            if (badge != null)
              Positioned(
                right: 0,
                top: 2,
                child: Icon(badge, size: 13, color: tint),
              ),
            if (active)
              Positioned(
                bottom: 0,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Consigliati" list under the queue: tracks that fit after the current
/// song, each one tap away from the queue.
class _QueueSuggestions extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final Color accent;

  const _QueueSuggestions({
    super.key,
    required this.audioHandler,
    required this.accent,
  });

  @override
  State<_QueueSuggestions> createState() => _QueueSuggestionsState();
}

class _QueueSuggestionsState extends State<_QueueSuggestions> {
  late final Future<List<Song>> _suggestions =
      widget.audioHandler.suggestionsForCurrent();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Song>>(
      future: _suggestions,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Song>[];
        if (songs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.sm),
              child: Row(
                children: [
                  Icon(AppIcons.smart, size: 17, color: widget.accent),
                  const SizedBox(width: AppSpacing.sm),
                  const Text(
                    'Consigliati',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            for (final song in songs)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 7, AppSpacing.sm, 7),
                child: Row(
                  children: [
                    AppCover(url: song.thumbnailUrl, size: 46),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Aggiungi alla coda',
                      icon: const Icon(AppIcons.save, color: Colors.white, size: 25),
                      onPressed: () {
                        PlaybackLogService.instance
                            .log('UI', 'coda: aggiungo consigliato "${song.title}"');
                        widget.audioHandler.addToQueue(song);
                      },
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Progress bar of the player: follows the position, and while it is being
/// dragged shows where the finger is instead.
class _SeekerBar extends StatefulWidget {
  final AudioPlayerHandler audioHandler;
  final MediaItem mediaItem;

  const _SeekerBar({
    required this.audioHandler,
    required this.mediaItem,
  });

  @override
  State<_SeekerBar> createState() => _SeekerBarState();
}

class _SeekerBarState extends State<_SeekerBar> {
  bool _isDragging = false;
  double? _dragValue;

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // The parent rebuilds this bar with every media item it publishes.
    final published = widget.mediaItem.duration ?? Duration.zero;
    final totalDuration = published > Duration.zero
        ? published
        : (widget.audioHandler.currentSong?.duration ?? Duration.zero);
    final maxMs = totalDuration.inMilliseconds.toDouble();
    final limit = maxMs > 0 ? maxMs : 1.0;
    final timeStyle = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
      color: Colors.white.withValues(alpha: 0.72),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return ValueListenableBuilder<Duration>(
      valueListenable: widget.audioHandler.positionNotifier,
      builder: (context, position, _) {
        final curMs = position.inMilliseconds.toDouble().clamp(0.0, limit);
        final displayMs = (_isDragging && _dragValue != null)
            ? _dragValue!.clamp(0.0, limit)
            : curMs;

        final style = AppSettings.instance.seekBarStyle.value;
        final baseHeight = switch (style) {
          1 => 2.0,
          2 => 8.0,
          _ => 4.0,
        };
        final wavy = style == 3 && !_isDragging;
        final details = widget.audioHandler.currentStreamId == null
            ? null
            : YTMusicService.instance.streamDetails(widget.audioHandler.currentStreamId!);
        final format = [
          if (details?.codec != null)
            details!.codec!.startsWith('mp4a') ? 'AAC' : details.codec!.toUpperCase(),
          if (details?.bitrate != null) '${(details!.bitrate! / 1000).round()} kbps',
          if (details?.sampleRate != null) '${(details!.sampleRate! / 1000).toStringAsFixed(1)} kHz',
        ].join(' · ');
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: _isDragging ? baseHeight + 2 : baseHeight,
                trackShape: _SeekTrackShape(
                  wave: wavy ? position.inMilliseconds / 160 : null,
                ),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _isDragging ? 8 : (style == 1 ? 4.5 : 6),
                  elevation: 0,
                  pressedElevation: 0,
                ),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
                thumbColor: Colors.white,
              ),
              child: SizedBox(
                height: 24,
                child: Slider(
                  value: displayMs,
                  max: limit,
                  onChangeStart: (val) {
                    setState(() {
                      _isDragging = true;
                      _dragValue = val;
                    });
                  },
                  onChanged: (val) {
                    setState(() => _dragValue = val);
                  },
                  onChangeEnd: (val) {
                    // The handler moves its position at once, so the
                    // thumb stays where it was released.
                    widget.audioHandler.seek(Duration(milliseconds: val.toInt()));
                    setState(() {
                      _isDragging = false;
                      _dragValue = null;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(Duration(milliseconds: displayMs.toInt())), style: timeStyle),
                if (AppSettings.instance.showCodec.value && format.isNotEmpty)
                  Text(format, style: timeStyle.copyWith(fontSize: 10.5)),
                Text(_fmt(totalDuration), style: timeStyle),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Track of the seek bar: it spans the whole width of the slider, so the
/// bar lines up with the title above and the times below.
class _SeekTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _SeekTrackShape({this.wave});

  /// The phase of the wave the played part is drawn as; null for a line.
  final double? wave;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 4;
    final top = offset.dy + (parentBox.size.height - height) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.height <= 0) return;
    final radius = Radius.circular(trackRect.height / 2);

    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = sliderTheme.inactiveTrackColor ?? Colors.white24,
    );

    final activeRight = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final activeRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      activeRight,
      trackRect.bottom,
    );
    if (activeRect.isEmpty) return;
    final phase = wave;
    if (phase == null) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        Paint()..color = sliderTheme.activeTrackColor ?? Colors.white,
      );
      return;
    }
    // The part already played as a wave that moves with the song.
    final middle = trackRect.center.dy;
    final path = Path()..moveTo(trackRect.left, middle);
    for (var x = trackRect.left; x <= activeRight; x += 1.5) {
      path.lineTo(x, middle + 3.2 * math.sin((x - trackRect.left) / 18 * 2 * math.pi - phase));
    }
    context.canvas.drawPath(
      path,
      Paint()
        ..color = sliderTheme.activeTrackColor ?? Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = trackRect.height * 0.8
        ..strokeCap = StrokeCap.round,
    );
  }
}

/// The cover of the song, blurred and darkened, behind the whole player.
class _BlurredCover extends StatelessWidget {
  const _BlurredCover({required this.url, required this.palette});

  final String url;
  final AmbientPalette palette;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: palette.deep),
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 38, sigmaY: 38),
          child: Image(image: imageProviderFor(url), fit: BoxFit.cover),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.35),
                Colors.black.withValues(alpha: 0.5),
                Colors.black.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
