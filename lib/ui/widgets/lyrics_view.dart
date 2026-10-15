import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../models/lyrics_model.dart';
import '../../models/song.dart';
import '../../services/app_settings.dart';
import '../../services/audio_handler.dart';
import '../../services/lyrics_service.dart';
import '../../services/lyrics_translator.dart';
import '../../services/playback_log_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';
import 'lyrics_actions.dart';

/// The lyrics of the song playing, as the player's second tab shows them:
/// the line being sung in the middle, lit word by word when the lyrics are
/// timed that way, with its translation and its spelling in Latin letters
/// under it when the user wants them. A bar at the foot translates, moves
/// the lyrics in time and opens the other actions.
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.audioHandler,
    required this.palette,
    required this.bottomInset,
    required this.visible,
  });

  final AudioPlayerHandler audioHandler;
  final AmbientPalette palette;
  final double bottomInset;

  /// Whether the tab is the one in sight: coming back to it brings the line
  /// being sung back to the middle.
  final bool visible;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  static const Color _ink = Colors.white;

  Song? _song;
  Lyrics _lyrics = Lyrics.empty;
  Lyrics _shown = Lyrics.empty;
  Duration _offset = Duration.zero;
  bool _loading = false;
  int _loadGeneration = 0;
  LyricsAnnotations _notes = LyricsAnnotations.empty;
  bool _annotating = false;

  final ScrollController _scroll = ScrollController();
  final ValueNotifier<int> _active = ValueNotifier<int>(-1);
  // While the user scrolls, following stops; it starts again a few seconds
  // after the last manual scroll.
  bool _browsing = false;
  Timer? _followTimer;
  StreamSubscription<MediaItem?>? _songs;

  AppSettings get _settings => AppSettings.instance;

  late final Listenable _lookSettings = Listenable.merge([
    _settings.lyricsTextSize,
    _settings.lyricsCentered,
    _settings.lyricsBlur,
    _settings.lyricsWordSync,
  ]);
  late final Listenable _noteSettings = Listenable.merge([
    _settings.lyricsTranslate,
    _settings.lyricsTranslateTo,
    _settings.lyricsRomanize,
  ]);

  @override
  void initState() {
    super.initState();
    _songs = widget.audioHandler.mediaItem.listen((_) {
      final song = widget.audioHandler.currentSong;
      if (song != null && song.id != _song?.id) _load(song);
    });
    widget.audioHandler.positionNotifier.addListener(_follow);
    LyricsService.instance.changes.addListener(_reload);
    _noteSettings.addListener(_annotate);
    _lookSettings.addListener(_onLookChanged);
    final song = widget.audioHandler.currentSong;
    if (song != null) _load(song);
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) {
      _followTimer?.cancel();
      _browsing = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive(force: true));
    }
  }

  @override
  void dispose() {
    _songs?.cancel();
    widget.audioHandler.positionNotifier.removeListener(_follow);
    LyricsService.instance.changes.removeListener(_reload);
    _noteSettings.removeListener(_annotate);
    _lookSettings.removeListener(_onLookChanged);
    _followTimer?.cancel();
    _scroll.dispose();
    _active.dispose();
    super.dispose();
  }

  void _onLookChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive(force: true));
  }

  // ── Loading ─────────────────────────────────────────────────────────────

  Future<void> _load(Song song, {bool refresh = false}) async {
    final generation = ++_loadGeneration;
    _song = song;
    _followTimer?.cancel();
    _browsing = false;
    _active.value = -1;
    setState(() {
      _loading = true;
      _lyrics = Lyrics.empty;
      _shown = Lyrics.empty;
      _notes = LyricsAnnotations.empty;
    });
    final lyrics = await LyricsService.instance.getLyrics(song, refresh: refresh);
    if (!mounted || generation != _loadGeneration) return;
    _apply(lyrics, LyricsService.instance.offsetOf(song.id));
  }

  /// The lyrics or their timing changed by the user's hand.
  Future<void> _reload() async {
    final song = _song;
    if (song == null) return;
    final generation = ++_loadGeneration;
    final lyrics = await LyricsService.instance.getLyrics(song);
    if (!mounted || generation != _loadGeneration) return;
    _apply(lyrics, LyricsService.instance.offsetOf(song.id));
  }

  void _apply(Lyrics lyrics, Duration offset) {
    final sameLines = _lyrics.lines.join('\n') == lyrics.lines.join('\n');
    setState(() {
      _lyrics = lyrics;
      _offset = offset;
      _shown = lyrics.shifted(offset);
      _loading = false;
      if (!sameLines) _notes = LyricsAnnotations.empty;
    });
    _follow();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive(force: true));
    if (!sameLines || _notes.translations.isEmpty) _annotate();
  }

  Future<void> _annotate() async {
    final translate = _settings.lyricsTranslate.value;
    final romanize = _settings.lyricsRomanize.value;
    final lines = _shown.lines;
    if (lines.isEmpty || (!translate && !romanize)) {
      if (_notes != LyricsAnnotations.empty && mounted) {
        setState(() => _notes = LyricsAnnotations.empty);
      }
      return;
    }
    final song = _song;
    setState(() => _annotating = true);
    try {
      final notes = await LyricsTranslator.instance.annotate(
        lines,
        target: _settings.lyricsTranslateTo.value,
        translate: translate,
        romanize: romanize,
      );
      if (!mounted || _song?.id != song?.id) return;
      setState(() => _notes = notes);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive(force: true));
    } catch (e) {
      PlaybackLogService.instance.log('LYRICS', 'traduzione non riuscita: $e');
    } finally {
      if (mounted) setState(() => _annotating = false);
    }
  }

  // ── Following the song ──────────────────────────────────────────────────

  void _follow() {
    if (!mounted || !_shown.isSynced) return;
    final position = widget.audioHandler.position;
    final index = _shown.syncedLyrics.lastIndexWhere((line) => line.time <= position);
    if (index != _active.value) {
      _active.value = index;
      _scrollToActive();
    }
  }

  double get _fontSize => const [20.0, 24.0, 28.0][_settings.lyricsTextSize.value.clamp(0, 2)];
  double get _noteSize => _fontSize * 0.6;

  bool get _hasTranslation => _notes.translations.any((t) => t.isNotEmpty);
  bool get _hasRomanization => _notes.romanized.any((t) => t.isNotEmpty);

  /// Every row is as tall as the tallest can be: the active one then sits
  /// exactly in the middle of the view.
  double get _rowExtent =>
      _fontSize * 1.25 * 2 +
      22 +
      (_hasRomanization ? _noteSize * 1.4 + 2 : 0) +
      (_hasTranslation ? _noteSize * 1.4 + 2 : 0);

  void _scrollToActive({bool force = false}) {
    if (!_scroll.hasClients || !widget.visible) return;
    if (_browsing && !force) return;
    final index = _active.value;
    if (index < 0) return;
    final position = _scroll.position;
    if (!position.hasViewportDimension) return;
    _scroll.animateTo(
      (index * _rowExtent).clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification || notification is UserScrollNotification) {
      final byUser = notification is UserScrollNotification
          ? notification.direction != ScrollDirection.idle
          : (notification as ScrollStartNotification).dragDetails != null;
      if (byUser) {
        _browsing = true;
        _followTimer?.cancel();
      }
    } else if (notification is ScrollEndNotification && _browsing) {
      _followTimer?.cancel();
      _followTimer = Timer(const Duration(seconds: 4), () {
        _browsing = false;
        if (mounted) _scrollToActive(force: true);
      });
    }
  }

  // ── Drawing ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final faint = _ink.withValues(alpha: 0.38);
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator(color: _ink, radius: 14));
    }
    final song = _song;
    if (song == null || _shown.isEmpty) return _empty(faint);

    return Stack(
      children: [
        Positioned.fill(child: _shown.isSynced ? _synced(faint) : _plain()),
        Positioned(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          bottom: widget.bottomInset + AppSpacing.sm,
          child: _toolbar(song),
        ),
      ],
    );
  }

  Widget _empty(Color faint) {
    final song = _song;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(AppIcons.lyrics, size: 46, color: faint),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Testo non disponibile',
            style: TextStyle(
              color: _ink.withValues(alpha: 0.72),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.md,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _ink,
                  side: BorderSide(color: _ink.withValues(alpha: 0.4)),
                ),
                onPressed: song == null ? null : () => _load(song, refresh: true),
                child: const Text('Riprova'),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _ink,
                  side: BorderSide(color: _ink.withValues(alpha: 0.4)),
                ),
                onPressed: song == null ? null : () => showLyricsSearch(context, song),
                child: const Text('Cerca il testo'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _plain() {
    final lines = _shown.lines;
    final centered = _settings.lyricsCentered.value;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.xl,
        widget.bottomInset + 84,
      ),
      child: Column(
        crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                children: [
                  Text(
                    lines[i],
                    textAlign: centered ? TextAlign.center : TextAlign.start,
                    style: TextStyle(
                      color: _ink,
                      fontSize: _fontSize * 0.85,
                      height: 1.35,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  ..._notesFor(i, centered),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _notesFor(int index, bool centered) {
    final romanized = index < _notes.romanized.length ? _notes.romanized[index] : '';
    final translated = index < _notes.translations.length ? _notes.translations[index] : '';
    final style = TextStyle(
      color: _ink.withValues(alpha: 0.62),
      fontSize: _noteSize,
      height: 1.3,
      fontWeight: FontWeight.w600,
    );
    return [
      if (romanized.isNotEmpty)
        Text(
          romanized,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: style.copyWith(fontStyle: FontStyle.italic),
        ),
      if (translated.isNotEmpty)
        Text(
          translated,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: style.copyWith(color: widget.palette.accent.withValues(alpha: 0.9)),
        ),
    ];
  }

  Widget _synced(Color faint) {
    final centered = _settings.lyricsCentered.value;
    final blur = _settings.lyricsBlur.value;
    final karaoke = _settings.lyricsWordSync.value;
    final extent = _rowExtent;
    return ValueListenableBuilder<int>(
      valueListenable: _active,
      builder: (context, active, _) => LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.maxHeight;
          final padding = (viewport / 2 - extent / 2).clamp(0.0, viewport);
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              _onScroll(notification);
              return false;
            },
            // Two lines at the active size must always fit their row.
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.05,
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(AppSpacing.xl, padding, AppSpacing.xl, padding),
                physics: const BouncingScrollPhysics(),
                itemExtent: extent,
                itemCount: _shown.syncedLyrics.length,
                itemBuilder: (context, index) {
                  final line = _shown.syncedLyrics[index];
                  final isActive = index == active;
                  final style = DefaultTextStyle.of(context).style.copyWith(
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w800,
                    color: isActive
                        ? _ink
                        : (index < active ? _ink.withValues(alpha: 0.62) : faint),
                    height: 1.25,
                    letterSpacing: -0.4,
                  );
                  Widget text = isActive && karaoke && line.words.isNotEmpty
                      ? _KaraokeLine(
                          line: line,
                          handler: widget.audioHandler,
                          style: style,
                          waiting: faint,
                          centered: centered,
                        )
                      : AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          style: style,
                          child: Text(
                            line.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: centered ? TextAlign.center : TextAlign.start,
                          ),
                        );
                  Widget row = Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: centered
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [text, ..._notesFor(index, centered)],
                  );
                  if (blur && !isActive && !_browsing) {
                    final distance = (index - active).abs().clamp(1, 4);
                    row = ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 0.9 * distance, sigmaY: 0.9 * distance),
                      child: row,
                    );
                  }
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      PlaybackLogService.instance.log(
                        'UI',
                        'testi: tap riga ${line.time.inSeconds}s',
                      );
                      _followTimer?.cancel();
                      _browsing = false;
                      widget.audioHandler.seek(line.time);
                      _active.value = index;
                      _scrollToActive(force: true);
                    },
                    child: Align(
                      alignment: centered ? Alignment.center : Alignment.centerLeft,
                      child: row,
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _toolbar(Song song) {
    final translating = _settings.lyricsTranslate.value;
    Widget button(IconData icon, String tooltip, VoidCallback onTap, {bool on = false}) =>
        IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon, size: 21, color: on ? widget.palette.accent : _ink),
        );
    final source = _shown.source;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          height: 46,
          padding: const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.xs),
          color: Colors.black.withValues(alpha: 0.28),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  [
                    if (source.isNotEmpty) source,
                    if (_shown.isWordSynced)
                      'parola per parola'
                    else if (_shown.isSynced)
                      'sincronizzato'
                    else
                      'senza tempi',
                    if (_offset != Duration.zero) _offsetLabel(_offset),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _ink.withValues(alpha: 0.7), fontSize: 12.5),
                ),
              ),
              if (_annotating)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: CupertinoActivityIndicator(color: _ink, radius: 8),
                ),
              button(
                AppIcons.translate,
                translating ? 'Nascondi la traduzione' : 'Traduci',
                () => _settings.lyricsTranslate.set(!translating),
                on: translating,
              ),
              if (_shown.isSynced)
                button(AppIcons.timer, 'Sincronizzazione', () => showLyricsOffset(context, song)),
              button(AppIcons.more, 'Opzioni dei testi', () {
                showLyricsMenu(
                  context,
                  song: song,
                  lyrics: _lyrics,
                  palette: widget.palette,
                  onRefresh: () => _load(song, refresh: true),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

String _offsetLabel(Duration offset) {
  final ms = offset.inMilliseconds;
  final sign = ms > 0 ? '+' : '−';
  return '$sign${(ms.abs() / 1000).toStringAsFixed(1)} s';
}

/// The line being sung, lit word by word as it is sung: the words already
/// sung in full, the one being sung filling, the others waiting.
class _KaraokeLine extends StatefulWidget {
  const _KaraokeLine({
    required this.line,
    required this.handler,
    required this.style,
    required this.waiting,
    required this.centered,
  });

  final LyricLine line;
  final AudioPlayerHandler handler;
  final TextStyle style;
  final Color waiting;
  final bool centered;

  @override
  State<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends State<_KaraokeLine> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  // The position last reported, and when: between two reports it is
  // estimated, so that the words fill smoothly.
  Duration _reported = Duration.zero;
  DateTime _reportedAt = DateTime.now();
  Duration _now = Duration.zero;

  @override
  void initState() {
    super.initState();
    _onPosition();
    widget.handler.positionNotifier.addListener(_onPosition);
    _ticker = createTicker((_) {
      final playing = widget.handler.playbackState.value.playing;
      final speed = widget.handler.playbackState.value.speed;
      final elapsed = playing ? DateTime.now().difference(_reportedAt) * speed : Duration.zero;
      final estimate = _reported + elapsed;
      if ((estimate - _now).abs() > const Duration(milliseconds: 16)) {
        setState(() => _now = estimate);
      }
    })..start();
  }

  void _onPosition() {
    _reported = widget.handler.position;
    _reportedAt = DateTime.now();
  }

  @override
  void dispose() {
    widget.handler.positionNotifier.removeListener(_onPosition);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sung = widget.style.color ?? Colors.white;
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.centered ? TextAlign.center : TextAlign.start,
      textScaler: MediaQuery.textScalerOf(context),
      text: TextSpan(
        style: widget.style,
        children: [
          for (final word in widget.line.words)
            TextSpan(
              text: word.text,
              style: TextStyle(color: _colorOf(word, sung)),
            ),
        ],
      ),
    );
  }

  Color _colorOf(LyricWord word, Color sung) {
    if (_now >= word.end) return sung;
    if (_now <= word.start) return widget.waiting;
    final length = (word.end - word.start).inMilliseconds;
    final done = length <= 0 ? 1.0 : (_now - word.start).inMilliseconds / length;
    return Color.lerp(widget.waiting, sung, done.clamp(0.0, 1.0))!;
  }
}
