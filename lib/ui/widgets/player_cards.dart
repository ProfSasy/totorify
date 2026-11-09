import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/artist.dart';
import '../../models/lyrics_model.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/lyrics_service.dart';
import '../../services/ytmusic_catalog_service.dart';
import '../theme/app_ambience.dart';
import '../theme/app_tokens.dart';
import 'app_cover.dart';

/// The cards under the player, reached by scrolling it up as in Spotify:
/// a preview of the lyrics, the artist, what plays next and the credits.
class PlayerCards extends StatefulWidget {
  const PlayerCards({
    super.key,
    required this.audioHandler,
    required this.song,
    required this.palette,
    required this.onLyrics,
    required this.onQueue,
    required this.onArtist,
    required this.onDetails,
  });

  final AudioPlayerHandler audioHandler;
  final Song song;
  final AmbientPalette palette;
  final VoidCallback onLyrics;
  final VoidCallback onQueue;
  final VoidCallback onArtist;
  final VoidCallback onDetails;

  @override
  State<PlayerCards> createState() => _PlayerCardsState();
}

class _PlayerCardsState extends State<PlayerCards> {
  // One look-up per artist while the app is open: the cards are rebuilt at
  // every tick of the player.
  static final Map<String, Future<Artist?>> _artists = {};

  Future<Lyrics>? _lyrics;
  Future<Artist?>? _artist;
  String? _songId;

  static const Color _ink = Colors.white;

  static String _mainArtist(Song song) => song.artist.split(',').first.trim();

  void _load() {
    final song = widget.song;
    if (song.id == _songId) return;
    _songId = song.id;
    _lyrics = LyricsService.instance.getLyrics(song);
    final name = _mainArtist(song);
    _artist = name.isEmpty
        ? Future.value(null)
        : _artists.putIfAbsent(name, () => YTMusicCatalogService.instance.findArtist(name));
  }

  @override
  Widget build(BuildContext context) {
    _load();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _lyricsCard(),
          const SizedBox(height: AppSpacing.lg),
          _artistCard(),
          const SizedBox(height: AppSpacing.lg),
          _nextCard(),
          const SizedBox(height: AppSpacing.lg),
          _creditsCard(),
        ],
      ),
    );
  }

  Widget _card({required Widget child, required VoidCallback onTap, Color? color}) {
    return Material(
      color: color ?? Color.lerp(widget.palette.surface, Colors.white, 0.07),
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: child),
    );
  }

  Widget _cardTitle(String title, {String? action, VoidCallback? onAction}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.md, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: _ink, fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _ink.withValues(alpha: 0.5)),
                ),
                child: Text(
                  action,
                  style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Lyrics ──────────────────────────────────────────────────────────────

  Widget _lyricsCard() {
    return _card(
      // The vivid colour of the cover, as Spotify gives its lyrics card.
      color: Color.lerp(widget.palette.accent, Colors.black, 0.45),
      onTap: widget.onLyrics,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('Anteprima del testo', action: 'Mostra testo', onAction: widget.onLyrics),
          FutureBuilder<Lyrics>(
            future: _lyrics,
            builder: (context, snapshot) {
              final lyrics = snapshot.data;
              final lines = lyrics == null
                  ? const <String>[]
                  : (lyrics.syncedLyrics.isNotEmpty
                          ? lyrics.syncedLyrics.map((l) => l.text)
                          : lyrics.plainLyrics.split('\n'))
                      .map((l) => l.trim())
                      .where((l) => l.isNotEmpty)
                      .take(6)
                      .toList();
              final text = snapshot.connectionState != ConnectionState.done
                  ? null
                  : lines.isEmpty
                      ? 'Il testo di questo brano non è disponibile.'
                      : lines.join('\n');
              return Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
                child: text == null
                    ? const SizedBox(
                        height: 60,
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: _ink)),
                      )
                    : Text(
                        text,
                        style: TextStyle(
                          color: _ink,
                          fontSize: lines.isEmpty ? 15 : 21,
                          height: 1.35,
                          fontWeight: lines.isEmpty ? FontWeight.w500 : FontWeight.w800,
                        ),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Artist ──────────────────────────────────────────────────────────────

  Widget _artistCard() {
    return FutureBuilder<Artist?>(
      future: _artist,
      builder: (context, snapshot) {
        final artist = snapshot.data;
        final name = artist?.name ?? _mainArtist(widget.song);
        return _card(
          onTap: widget.onArtist,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (artist != null && artist.imageUrl.isNotEmpty)
                      LayoutBuilder(
                        builder: (context, box) => AppCover(
                          url: artist.imageUrl,
                          size: box.maxWidth,
                          radius: 0,
                        ),
                      )
                    else
                      ColoredBox(color: widget.palette.deep),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x99000000), Color(0x00000000), Color(0x66000000)],
                        ),
                      ),
                    ),
                    const Positioned(
                      left: AppSpacing.lg,
                      top: AppSpacing.lg,
                      child: Text(
                        'Informazioni sull\'artista',
                        style: TextStyle(color: _ink, fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                    if ((artist?.audience ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        artist!.audience,
                        style: TextStyle(color: _ink.withValues(alpha: 0.72), fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      'Tocca per aprire la pagina dell\'artista',
                      style: TextStyle(color: _ink.withValues(alpha: 0.6), fontSize: 12),
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

  // ── Up next ─────────────────────────────────────────────────────────────

  Widget _nextCard() {
    final queue = widget.audioHandler.queueSnapshot;
    final next = queue.index < 0
        ? const <Song>[]
        : queue.songs.skip(queue.index + 1).take(3).toList();
    return _card(
      onTap: widget.onQueue,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('Prossimi in coda', action: 'Apri la coda', onAction: widget.onQueue),
          if (next.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
              child: Text(
                'Dopo questo brano parte la radio con brani simili.',
                style: TextStyle(color: _ink.withValues(alpha: 0.72), fontSize: 13),
              ),
            )
          else
            for (final song in next)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                child: Row(
                  children: [
                    AppCover(url: song.thumbnailUrl, size: 42),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _ink.withValues(alpha: 0.72), fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ── Credits ─────────────────────────────────────────────────────────────

  Widget _creditsCard() {
    final song = widget.song;
    final rows = <(String, String)>[
      ('Artista', song.artist),
      if ((song.album ?? '').isNotEmpty) ('Album', song.album!),
      if (song.duration > Duration.zero)
        ('Durata', '${song.duration.inMinutes}:${(song.duration.inSeconds % 60).toString().padLeft(2, '0')}'),
    ];
    return _card(
      onTap: widget.onDetails,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('Crediti', action: 'Mostra tutto', onAction: widget.onDetails),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: const TextStyle(color: _ink, fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(label, style: TextStyle(color: _ink.withValues(alpha: 0.6), fontSize: 12.5)),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}

/// Closes the player when it is pulled down from the top of its scroll, as
/// the sheet itself would without a scrollable inside.
class PullToClose extends StatefulWidget {
  const PullToClose({super.key, required this.onClose, required this.child});

  final VoidCallback onClose;
  final Widget child;

  @override
  State<PullToClose> createState() => _PullToCloseState();
}

class _PullToCloseState extends State<PullToClose> {
  static const double _distance = 70;
  double _pulled = 0;
  bool _closed = false;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        if (notification is OverscrollNotification &&
            notification.overscroll < 0 &&
            notification.metrics.pixels <= notification.metrics.minScrollExtent) {
          _pulled -= notification.overscroll;
          if (_pulled > _distance && !_closed) {
            _closed = true;
            scheduleMicrotask(widget.onClose);
          }
        } else if (notification is ScrollEndNotification) {
          _pulled = 0;
        }
        return false;
      },
      child: widget.child,
    );
  }
}
