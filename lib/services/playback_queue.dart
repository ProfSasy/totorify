import 'dart:math';

import '../models/song.dart';

enum PlaybackRepeat { off, all, one }

/// Queue state for the player: order, current index, shuffle and repeat.
///
/// Has no player or platform dependencies, so the navigation rules can be
/// unit-tested directly. [AudioPlayerHandler] owns one instance and only
/// decides *how* to play the track it points at.
class PlaybackQueue {
  PlaybackQueue({Random? random}) : _random = random ?? Random();

  final Random _random;
  final List<Song> _items = [];

  // Ids of the tracks played before the current one, most recent last.
  // Lets a shuffled session walk back to where it came from.
  final List<String> _backStack = [];

  // Shuffle only: ids already played in the current round, so shuffle does
  // not repeat a track until every track has been played once.
  final Set<String> _playedRound = {};

  static const int _maxBackStack = 200;

  int _index = -1;
  bool _shuffle = false;
  PlaybackRepeat _repeat = PlaybackRepeat.off;

  List<Song> get items => List.unmodifiable(_items);
  int get index => _index;
  bool get isEmpty => _items.isEmpty;
  bool get shuffle => _shuffle;
  PlaybackRepeat get repeat => _repeat;

  Song? get current =>
      (_index >= 0 && _index < _items.length) ? _items[_index] : null;

  void setRepeat(PlaybackRepeat mode) => _repeat = mode;

  void setShuffle(bool enabled) {
    _shuffle = enabled;
    _playedRound.clear();
    if (enabled && current != null) _playedRound.add(current!.id);
  }

  /// Replaces the queue with [songs] and points at [start]. If [start] is
  /// not in [songs] it is inserted at the top. Shuffle and repeat are kept.
  void replace(List<Song> songs, Song start) {
    _items
      ..clear()
      ..addAll(songs.isNotEmpty ? songs : [start]);
    _index = _items.indexWhere((s) => s.id == start.id);
    if (_index == -1) {
      _items.insert(0, start);
      _index = 0;
    }
    _backStack.clear();
    _playedRound.clear();
    if (_shuffle) _playedRound.add(start.id);
  }

  void append(Song song) => _items.add(song);

  /// Appends the songs whose ids are not queued yet. Returns how many were
  /// added; the first added song sits at the previous length.
  int appendUnique(Iterable<Song> songs) {
    var added = 0;
    for (final song in songs) {
      if (_items.any((s) => s.id == song.id)) continue;
      _items.add(song);
      added++;
    }
    return added;
  }

  /// Inserts [song] at [at] (clamped), keeping the current song current.
  void insertAt(int at, Song song) {
    final target = at.clamp(0, _items.length);
    _items.insert(target, song);
    if (_index >= 0 && target <= _index) _index++;
  }

  void insertAfterCurrent(Song song) {
    final at = (_index + 1).clamp(0, _items.length);
    _items.insert(at, song);
  }

  /// Replaces the song with [id] using [update] (e.g. a new YouTube source).
  void updateSong(String id, Song Function(Song) update) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].id == id) _items[i] = update(_items[i]);
    }
  }

  /// Removes the song at [i]. Returns true when it was the current song.
  /// Afterwards [index] points at the song that took its place, or is -1
  /// when there is none (the removed song was the last one).
  bool removeAt(int i) {
    if (i < 0 || i >= _items.length) return false;
    final removed = _items.removeAt(i);
    _backStack.removeWhere((id) => id == removed.id);
    _playedRound.remove(removed.id);

    final wasCurrent = i == _index;
    if (i < _index) {
      _index--;
    } else if (wasCurrent) {
      _index = i < _items.length ? i : -1;
    }
    return wasCurrent;
  }

  void move(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _items.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, _items.length - 1);
    final item = _items.removeAt(oldIndex);
    _items.insert(newIndex, item);

    if (_index == oldIndex) {
      _index = newIndex;
    } else if (oldIndex < _index && newIndex >= _index) {
      _index--;
    } else if (oldIndex > _index && newIndex <= _index) {
      _index++;
    }
  }

  /// Index the next track moves to, or null at the end of the queue.
  /// Manual skip rules: repeat-one does not affect this; the caller handles
  /// natural track end by restarting the current song.
  int? peekNext() {
    if (current == null) return null;
    if (_shuffle) return _pickShuffled();
    if (_index < _items.length - 1) return _index + 1;
    return _repeat == PlaybackRepeat.all ? 0 : null;
  }

  /// Index the previous track moves to, or null when there is none.
  int? peekPrevious() {
    if (current == null) return null;
    if (_shuffle) {
      if (_backStack.isEmpty) return null;
      final i = _items.indexWhere((s) => s.id == _backStack.last);
      return i == -1 ? null : i;
    }
    return _index > 0 ? _index - 1 : null;
  }

  /// Moves the current pointer to [target], which must come from [peekNext]
  /// or [peekPrevious]. Pass [back] for a backward move.
  void moveTo(int target, {bool back = false}) {
    assert(target >= 0 && target < _items.length);
    final from = current;

    if (back) {
      if (_backStack.isNotEmpty && _backStack.last == _items[target].id) {
        _backStack.removeLast();
      }
    } else if (from != null && target != _index) {
      _backStack.add(from.id);
      if (_backStack.length > _maxBackStack) _backStack.removeAt(0);
    }

    if (_shuffle) {
      // Round complete: start a new one with this track.
      if (!back && _playedRound.length >= _items.length) _playedRound.clear();
      _playedRound.add(_items[target].id);
    }
    _index = target;
  }

  int? _pickShuffled() {
    final unplayed = <int>[
      for (var i = 0; i < _items.length; i++)
        if (i != _index && !_playedRound.contains(_items[i].id)) i,
    ];
    if (unplayed.isNotEmpty) return unplayed[_random.nextInt(unplayed.length)];
    if (_repeat == PlaybackRepeat.off) return null;

    // Round finished and repeat is on: start a new round, avoiding the song
    // that just played when the queue has more than one track.
    final others = [
      for (var i = 0; i < _items.length; i++)
        if (i != _index) i,
    ];
    if (others.isEmpty) return _index;
    return others[_random.nextInt(others.length)];
  }
}
