import 'dart:async';

import '../playback_log_service.dart';
import '../sponsor_block_service.dart';

/// SponsorBlock: jumps over the parts of the video playing that are not
/// music (intros, sponsors, talk).
class SegmentSkipper {
  SegmentSkipper({
    required this.fetchSegments,
    required this.currentGeneration,
    required this.canSkip,
    required this.trackDuration,
    required this.seek,
    required this.endTrack,
    required this.reportInfo,
  });

  /// The parts of a video to skip.
  final Future<List<SkipSegment>> Function(String videoId) fetchSegments;

  /// The load in progress: an answer for an older one is dropped.
  final int Function() currentGeneration;

  /// False while nothing must be skipped: a seek or a load is in flight, or
  /// another device is playing.
  final bool Function() canSkip;

  final Duration Function() trackDuration;
  final Future<void> Function(Duration position) seek;

  /// Ends the current track, as if it had played to its end.
  final void Function() endTrack;
  final void Function(String message) reportInfo;

  // The parts of the video playing to jump over, and which of them were
  // already jumped (or entered on purpose by the user) in this load.
  List<SkipSegment> _segments = const [];
  final Set<int> _passed = {};

  /// A load begins: the parts of the previous track are forgotten.
  void reset() {
    _segments = const [];
    _passed.clear();
  }

  /// Looks up the parts of [videoId], loaded as [generation], to skip.
  Future<void> load(String videoId, int generation) async {
    final segments = await fetchSegments(videoId);
    if (generation != currentGeneration() || segments.isEmpty) return;
    _segments = segments;
    PlaybackLogService.instance.log('SKIP', 'SponsorBlock $videoId: ${segments.join(', ')}');
  }

  /// The user moved to [target]: a part entered on purpose is not skipped.
  void markEntered(Duration target) {
    for (var i = 0; i < _segments.length; i++) {
      if (_segments[i].contains(target)) _passed.add(i);
    }
  }

  /// Jumps over the marked part [position] is in, once per load. A part
  /// that runs to the end of the track ends it.
  void skipAt(Duration position) {
    if (_segments.isEmpty || !canSkip()) return;
    for (var i = 0; i < _segments.length; i++) {
      final segment = _segments[i];
      if (_passed.contains(i) || !segment.contains(position)) continue;
      _passed.add(i);
      PlaybackLogService.instance.log('SKIP', 'salto $segment');
      final duration = trackDuration();
      final toEnd =
          duration > Duration.zero && segment.end >= duration - const Duration(seconds: 2);
      if (toEnd) {
        endTrack();
      } else {
        unawaited(seek(segment.end));
        reportInfo(segment.category == 'music_offtopic'
            ? 'Saltata una parte non musicale'
            : 'Saltato un segmento (${SponsorBlockService.categories[segment.category] ?? segment.category})');
      }
      return;
    }
  }
}
