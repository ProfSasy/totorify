import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import '../../models/lyrics_model.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/playback_log_service.dart';
import '../../services/canvas_service.dart';
import '../../services/download_service.dart';
import '../../services/lyrics_service.dart';
import '../../services/storage_service.dart';
import '../screens/artist_screen.dart';
import '../theme/app_ambience.dart';

import '../theme/app_tokens.dart';
import 'canvas_player_widget.dart';
import 'alternative_sources_sheet.dart';

/// Full-screen now-playing sheet with three tabs: player, lyrics, queue.
/// The background is an ambient canvas: artwork colors breathe behind the
/// content (and on top of the Canvas video) and cross-fade on track change.
class PlayerSheet extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const PlayerSheet({super.key, required this.audioHandler});

  /// True while the sheet is on screen. It covers the whole screen, snack
  /// bars included, so it shows playback messages itself.
  static bool isOpen = false;

  static void show(BuildContext context, AudioPlayerHandler audioHandler) {
    PlaybackLogService.instance.log('UI', 'player: apri');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor:
          Theme.of(context).colorScheme.surface.withValues(alpha: 0),
      barrierColor: Colors.black.withValues(alpha: 0.72),
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
  Lyrics _lyrics = Lyrics.empty;
  bool _isLoadingLyrics = false;
  String? _lastLoadedSongId;
  String? _lastLoadedLyricsSongId;

  final ScrollController _lyricsScrollController = ScrollController();
  final ValueNotifier<int> _activeLyricIndexNotifier = ValueNotifier<int>(-1);
  StreamSubscription<String>? _errorSub;
  int _lastTabIndex = 0;

  // Lyric auto-follow: while the user scrolls, follow is paused and it
  // resumes a few seconds after the last manual scroll.
  static const double _lyricLineExtent = 72;
  bool _userBrowsingLyrics = false;
  Timer? _lyricsFollowTimer;

  // Canvas state
  bool _showCanvas = true;
  String? _currentCanvasUrl;
  bool _isLoadingCanvas = false;
  int _canvasLoadGeneration = 0;
  // One automatic retry per song when the video fails to initialize.
  String? _canvasRetriedFor;
  int _canvasAttempt = 0;

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
      if (_tabController.index == 1) {
        // Re-entering the lyrics tab always resumes following.
        _lyricsFollowTimer?.cancel();
        _userBrowsingLyrics = false;
        if (_activeLyricIndexNotifier.value >= 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToActiveLyric(
              _activeLyricIndexNotifier.value,
              force: true,
            );
          });
        }
      } else {
        _lyricsFollowTimer?.cancel();
        _userBrowsingLyrics = false;
      }
    });

    // Extract dominant color from current artwork & load canvas & lyrics
    final current = widget.audioHandler.currentSong;
    if (current != null) {
      _loadCanvas(current);
      _loadLyrics(current);
    }
    CanvasService.instance.isCanvasEnabledNotifier.addListener(_onCanvasSettingChanged);
    StorageService.instance.accentColorNotifier.addListener(_onAccentColorChanged);

    // Sync karaoke lyrics on position tick
    widget.audioHandler.positionNotifier.addListener(_syncLyricsToPosition);

    _errorSub = widget.audioHandler.errorStream.listen(_showNotice);
  }

  void _showNotice(String message) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _syncLyricsToPosition() {
    if (!mounted || !_lyrics.isSynced || _lyrics.syncedLyrics.isEmpty) return;
    final pos = widget.audioHandler.position;
    final idx = _lyrics.syncedLyrics.lastIndexWhere((line) => line.time <= pos);
    if (idx != _activeLyricIndexNotifier.value && idx != -1) {
      _activeLyricIndexNotifier.value = idx;
      _scrollToActiveLyric(idx);
    }
  }

  @override
  void dispose() {
    CanvasService.instance.isCanvasEnabledNotifier.removeListener(_onCanvasSettingChanged);
    StorageService.instance.accentColorNotifier.removeListener(_onAccentColorChanged);
    widget.audioHandler.positionNotifier.removeListener(_syncLyricsToPosition);
    _errorSub?.cancel();
    _noticeTimer?.cancel();
    PlayerSheet.isOpen = false;
    PlaybackLogService.instance.log('UI', 'player: chiudi');
    _lyricsFollowTimer?.cancel();
    _enterController.dispose();
    _tabController.dispose();
    _lyricsScrollController.dispose();
    _activeLyricIndexNotifier.dispose();
    super.dispose();
  }

  void _onCanvasSettingChanged() {
    if (mounted) {
      _loadCanvas(widget.audioHandler.currentSong);
    }
  }

  void _onAccentColorChanged() {
    if (mounted) setState(() {});
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -200) {
      HapticFeedback.mediumImpact();
      widget.audioHandler.skipToNext();
    } else if (velocity > 200) {
      HapticFeedback.mediumImpact();
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

  void _scrollToActiveLyric(int idx, {bool force = false}) {
    if (!_lyricsScrollController.hasClients) return;
    if (_tabController.index != 1) return; // Only scroll when on lyrics tab
    if (_userBrowsingLyrics && !force) return;
    final position = _lyricsScrollController.position;
    if (!position.hasViewportDimension) return;
    // The ListView top padding is (viewport - line)/2, so scrolling to
    // idx * line places the active line exactly at the viewport center.
    final targetOffset = idx * _lyricLineExtent;
    _lyricsScrollController.animateTo(
      targetOffset.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _onLyricsScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is UserScrollNotification) {
      final isUserScroll = notification is UserScrollNotification
          ? notification.direction != ScrollDirection.idle
          : (notification as ScrollStartNotification).dragDetails != null;
      // ScrollDirection is exported by the widgets library through Material.
      if (isUserScroll) {
        _userBrowsingLyrics = true;
        _lyricsFollowTimer?.cancel();
      }
    } else if (notification is ScrollEndNotification &&
        _userBrowsingLyrics) {
      _lyricsFollowTimer?.cancel();
      _lyricsFollowTimer = Timer(const Duration(seconds: 4), () {
        _userBrowsingLyrics = false;
        final active = _activeLyricIndexNotifier.value;
        if (mounted && active >= 0) {
          _scrollToActiveLyric(active, force: true);
        }
      });
    }
  }

  Future<void> _loadLyrics(Song song, {bool refresh = false}) async {
    if (_lastLoadedLyricsSongId == song.id && (_lyrics.isNotEmpty || _isLoadingLyrics)) return;
    _lastLoadedLyricsSongId = song.id;
    _lyricsFollowTimer?.cancel();
    _userBrowsingLyrics = false;
    if (mounted) {
      setState(() {
        _isLoadingLyrics = true;
        _lyrics = Lyrics.empty;
      });
    }
    _activeLyricIndexNotifier.value = -1;
    final lyrics = await LyricsService.instance.getLyrics(song, refresh: refresh);
    if (mounted && _lastLoadedLyricsSongId == song.id) {
      setState(() {
        _lyrics = lyrics;
        _isLoadingLyrics = false;
      });
      if (_tabController.index == 1 && _lyrics.isSynced) {
        final currentPos = widget.audioHandler.position;
        final idx = _lyrics.syncedLyrics.lastIndexWhere((l) => l.time <= currentPos);
        if (idx != -1) {
          _activeLyricIndexNotifier.value = idx;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToActiveLyric(idx, force: true);
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: widget.audioHandler.mediaItem,
      builder: (context, mediaSnapshot) {
        final mediaItem = mediaSnapshot.data;
        if (mediaItem == null) {
          // The sheet can be opened a moment before the first media item is
          // published: show a loading state instead of an invisible modal.
          return Container(
            height: MediaQuery.sizeOf(context).height,
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: CupertinoActivityIndicator(
                radius: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _loadLyrics(currentSong);
          });
        }

        final colorScheme = Theme.of(context).colorScheme;
        // The modal sheet strips padding AND viewPadding from the ambient
        // MediaQuery, so the FlutterView is the only reliable source for the
        // status bar / Dynamic Island inset.
        final flutterView = View.of(context);
        final topInset =
            flutterView.viewPadding.top / flutterView.devicePixelRatio;
        return Container(
          height: MediaQuery.sizeOf(context).height,
          color: colorScheme.surfaceDim,
          child: StreamBuilder<PlaybackState>(
            stream: widget.audioHandler.playbackState,
            builder: (context, playbackSnapshot) {
              final isPlaying = playbackSnapshot.data?.playing ?? false;
              final canvasAvailable =
                  _showCanvas && _currentCanvasUrl != null;
              final canvasVisible = canvasAvailable && _tabController.index == 0;

              return Stack(
                fit: StackFit.expand,
                children: [
                  if (canvasAvailable)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _buildFullscreenCanvas(
                          currentSong,
                          isPlaying,
                          mediaItem,
                        ),
                      ),
                    ),
                  // Veil: softens the paused Canvas when the user is on the
                  // lyrics/queue tabs, still letting its motion glow through.
                  if (canvasAvailable && !canvasVisible)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: colorScheme.surface.withValues(alpha: 0.9),
                        ),
                      ),
                    ),

                  // Ambient backdrop: the artwork's colors breathe behind the
                  // whole player and cross-fade on every track change. Turns
                  // up when the Canvas is hidden, stays subtle over the video.
                  Positioned.fill(
                    child: AmbientBackdrop(
                      artworkUrl: mediaItem.artUri?.toString(),
                      intensity: canvasVisible ? 0.4 : 1.0,
                    ),
                  ),

                  // Scrim above the ambience keeps the header readable over
                  // the Canvas video.
                  if (canvasVisible)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colorScheme.surface.withValues(alpha: 0.42),
                                colorScheme.surface.withValues(alpha: 0.28),
                                colorScheme.surface.withValues(alpha: 0.97),
                              ],
                              stops: const [0.0, 0.42, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: Column(
                      children: [
                        _buildPlayerHeader(context, currentSong, mediaItem),
                        Expanded(
                          child: TabBarView(
                            controller: _tabController,
                            physics: const NeverScrollableScrollPhysics(),
                            children: [
                              _buildMainPlayerTab(mediaItem, playbackSnapshot.data),
                              _buildLyricsTab(),
                              _buildQueueTab(),
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
                      top: topInset + 62,
                      right: 20,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOut,
                        builder: (context, value, child) =>
                            Opacity(opacity: value, child: child),
                        child: _buildCanvasToggle(context),
                      ),
                    ),
                  if (_notice != null)
                    Positioned(
                      left: 20,
                      right: 20,
                      // Below the header and the Canvas toggle.
                      top: topInset + 112,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            border: Border.all(
                              color: colorScheme.onSurface.withValues(alpha: 0.12),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            child: Text(
                              _notice!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
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
        );
      },
    );
  }

  Widget _buildPlayerHeader(
    BuildContext context,
    Song? currentSong,
    MediaItem mediaItem,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 58,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Truly screen-centered title, independent from the side buttons.
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 64),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _tabController.index == 1
                          ? 'TESTO'
                          : _tabController.index == 2
                              ? 'CODA DI RIPRODUZIONE'
                              : 'IN RIPRODUZIONE DA',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _tabController.index == 0
                          ? ((currentSong?.album?.isNotEmpty ?? false)
                              ? currentSong!.album!
                              : 'Totorify')
                          : mediaItem.title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  tooltip: _tabController.index == 0 ? 'Chiudi player' : 'Torna al player',
                  icon: Icon(
                    _tabController.index == 0
                        ? CupertinoIcons.chevron_down
                        : CupertinoIcons.chevron_left,
                    color: colorScheme.onSurface,
                    size: 22,
                  ),
                  onPressed: () {
                    if (_tabController.index != 0) {
                      _tabController.animateTo(0);
                    } else {
                      Navigator.maybePop(context);
                    }
                  },
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<String?>(
                    valueListenable: widget.audioHandler.sleepTimerNotifier,
                    builder: (context, timerText, _) {
                      if (timerText == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.primary,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 36),
                          ),
                          onPressed: () => _showSleepTimerDialog(context),
                          icon: const Icon(CupertinoIcons.moon_fill, size: 13),
                          label: Text(timerText, style: const TextStyle(fontSize: 11)),
                        ),
                      );
                    },
                  ),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      tooltip: 'Altre opzioni',
                      icon: Icon(
                        CupertinoIcons.ellipsis,
                        color: colorScheme.onSurfaceVariant,
                        size: 22,
                      ),
                      onPressed: () => _showPlaybackSettings(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Animates the whole player block when the sheet opens.
  Widget _buildMainPlayerTab(
    MediaItem mediaItem,
    PlaybackState? playback,
  ) {
    return FadeTransition(
      opacity: _enterCurve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.05),
          end: Offset.zero,
        ).animate(_enterCurve),
        child: _buildMainPlayerTabContent(mediaItem, playback),
      ),
    );
  }

  Widget _buildMainPlayerTabContent(
    MediaItem mediaItem,
    PlaybackState? playback,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colorScheme = Theme.of(context).colorScheme;
        final availableHeight = constraints.maxHeight;
        final isShortScreen = availableHeight < 620;
        final hasCanvas = _showCanvas && _currentCanvasUrl != null;
        final isPlaying = playback?.playing ?? false;
        final isLoading =
            playback?.processingState == AudioProcessingState.loading ||
                playback?.processingState == AudioProcessingState.buffering;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: _handleHorizontalSwipe,
          child: Column(
            children: [
              Expanded(
                child: hasCanvas
                    ? const SizedBox.expand()
                    : LayoutBuilder(
                        builder: (context, coverConstraints) {
                          final maxWidth = MediaQuery.sizeOf(context).width - 56;
                          final dimension = coverConstraints.maxHeight < maxWidth
                              ? coverConstraints.maxHeight
                              : maxWidth;
                          if (dimension < 120) return const SizedBox.shrink();
                          // Cover stays vertically centered in its available
                          // space; only the controls block is anchored lower.
                          return Center(
                            child: AnimatedScale(
                              scale: isPlaying ? 1 : 0.96,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              child: SizedBox.square(
                                dimension: dimension,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 300),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  layoutBuilder:
                                      (currentChild, previousChildren) =>
                                          Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ...previousChildren,
                                      ?currentChild,
                                    ],
                                  ),
                                  child: KeyedSubtree(
                                    key: ValueKey(
                                        'player_cover_${mediaItem.id}'),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(20),
                                        boxShadow: [
                                          BoxShadow(
                                            color: colorScheme.primary
                                                .withValues(alpha: 0.28),
                                            blurRadius: 46,
                                            offset: const Offset(0, 22),
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(20),
                                        child: CachedNetworkImage(
                                          imageUrl:
                                              mediaItem.artUri?.toString() ??
                                                  '',
                                          fit: BoxFit.cover,
                                          fadeInDuration: const Duration(
                                              milliseconds: 180),
                                          placeholder: (_, _) => ColoredBox(
                                            color: colorScheme.surface,
                                            child: Icon(
                                              CupertinoIcons.music_note,
                                              color: colorScheme
                                                  .onSurfaceVariant,
                                              size: 64,
                                            ),
                                          ),
                                          errorWidget: (_, _, _) => ColoredBox(
                                            color: colorScheme.surface,
                                            child: Icon(
                                              CupertinoIcons.music_note,
                                              color: colorScheme
                                                  .onSurfaceVariant,
                                              size: 64,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  isShortScreen ? 4 : 8,
                  24,
                  // Small explicit inset instead of the full safe-area
                  // padding: keeps taps clear of the home indicator while
                  // letting the controls drop closer to the bottom edge.
                  isShortScreen ? 12 : 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                layoutBuilder:
                                    (currentChild, previousChildren) => Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    ...previousChildren,
                                    ?currentChild,
                                  ],
                                ),
                                transitionBuilder: (child, animation) =>
                                    FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(0, 0.25),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                                child: Text(
                                  mediaItem.title,
                                  key: ValueKey('player_title_${mediaItem.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: -0.4,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  ValueListenableBuilder(
                                    valueListenable: StorageService
                                        .instance.downloadsNotifier,
                                    builder: (context, _, _) =>
                                        StorageService.instance
                                                .isDownloaded(mediaItem.id)
                                            ? Padding(
                                                padding: const EdgeInsets.only(
                                                    right: 6),
                                                child: Icon(
                                                  CupertinoIcons
                                                      .arrow_down_circle_fill,
                                                  size: 15,
                                                  color: colorScheme.primary,
                                                ),
                                              )
                                            : const SizedBox.shrink(),
                                  ),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 280),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      layoutBuilder: (currentChild,
                                              previousChildren) =>
                                          Stack(
                                        alignment: Alignment.centerLeft,
                                        children: [
                                          ...previousChildren,
                                          ?currentChild,
                                        ],
                                      ),
                                      transitionBuilder: (child, animation) =>
                                          FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                      child: GestureDetector(
                                        key: ValueKey(
                                            'player_artist_${mediaItem.id}'),
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _openArtist,
                                        child: Text(
                                          mediaItem.artist ?? 'Artista',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 15,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        ValueListenableBuilder(
                          valueListenable:
                              StorageService.instance.favoritesNotifier,
                          builder: (context, _, _) {
                            final isFavorite = StorageService.instance
                                .isFavorite(mediaItem.id);
                            return IconButton(
                              tooltip: isFavorite
                                  ? 'Rimuovi dai preferiti'
                                  : 'Aggiungi ai preferiti',
                              onPressed: () {
                                PlaybackLogService.instance
                                    .log('UI', 'player: preferito');
                                final song = widget.audioHandler.currentSong;
                                if (song != null) {
                                  StorageService.instance.toggleFavorite(song);
                                }
                              },
                              icon: Icon(
                                isFavorite
                                    ? CupertinoIcons.heart_fill
                                    : CupertinoIcons.heart,
                                color: isFavorite
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                                size: 27,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: isShortScreen ? 4 : 10),
                    _SeekerBar(
                      audioHandler: widget.audioHandler,
                      mediaItem: mediaItem,
                    ),
                    SizedBox(height: isShortScreen ? 4 : 10),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: widget.audioHandler.smartShuffleNotifier,
                            builder: (context, smart, _) {
                              final shuffled = playback?.shuffleMode == AudioServiceShuffleMode.all || playback?.shuffleMode == AudioServiceShuffleMode.group;
                              final active = shuffled || smart;
                              return IconButton(
                                tooltip: smart
                                    ? 'Disattiva Smart Shuffle'
                                    : (shuffled ? 'Attiva Smart Shuffle' : 'Attiva casuale'),
                                onPressed: () {
                                  // Cycle: off -> shuffle -> Smart Shuffle -> off.
                                  if (smart) {
                                    PlaybackLogService.instance.log('UI', 'player: shuffle off');
                                    widget.audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
                                  } else if (shuffled) {
                                    PlaybackLogService.instance.log('UI', 'player: smart shuffle on');
                                    widget.audioHandler.setSmartShuffle(true);
                                  } else {
                                    PlaybackLogService.instance.log('UI', 'player: shuffle on');
                                    widget.audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
                                  }
                                },
                                icon: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Icon(CupertinoIcons.shuffle, size: 22, color: active ? colorScheme.primary : colorScheme.onSurface),
                                        if (smart)
                                          Positioned(
                                            right: -9,
                                            top: -7,
                                            child: Icon(CupertinoIcons.sparkles, size: 13, color: colorScheme.primary),
                                          ),
                                      ],
                                    ),
                                    if (active) const SizedBox(height: 3),
                                    if (active) Container(width: 4, height: 4, decoration: BoxDecoration(color: colorScheme.primary, shape: BoxShape.circle)),
                                  ],
                                ),
                              );
                            },
                          ),
                          IconButton(
                            tooltip: 'Brano precedente',
                            iconSize: 34,
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              PlaybackLogService.instance.log('UI', 'player: prev');
                              widget.audioHandler.skipToPrevious();
                            },
                            icon: Icon(CupertinoIcons.backward_end_fill, color: colorScheme.onSurface),
                          ),
                          Semantics(
                            button: true,
                            label: isPlaying ? 'Pausa' : 'Riproduci',
                            child: SizedBox(
                              width: 66,
                              height: 66,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  shape: const CircleBorder(),
                                  padding: EdgeInsets.zero,
                                  backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black,
                                  foregroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
                                ),
                                onPressed: () {
                                  PlaybackLogService.instance.log('UI', isPlaying ? 'player: pausa' : 'player: play');
                                  isPlaying ? widget.audioHandler.pause() : widget.audioHandler.play();
                                },
                                child: isLoading
                                    ? CupertinoActivityIndicator(color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white)
                                    : Icon(
                                        isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                                        size: 32,
                                      ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Brano successivo',
                            iconSize: 34,
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              PlaybackLogService.instance.log('UI', 'player: next');
                              widget.audioHandler.skipToNext();
                            },
                            icon: Icon(CupertinoIcons.forward_end_fill, color: colorScheme.onSurface),
                          ),
                          Builder(
                            builder: (context) {
                              final mode = playback?.repeatMode ?? AudioServiceRepeatMode.none;
                              final isActive = mode != AudioServiceRepeatMode.none;
                              return IconButton(
                                tooltip: 'Ripeti',
                                onPressed: () {
                                  PlaybackLogService.instance.log('UI', 'player: repeat toggle');
                                  final nextMode = mode == AudioServiceRepeatMode.none
                                      ? AudioServiceRepeatMode.all
                                      : (mode == AudioServiceRepeatMode.all
                                          ? AudioServiceRepeatMode.one
                                          : AudioServiceRepeatMode.none);
                                  widget.audioHandler.setRepeatMode(nextMode);
                                },
                                icon: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      mode == AudioServiceRepeatMode.one ? CupertinoIcons.repeat_1 : CupertinoIcons.repeat,
                                      size: 22,
                                      color: isActive ? colorScheme.primary : colorScheme.onSurface,
                                    ),
                                    if (isActive) const SizedBox(height: 3),
                                    if (isActive) Container(width: 4, height: 4, decoration: BoxDecoration(color: colorScheme.primary, shape: BoxShape.circle)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ]
                      ),
                    SizedBox(height: isShortScreen ? 4 : 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () => _showPlaybackSettings(context),
                            icon: Icon(CupertinoIcons.slider_horizontal_3,
                                size: 16, color: colorScheme.primary),
                            label: Text(
                              'Velocità e timer',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: colorScheme.primary, fontSize: 12),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Fonti audio',
                          onPressed: () {
                            final song = widget.audioHandler.currentSong;
                            if (song != null) {
                              AlternativeSourcesSheet.show(
                                context,
                                song: song,
                                audioHandler: widget.audioHandler,
                              );
                            }
                          },
                          icon: Icon(CupertinoIcons.tuningfork,
                              color: colorScheme.onSurfaceVariant),
                        ),
                        IconButton(
                          tooltip: 'Testo',
                          onPressed: () => _tabController.animateTo(1),
                          icon: Icon(CupertinoIcons.text_quote,
                              color: colorScheme.onSurfaceVariant),
                        ),
                        IconButton(
                          tooltip: 'Coda',
                          onPressed: () => _tabController.animateTo(2),
                          icon: Icon(CupertinoIcons.list_bullet,
                              color: colorScheme.onSurfaceVariant),
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
  Widget _buildFullscreenCanvas(
    Song? currentSong,
    bool isPlaying,
    MediaItem mediaItem,
  ) {
    final url = _currentCanvasUrl!;
    return CanvasPlayerWidget(
      key: ValueKey<String>(
        'fullscreen_canvas_${currentSong?.id}_${url}_$_canvasAttempt',
      ),
      videoUrl: url,
      isPlaying: isPlaying && _tabController.index == 0,
      borderRadius: 0,
      placeholder: CachedNetworkImage(
        imageUrl: mediaItem.artUri?.toString() ?? '',
        fit: BoxFit.cover,
      ),
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

  Widget _buildCanvasToggle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = _currentCanvasUrl != null;
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
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _showCanvas
                  ? colorScheme.primary.withValues(alpha: 0.18)
                  : colorScheme.surface.withValues(alpha: 0.78),
              borderRadius: AppRadius.chip,
              border: Border.all(
                color: _showCanvas
                    ? colorScheme.primary.withValues(alpha: 0.55)
                    : colorScheme.onSurface.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoadingCanvas)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: CupertinoActivityIndicator(
                      radius: 6,
                      color: colorScheme.primary,
                    ),
                  )
                else
                  Icon(
                    _showCanvas
                        ? CupertinoIcons.play_circle_fill
                        : CupertinoIcons.photo,
                    size: 14,
                    color: _showCanvas
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 5),
                Text(
                  _isLoadingCanvas
                      ? 'CANVAS...'
                      : (_showCanvas ? 'CANVAS' : 'COVER'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.7,
                    color: _showCanvas
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLyricsTab() {
    if (_isLoadingLyrics) {
      return Center(
        child: CupertinoActivityIndicator(color: Theme.of(context).colorScheme.onSurface, radius: 14),
      );
    }

    if (!_lyrics.isSynced && _lyrics.plainLyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.music_note_2,
                size: 48, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
            const SizedBox(height: 12),
            Text(
              'Testo non disponibile.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5), fontSize: 16),
            ),
            const SizedBox(height: 16),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(20),
              child: Text('Riprova', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
              onPressed: () {
                final current = widget.audioHandler.currentSong;
                if (current != null) {
                  _lastLoadedLyricsSongId = null;
                  _loadLyrics(current, refresh: true);
                }
              },
            ),
          ],
        ),
      );
    }

    if (!_lyrics.isSynced) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Text(
          _lyrics.plainLyrics,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 18,
            height: 1.8,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    // Synced karaoke lyrics — active line vertically centered, with free
    // manual scrolling that temporarily pauses auto-follow.
    return ValueListenableBuilder<int>(
      valueListenable: _activeLyricIndexNotifier,
      builder: (context, activeIdx, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.maxHeight;
            final halfLine = _lyricLineExtent / 2;
            final verticalPadding =
                (viewport / 2 - halfLine).clamp(0.0, viewport);
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                _onLyricsScrollNotification(notification);
                return false;
              },
              // Two lyric lines at the active size must always fit their row.
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.05,
                child: ListView.builder(
                controller: _lyricsScrollController,
                padding: EdgeInsets.fromLTRB(28, verticalPadding, 28, verticalPadding),
                physics: const BouncingScrollPhysics(),
                itemExtent: _lyricLineExtent,
                itemCount: _lyrics.syncedLyrics.length,
                itemBuilder: (context, index) {
                  final line = _lyrics.syncedLyrics[index];
                  final isActive = index == activeIdx;

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      PlaybackLogService.instance.log(
                          'UI', 'testi: tap riga ${line.time.inSeconds}s');
                      _lyricsFollowTimer?.cancel();
                      _userBrowsingLyrics = false;
                      widget.audioHandler.seek(line.time);
                      _scrollToActiveLyric(index, force: true);
                    },
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isActive ? 26 : 18,
                          fontWeight:
                              isActive ? FontWeight.w800 : FontWeight.w600,
                          color: isActive
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.32),
                          height: 1.3,
                          letterSpacing: -0.3,
                        ),
                        child: Text(
                          line.text,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  );
                },
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Closes the player and opens the page of the artist being played.
  void _openArtist() {
    final song = widget.audioHandler.currentSong;
    if (song == null || song.artist.trim().isEmpty) return;
    PlaybackLogService.instance.log('UI', 'player: apri artista "${song.artist}"');
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      CupertinoPageRoute<void>(
        builder: (_) => ArtistScreen(
          audioHandler: widget.audioHandler,
          song: song,
        ),
      ),
    );
  }

  Widget _buildQueueTab() {
    // Rebuild whenever the real queue changes (reorder, dismiss, radio adds).
    return StreamBuilder<List<MediaItem>>(
      stream: widget.audioHandler.queue,
      builder: (context, _) {
        final playlist = widget.audioHandler.currentPlaylist;
        final currentSong = widget.audioHandler.currentSong;
        final suggestedIds = widget.audioHandler.suggestedIdsNotifier.value;

        if (playlist.isEmpty) {
          return Center(
            child: Text('Coda vuota',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          );
        }

        return ReorderableListView.builder(
          // Extra bottom padding keeps the last queue item clear of the home
          // indicator now that the root no longer applies the bottom safe area.
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          itemCount: playlist.length,
          // Recommended next tracks, reloaded when the song or queue changes.
          footer: _QueueSuggestions(
            key: ValueKey('suggest_${currentSong?.id}_${playlist.length}'),
            audioHandler: widget.audioHandler,
          ),
          proxyDecorator: (child, index, animation) {
            return AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                return Material(
                  elevation: 8,
                  color:
                      Theme.of(context).colorScheme.surface.withValues(alpha: 0),
                  child: child,
                );
              },
              child: child,
            );
          },
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
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(CupertinoIcons.trash,
                    color: Theme.of(context).colorScheme.onPrimary),
              ),
              onDismissed: (_) {
                PlaybackLogService.instance
                    .log('UI', 'coda: rimuovo indice $index');
                widget.audioHandler.removeFromQueue(index);
              },
              child: ListTile(
                key: ValueKey('tile_${song.id}_$index'),
                leading: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: song.thumbnailUrl,
                        width: 46,
                        height: 46,
                        fit: BoxFit.cover,
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          CupertinoIcons.waveform,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                      ),
                  ],
                ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                    color: isCurrent
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Added by Smart Shuffle, not by the user.
                    if (suggestedIds.contains(song.id)) ...[
                      Icon(CupertinoIcons.sparkles,
                          color: Theme.of(context).colorScheme.primary,
                          size: 16),
                      const SizedBox(width: 10),
                    ],
                    Icon(CupertinoIcons.bars,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 20),
                  ],
                ),
                onTap: () {
                  PlaybackLogService.instance
                      .log('UI', 'coda: tap "${song.title}"');
                  // By position: the queue stays as it is, and a song queued
                  // twice plays the copy that was tapped.
                  widget.audioHandler.skipToQueueItem(index);
                },
              ),
            );
          },
        );
      },
    );
  }

  void _showPlaybackSettings(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Opzioni di riproduzione'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _showSpeedDialog(context);
            },
            child: Text('Velocità di Riproduzione'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _showSleepTimerDialog(context);
            },
            child: Text('Timer Spegnimento (Sleep Timer)'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              final song = widget.audioHandler.currentSong;
              if (song != null) {
                PlaybackLogService.instance
                    .log('UI', 'player: scarica "${song.title}"');
                DownloadService.instance.downloadSong(song);
              }
            },
            child: Text('Scarica brano in locale'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              final song = widget.audioHandler.currentSong;
              if (song != null) {
                AlternativeSourcesSheet.show(
                  context,
                  song: song,
                  audioHandler: widget.audioHandler,
                );
              }
            },
            child: Text('Fonti audio alternative'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Chiudi'),
        ),
      ),
    );
  }

  void _showSpeedDialog(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Seleziona Velocità'),
        actions: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((speed) {
          return CupertinoActionSheetAction(
            onPressed: () {
              PlaybackLogService.instance.log('UI', 'player: velocità ${speed}x');
              widget.audioHandler.setSpeed(speed);
              Navigator.pop(ctx);
            },
            child: Text(
              '${speed}x',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          );
        }).toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Annulla'),
        ),
      ),
    );
  }

  void _showSleepTimerDialog(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Timer di Spegnimento'),
        message: Text('La riproduzione si fermerà automaticamente'),
        actions: [
          ...[15, 30, 45, 60, 90].map((minutes) {
            return CupertinoActionSheetAction(
              onPressed: () {
                PlaybackLogService.instance
                    .log('UI', 'player: sleep timer $minutes min');
                widget.audioHandler.setSleepTimer(Duration(minutes: minutes));
                Navigator.pop(ctx);
              },
              child: Text('$minutes Minuti'),
            );
          }),
          CupertinoActionSheetAction(
            onPressed: () {
              PlaybackLogService.instance
                  .log('UI', 'player: sleep timer fine brano');
              widget.audioHandler.setSleepTimer(null, endOfTrack: true);
              Navigator.pop(ctx);
              _showNotice('La musica si fermerà alla fine del brano');
            },
            child: Text('Fine del Brano'),
          ),
          if (widget.audioHandler.isSleepTimerActive)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                PlaybackLogService.instance
                    .log('UI', 'player: sleep timer annullato');
                widget.audioHandler.cancelSleepTimer();
                Navigator.pop(ctx);
              },
              child: Text('Disattiva Timer'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Annulla'),
        ),
      ),
    );
  }
}

/// "Consigliati" list under the queue: tracks that fit after the current
/// song, each one tap away from the queue.
class _QueueSuggestions extends StatefulWidget {
  final AudioPlayerHandler audioHandler;

  const _QueueSuggestions({super.key, required this.audioHandler});

  @override
  State<_QueueSuggestions> createState() => _QueueSuggestionsState();
}

class _QueueSuggestionsState extends State<_QueueSuggestions> {
  late final Future<List<Song>> _suggestions =
      widget.audioHandler.suggestionsForCurrent();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return FutureBuilder<List<Song>>(
      future: _suggestions,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Song>[];
        if (songs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Row(
                children: [
                  Icon(CupertinoIcons.sparkles,
                      size: 16, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Consigliati', style: AppText.sectionTitle(colorScheme)),
                ],
              ),
            ),
            for (final song in songs)
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: song.thumbnailUrl,
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                  ),
                ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: colorScheme.onSurfaceVariant, fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: 'Aggiungi alla coda',
                  icon: Icon(CupertinoIcons.plus_circle,
                      color: colorScheme.primary, size: 24),
                  onPressed: () {
                    PlaybackLogService.instance
                        .log('UI', 'coda: aggiungo consigliato "${song.title}"');
                    widget.audioHandler.addToQueue(song);
                  },
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
    // Both sources are long-lived objects: a stream created here would be
    // subscribed again at every rebuild and lose its ticks.
    return StreamBuilder<MediaItem?>(
      stream: widget.audioHandler.mediaItem,
      builder: (context, itemSnapshot) {
        final published =
            (itemSnapshot.data ?? widget.mediaItem).duration ?? Duration.zero;
        final totalDuration = published > Duration.zero
            ? published
            : (widget.audioHandler.currentSong?.duration ?? Duration.zero);
        final maxMs = totalDuration.inMilliseconds.toDouble();

        return ValueListenableBuilder<Duration>(
          valueListenable: widget.audioHandler.positionNotifier,
          builder: (context, position, _) {
            final curMs = position.inMilliseconds.toDouble().clamp(0.0, maxMs > 0 ? maxMs : 1.0);
            final displayMs = (_isDragging && _dragValue != null) ? _dragValue!.clamp(0.0, maxMs > 0 ? maxMs : 1.0) : curMs;

            final displayDuration = Duration(milliseconds: displayMs.toInt());

            final primaryColor = Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black;
            final inactiveColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: _isDragging ? 5 : 3.5,
                    trackShape: const _AmbientSliderTrackShape(),
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: _isDragging ? 7.5 : 5.5,
                      elevation: _isDragging ? 4 : 1,
                    ),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: primaryColor,
                    inactiveTrackColor: inactiveColor,
                    thumbColor: primaryColor,
                  ),
                  child: SizedBox(
                    height: 24, 
                    child: Slider(
                      value: displayMs,
                      max: maxMs > 0 ? maxMs : 1.0,
                      onChangeStart: (val) {
                        setState(() { _isDragging = true; _dragValue = val; });
                      },
                      onChanged: (val) {
                        setState(() { _dragValue = val; });
                      },
                      onChangeEnd: (val) {
                        // The handler moves its position at once, so the
                        // thumb stays where it was released.
                        widget.audioHandler.seek(Duration(milliseconds: val.toInt()));
                        setState(() { _isDragging = false; _dragValue = null; });
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _fmt(displayDuration),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      Text(
                        _fmt(totalDuration), 
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Slider track painted with the brand gradient: the played part glows and
/// fades into the accent, the remaining part stays a hairline.
class _AmbientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _AmbientSliderTrackShape();

  @override
  bool get isRounded => true;

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
    final trackHeight = sliderTheme.trackHeight;
    if (trackHeight == null || trackHeight <= 0) return;

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(trackRect.height / 2);

    // Remaining part: quiet hairline.
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

    // Played part: gradient from the accent to its lighter twin.
    final gradient = LinearGradient(
      colors: [
        sliderTheme.activeTrackColor ?? Colors.white,
        Color.lerp(
              sliderTheme.thumbColor ?? Colors.white,
              Colors.white,
              0.35,
            ) ??
            Colors.white,
      ],
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, radius),
      Paint()..shader = gradient.createShader(trackRect),
    );
  }
}
