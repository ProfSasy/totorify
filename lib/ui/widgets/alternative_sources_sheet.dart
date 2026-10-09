import '../../services/playback_log_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/song.dart';
import '../../services/audio_handler.dart';
import '../../services/storage_service.dart';
import '../../services/track_matcher_service.dart';

/// Modal bottom sheet allowing users to view, inspect, and choose alternative
/// audio stream sources from YouTube/YouTube Music for a given song.
/// Inspired by Spotube's Alternative Track Sources feature.
class AlternativeSourcesSheet extends StatefulWidget {
  final Song song;
  final AudioPlayerHandler audioHandler;

  const AlternativeSourcesSheet({
    super.key,
    required this.song,
    required this.audioHandler,
  });

  static Future<void> show(
    BuildContext context, {
    required Song song,
    required AudioPlayerHandler audioHandler,
  }) {
    PlaybackLogService.instance
        .log('UI', 'fonti alternative: apri "${song.title}"');
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0),
      builder: (ctx) => AlternativeSourcesSheet(
        song: song,
        audioHandler: audioHandler,
      ),
    );
  }

  @override
  State<AlternativeSourcesSheet> createState() => _AlternativeSourcesSheetState();
}

class _AlternativeSourcesSheetState extends State<AlternativeSourcesSheet> {
  bool _isLoading = true;
  bool _isApplying = false;
  List<ScoredTrackMatch> _matches = [];
  String? _currentSelectedYtId;
  int _offsetMs = 0;

  @override
  void initState() {
    super.initState();
    _currentSelectedYtId = widget.song.youtubeVideoId ??
        StorageService.instance.getCachedYouTubeMapping(widget.song.id) ??
        // A song that is a YouTube video plays that video unless told otherwise.
        (TrackMatcherService.needsResolution(widget.song.id) ? null : widget.song.id);
    _offsetMs = StorageService.instance.getStartOffsetMs(widget.song.id) ?? 0;
    _loadMatches();
  }

  Future<void> _loadMatches() async {
    setState(() => _isLoading = true);
    final results = await TrackMatcherService.instance.getAlternativeMatches(widget.song);
    if (!mounted) return;
    setState(() {
      _matches = results;
      _isLoading = false;
      // If none selected yet, default to the top match
      if (_currentSelectedYtId == null && results.isNotEmpty) {
        _currentSelectedYtId = results.first.song.id;
      }
    });
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return '--:--';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _offsetButton(int deltaMs, String label) {
    return GestureDetector(
      onTap: () {
        final next = (_offsetMs + deltaMs).clamp(0, 600000);
        setState(() => _offsetMs = next);
        widget.audioHandler.applyStartOffset(widget.song, next);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Future<void> _selectSource(ScoredTrackMatch match) async {
    // A double tap would run two concurrent hot-swaps and pop twice.
    if (_isApplying) return;
    _isApplying = true;
    PlaybackLogService.instance.log(
      'UI',
      'fonti alternative: scelgo "${match.song.title}" (${match.song.id})',
    );
    HapticFeedback.mediumImpact();
    setState(() => _currentSelectedYtId = match.song.id);

    await widget.audioHandler.switchAudioSource(
      widget.song,
      match.song.id,
      newDuration: match.song.duration,
    );

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Capture theme colors before popping: the context is disposed after.
    final accent = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    Navigator.of(context).pop();

    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(CupertinoIcons.checkmark_seal_fill, color: accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Fonte audio aggiornata: ${match.song.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        backgroundColor: surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final maxHeight = MediaQuery.of(context).size.height * 0.82;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 16, 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    CupertinoIcons.tuningfork,
                    size: 20,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fonti Audio Alternative',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Motore di matching Spotube per ${widget.song.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(CupertinoIcons.xmark_circle_fill,
                      color: Theme.of(context).colorScheme.onSurfaceVariant, size: 24),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Start alignment: compensates music-video intros.
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.clock,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Allinea inizio: ${(_offsetMs / 1000).toStringAsFixed(1)}s',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                _offsetButton(-10000, '-10s'),
                _offsetButton(-1000, '-1s'),
                _offsetButton(1000, '+1s'),
                _offsetButton(10000, '+10s'),
                IconButton(
                  tooltip: 'Azzera',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(CupertinoIcons.arrow_counterclockwise,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  onPressed: () {
                    setState(() => _offsetMs = 0);
                    widget.audioHandler.applyStartOffset(widget.song, 0);
                  },
                ),
              ],
            ),
          ),

          // Target Reference Card
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: widget.song.thumbnailUrl,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.1)),
                    errorWidget: (_, _, _) => Container(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.1)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'SPOTIFY TARGET',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'Durata: ${_formatDuration(widget.song.duration)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.song.title} • ${widget.song.artist}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Match Results List
          Expanded(
            child: _isLoading
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CupertinoActivityIndicator(
                          radius: 14,
                          color: primaryColor,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Scansione delle sorgenti audio e scoring Spotube...',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : _matches.isEmpty
                    ? Center(
                        child: Text(
                          'Nessuna sorgente alternativa trovata',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        // Bottom inset keeps the last source clear of the
                        // home indicator inside the modal sheet.
                        padding: EdgeInsets.fromLTRB(
                          16,
                          8,
                          16,
                          MediaQuery.viewPaddingOf(context).bottom + 8,
                        ),
                        itemCount: _matches.length,
                        itemBuilder: (context, index) {
                          final match = _matches[index];
                          final isSelected = match.song.id == _currentSelectedYtId;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? primaryColor.withValues(alpha: 0.12)
                                  : Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected
                                    ? primaryColor.withValues(alpha: 0.6)
                                    : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
                                width: isSelected ? 1.5 : 1.0,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => _selectSource(match),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    // Thumbnail with Duration Overlay
                                    Stack(
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          child: CachedNetworkImage(
                                            imageUrl: match.song.thumbnailUrl,
                                            width: 58,
                                            height: 48,
                                            fit: BoxFit.cover,
                                            placeholder: (_, _) => Container(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.1)),
                                            errorWidget: (_, _, _) => Container(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.1)),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 2,
                                          right: 2,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              _formatDuration(match.song.duration),
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(context).colorScheme.onSurface,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(width: 12),

                                    // Video Metadata & Quality Badge
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            match.song.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: isSelected
                                                  ? FontWeight.bold
                                                  : FontWeight.w600,
                                              color: Theme.of(context).colorScheme.onSurface,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Row(
                                            children: [
                                              if (match.isTopicOrOfficial)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          right: 4),
                                                  child: Icon(
                                                    CupertinoIcons
                                                        .checkmark_seal_fill,
                                                    size: 12,
                                                    color: primaryColor,
                                                  ),
                                                ),
                                              Expanded(
                                                child: Text(
                                                  match.song.artist,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          // Badge matching quality
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 2),
                                                decoration: BoxDecoration(
                                                   color: primaryColor
                                                       .withValues(alpha: 0.2),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  border: Border.all(
                                                     color: primaryColor
                                                        .withValues(alpha: 0.5),
                                                    width: 0.8,
                                                  ),
                                                ),
                                                child: Text(
                                                  match.qualityLabel,
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                     color: primaryColor,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                'Score: ${match.score} pts',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),

                                    const SizedBox(width: 8),

                                    // Selection Indicator
                                    Icon(
                                      isSelected
                                          ? CupertinoIcons.checkmark_circle_fill
                                          : CupertinoIcons.circle,
                                      color: isSelected
                                          ? primaryColor
                                          : Theme.of(context).colorScheme.onSurfaceVariant,
                                      size: 22,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
