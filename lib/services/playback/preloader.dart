import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../canvas_service.dart';
import '../canvas_video_pool.dart';
import '../cover_art_service.dart';
import '../lyrics_service.dart';
import '../playback_queue.dart';
import '../storage_service.dart';
import '../track_matcher_service.dart';
import '../ytmusic_service.dart';

/// Prepares what is around the current track, so that it is ready when it
/// is needed: the stream of the next track, the Canvas videos, the lyrics
/// and the original covers.
class PlaybackPreloader {
  PlaybackPreloader({
    required PlaybackQueue queue,
    required this.currentGeneration,
    required this.onQueueChanged,
    required this.onCurrentCoverChanged,
  }) : _queue = queue;

  final PlaybackQueue _queue;

  /// The load in progress: what was started for an older one stops.
  final int Function() currentGeneration;

  /// Called after a song of the queue was given its original cover.
  final void Function() onQueueChanged;

  /// Called when that song is the current one.
  final void Function() onCurrentCoverChanged;

  /// Swaps YouTube video thumbnails for the official album cover on the
  /// current track and the ones around it.
  void upgradeCoversAround() {
    final items = _queue.items;
    final index = _queue.index;
    if (index < 0) return;

    for (var i = index - 1; i <= index + 3; i++) {
      if (i < 0 || i >= items.length) continue;
      final song = items[i];
      if (!CoverArtService.needsOriginal(song.thumbnailUrl)) continue;

      unawaited(() async {
        try {
          final cover = await CoverArtService.instance.originalCover(song);
          if (cover == null) return;
          _queue.updateSong(song.id, (s) => s.copyWith(thumbnailUrl: cover));
          onQueueChanged();

          final current = _queue.current;
          if (current != null && current.id == song.id) {
            onCurrentCoverChanged();
            await StorageService.instance.addToHistory(current);
          }
        } catch (e) {
          debugPrint('PlaybackPreloader.upgradeCoversAround: $e');
        }
      }());
    }
  }

  /// The current track has started: what comes next is prepared now, and
  /// not before, so that nothing competes with its first seconds. The next
  /// track's stream first, then the Canvas videos around, and last the file
  /// that makes this track's Canvas instant the next time.
  void prepareWhatFollows(Song song, int generation) {
    unawaited(() async {
      await _prefetchNext();
      if (generation != currentGeneration()) return;
      _warmCanvasAround();
      unawaited(LyricsService.instance.preload(_upcoming(2)));
      await Future<void>.delayed(const Duration(seconds: 4));
      if (generation != currentGeneration()) return;
      await CanvasService.instance.keepForReplay(song);
    }());
  }

  /// The [count] songs that come after the current one in queue order.
  List<Song> _upcoming(int count) {
    final items = _queue.items;
    final index = _queue.index;
    if (index < 0) return const [];
    return items.sublist(index + 1, (index + 1 + count).clamp(index + 1, items.length));
  }

  /// Resolves the next track's stream ahead of time, so skipping to it (or
  /// reaching it) starts without the matching and lookup delay. With
  /// shuffle the next track is the one the queue has drawn.
  Future<void> _prefetchNext() async {
    final next = _queue.peekNext();
    if (next == null) return;
    final song = _queue.items[next];
    try {
      if (StorageService.instance.isDownloaded(song.id)) return;
      final videoId = await TrackMatcherService.instance.resolveAndCacheStreamId(song);
      if (videoId == null) return;
      final yt = YTMusicService.instance;
      if (await yt.getHlsAudioUrl(videoId) == null) await yt.getAudioStreamUrl(videoId);
    } catch (e) {
      debugPrint('PlaybackPreloader._prefetchNext: $e');
    }
  }

  /// Looks up and warms the Canvas of the current track, the one the user
  /// is about to look at. It starts with the track, alongside its audio.
  void warmCanvasForCurrent() {
    final song = _queue.current;
    if (song == null) return;
    unawaited(() async {
      final url = await CanvasService.instance.getCanvasUrl(song);
      if (url == null || url.isEmpty || _queue.current?.id != song.id) return;
      await CanvasVideoPool.instance.warm(url);
    }());
  }

  /// Looks up and warms the Canvas of the tracks around the current one
  /// (the previous, the next and, in queue order, the one after), so that
  /// skipping shows the video at once.
  void _warmCanvasAround() {
    final items = _queue.items;
    final index = _queue.index;
    if (index < 0) return;
    final around = <int>{
      ?_queue.peekPrevious(),
      ?_queue.peekNext(),
      if (!_queue.shuffle && index + 2 < items.length) index + 2,
    }..remove(index);

    for (final i in around) {
      final song = items[i];
      unawaited(() async {
        final url = await CanvasService.instance.prefetch(song);
        if (url == null || url.isEmpty) return;
        await CanvasVideoPool.instance.warm(url);
      }());
    }
  }
}
