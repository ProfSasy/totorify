import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../playback_log_service.dart';
import '../playback_queue.dart';
import '../recommendation_service.dart';

/// Recommendations around the queue: the songs offered after the current
/// one, and Smart Shuffle, which mixes a few of them into the queue.
class SuggestionManager {
  SuggestionManager({
    required PlaybackQueue queue,
    required this.recommend,
    required this.youtubeSeedFor,
    required this.enableShuffle,
    required this.onQueueChanged,
  }) : _queue = queue;

  final PlaybackQueue _queue;

  /// Recommendations for a song, best first.
  final Future<List<Song>> Function(Song seed, {String? youtubeSeedId}) recommend;

  /// YouTube video to seed recommendations from when the catalog has no
  /// match for the song.
  final String? Function(Song song) youtubeSeedFor;

  /// Turns the shuffle mode on.
  final Future<void> Function() enableShuffle;

  /// Called after the queue was changed here.
  final void Function() onQueueChanged;

  /// Smart Shuffle: shuffle plus recommended tracks mixed into the queue.
  final ValueNotifier<bool> smartShuffleNotifier = ValueNotifier<bool>(false);

  /// Ids of the queued songs that were added as recommendations.
  final ValueNotifier<Set<String>> suggestedIdsNotifier =
      ValueNotifier<Set<String>>(const {});

  // Recommendations queued but not played yet, and how many more may still
  // be added to the current queue.
  final Set<String> _pendingSuggestions = {};
  int _suggestionBudget = 0;
  bool _toppingUp = false;
  static const int _suggestionsAhead = 3;

  /// Recommendations for [seed] that are not already in the queue.
  Future<List<Song>> fresh(Song seed) async {
    final recommended = await recommend(seed, youtubeSeedId: youtubeSeedFor(seed));
    final queuedIds = {for (final s in _queue.items) s.id};
    final queuedKeys = {for (final s in _queue.items) RecommendationService.songKey(s)};
    return [
      for (final song in recommended)
        if (!queuedIds.contains(song.id) &&
            queuedKeys.add(RecommendationService.songKey(song)))
          song,
    ];
  }

  /// Recommended next tracks for the song playing now, for the queue view.
  Future<List<Song>> forCurrent({int limit = 6}) async {
    final seed = _queue.current;
    if (seed == null) return [];
    return (await fresh(seed)).take(limit).toList();
  }

  Future<void> setSmartShuffle(bool enabled) async {
    if (smartShuffleNotifier.value == enabled) return;
    smartShuffleNotifier.value = enabled;
    PlaybackLogService.instance.log('CMD', enabled ? 'smart shuffle on' : 'smart shuffle off');

    if (enabled) {
      await enableShuffle();
      resetBudget();
      await topUp();
      return;
    }

    // Drop the recommendations that have not played yet.
    final items = _queue.items;
    for (var i = items.length - 1; i >= 0; i--) {
      if (i != _queue.index && _pendingSuggestions.contains(items[i].id)) {
        _queue.removeAt(i);
      }
    }
    syncWithQueue();
    onQueueChanged();
  }

  void resetBudget() {
    // About one recommendation every three tracks of the user's own queue.
    final suggested = suggestedIdsNotifier.value;
    final own = _queue.items.where((s) => !suggested.contains(s.id)).length;
    _suggestionBudget = (own / 3).ceil().clamp(3, 30);
  }

  /// Forgets the recommendations that are no longer in the queue.
  void syncWithQueue() {
    final queuedIds = {for (final s in _queue.items) s.id};
    _pendingSuggestions.retainAll(queuedIds);
    final kept = suggestedIdsNotifier.value.intersection(queuedIds);
    if (kept.length != suggestedIdsNotifier.value.length) {
      suggestedIdsNotifier.value = kept;
    }
  }

  /// [songId] started to play: it is no longer a recommendation waiting.
  void markPlayed(String songId) => _pendingSuggestions.remove(songId);

  /// Keeps a few recommendations queued ahead while Smart Shuffle is on.
  Future<void> topUp() async {
    if (!smartShuffleNotifier.value || _toppingUp) return;
    final seed = _queue.current;
    if (seed == null ||
        _suggestionBudget <= 0 ||
        _pendingSuggestions.length >= _suggestionsAhead) {
      return;
    }

    _toppingUp = true;
    try {
      final picks = await fresh(seed);
      // The track or the mode changed while loading: the next change retries.
      if (!smartShuffleNotifier.value || _queue.current?.id != seed.id) return;

      var added = 0;
      for (final song in picks) {
        if (_suggestionBudget <= 0 ||
            _pendingSuggestions.length >= _suggestionsAhead) {
          break;
        }
        // Spread them after the current track: +2, +5, +8.
        _queue.insertAt(_queue.index + 2 + added * 3, song);
        _pendingSuggestions.add(song.id);
        _suggestionBudget--;
        added++;
      }
      if (added > 0) {
        suggestedIdsNotifier.value = {
          ...suggestedIdsNotifier.value,
          ..._pendingSuggestions,
        };
        onQueueChanged();
      }
    } catch (e) {
      debugPrint('SuggestionManager.topUp: $e');
    } finally {
      _toppingUp = false;
    }
  }
}
