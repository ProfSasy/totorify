import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/playback_queue.dart';

Song song(String id) => Song(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      thumbnailUrl: '',
    );

List<Song> songs(int n) => [for (var i = 0; i < n; i++) song('s$i')];

List<String> ids(PlaybackQueue queue) => [for (final s in queue.items) s.id];

/// Walks forward with peekNext/moveTo until the queue ends or [limit] moves.
List<String> walk(PlaybackQueue queue, {int limit = 100}) {
  final visited = <String>[];
  for (var i = 0; i < limit; i++) {
    final next = queue.peekNext();
    if (next == null) break;
    queue.moveTo(next);
    visited.add(queue.current!.id);
  }
  return visited;
}

void main() {
  group('replace', () {
    test('an empty queue has no current song and no neighbours', () {
      final queue = PlaybackQueue();
      expect(queue.current, isNull);
      expect(queue.index, -1);
      expect(queue.peekNext(), isNull);
      expect(queue.peekPrevious(), isNull);
    });

    test('points at the start song', () {
      final queue = PlaybackQueue()..replace(songs(4), song('s2'));
      expect(queue.index, 2);
      expect(queue.current!.id, 's2');
      expect(ids(queue), ['s0', 's1', 's2', 's3']);
    });

    test('inserts the start song on top when it is not in the list', () {
      final queue = PlaybackQueue()..replace(songs(2), song('x'));
      expect(ids(queue), ['x', 's0', 's1']);
      expect(queue.index, 0);
    });

    test('with an empty list the queue is the start song alone', () {
      final queue = PlaybackQueue()..replace(const [], song('x'));
      expect(ids(queue), ['x']);
      expect(queue.index, 0);
    });

    test('keeps shuffle and repeat, forgets where it came from', () {
      final queue = PlaybackQueue()
        ..setRepeat(PlaybackRepeat.all)
        ..replace(songs(3), song('s0'));
      queue.moveTo(queue.peekNext()!);
      queue.setShuffle(true);
      queue.replace(songs(3), song('s1'));
      expect(queue.shuffle, isTrue);
      expect(queue.repeat, PlaybackRepeat.all);
      expect(queue.peekPrevious(), isNull);
    });
  });

  group('adopt', () {
    test('keeps the current song current, found again by id', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.adopt([song('a'), song('b'), song('s1'), song('c')]);
      expect(queue.index, 2);
      expect(queue.current!.id, 's1');
    });

    test('follows the given currentId', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.adopt(songs(3), currentId: 's2');
      expect(queue.current!.id, 's2');
    });

    test('nothing is current when the current song is gone', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.adopt([song('a'), song('b')]);
      expect(queue.index, -1);
      expect(queue.current, isNull);
    });

    test('after the current song is gone the next move starts from the top', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.adopt([song('a'), song('b')]);
      expect(queue.peekNext(), 0);
      expect(queue.peekPrevious(), isNull);
      queue.moveTo(0);
      expect(queue.current!.id, 'a');
    });

    test('with shuffle on, the move after the current song is gone draws a song', () {
      final queue = PlaybackQueue(random: Random(4))..replace(songs(3), song('s1'));
      queue.setShuffle(true);
      queue.adopt([song('a'), song('b'), song('c')]);
      final visited = walk(queue);
      expect(visited.toSet(), {'a', 'b', 'c'});
      expect(visited, hasLength(3));
    });

    test('drops the removed songs from the way back', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s0'));
      queue.moveTo(1);
      queue.moveTo(2);
      queue.setShuffle(true);
      // s1 (the previous song) is not in the adopted list.
      queue.adopt([song('s0'), song('s2')]);
      expect(queue.current!.id, 's2');
      expect(queue.items[queue.peekPrevious()!].id, 's0');
    });
  });

  group('editing', () {
    test('appendUnique skips the ids already queued', () {
      final queue = PlaybackQueue()..replace(songs(2), song('s0'));
      final added = queue.appendUnique([song('s1'), song('n1'), song('n1'), song('n2')]);
      expect(added, 2);
      expect(ids(queue), ['s0', 's1', 'n1', 'n2']);
    });

    test('insertAfterCurrent puts the song right after the current one', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.insertAfterCurrent(song('x'));
      expect(ids(queue), ['s0', 's1', 'x', 's2']);
      expect(queue.current!.id, 's1');
      expect(queue.peekNext(), 2);
    });

    test('insertAfterCurrent on the last song appends', () {
      final queue = PlaybackQueue()..replace(songs(2), song('s1'));
      queue.insertAfterCurrent(song('x'));
      expect(ids(queue), ['s0', 's1', 'x']);
    });

    test('insertAt before the current song keeps it current', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.insertAt(0, song('x'));
      expect(queue.current!.id, 's1');
      expect(queue.index, 2);
      queue.insertAt(99, song('y'));
      expect(ids(queue).last, 'y');
      expect(queue.current!.id, 's1');
    });

    test('updateSong replaces the song with that id only', () {
      final queue = PlaybackQueue()..replace(songs(2), song('s0'));
      queue.updateSong('s1', (s) => s.copyWith(youtubeVideoId: 'yt'));
      expect(queue.items[1].youtubeVideoId, 'yt');
      expect(queue.items[0].youtubeVideoId, isNull);
    });

    test('removeAt before the current song shifts the index', () {
      final queue = PlaybackQueue()..replace(songs(4), song('s2'));
      expect(queue.removeAt(0), isFalse);
      expect(queue.index, 1);
      expect(queue.current!.id, 's2');
    });

    test('removeAt after the current song leaves the index', () {
      final queue = PlaybackQueue()..replace(songs(4), song('s1'));
      expect(queue.removeAt(3), isFalse);
      expect(queue.index, 1);
      expect(queue.current!.id, 's1');
    });

    test('removeAt on the current song points at the one taking its place', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      expect(queue.removeAt(1), isTrue);
      expect(queue.current!.id, 's2');
    });

    test('removeAt on the current, last song leaves nothing current', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s2'));
      expect(queue.removeAt(2), isTrue);
      expect(queue.index, -1);
      expect(queue.current, isNull);
    });

    test('removeAt out of range does nothing', () {
      final queue = PlaybackQueue()..replace(songs(2), song('s0'));
      expect(queue.removeAt(-1), isFalse);
      expect(queue.removeAt(2), isFalse);
      expect(ids(queue), ['s0', 's1']);
    });

    test('move follows the current song (ReorderableListView indices)', () {
      final queue = PlaybackQueue()..replace(songs(4), song('s0'));
      // Dragging the first row below the third one.
      queue.move(0, 3);
      expect(ids(queue), ['s1', 's2', 's0', 's3']);
      expect(queue.current!.id, 's0');
    });

    test('move across the current song keeps it current', () {
      final queue = PlaybackQueue()..replace(songs(4), song('s1'));
      queue.move(0, 4);
      expect(ids(queue), ['s1', 's2', 's3', 's0']);
      expect(queue.current!.id, 's1');
      queue.move(3, 0);
      expect(ids(queue), ['s0', 's1', 's2', 's3']);
      expect(queue.current!.id, 's1');
    });

    test('move out of range does nothing', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s1'));
      queue.move(7, 0);
      expect(ids(queue), ['s0', 's1', 's2']);
      expect(queue.index, 1);
    });

    test('keepOnlyCurrent drops everything else', () {
      final queue = PlaybackQueue()..replace(songs(4), song('s2'));
      queue.moveTo(3);
      queue.keepOnlyCurrent();
      expect(ids(queue), ['s3']);
      expect(queue.index, 0);
      expect(queue.peekNext(), isNull);
      expect(queue.peekPrevious(), isNull);
    });

    test('keepOnlyCurrent with no current song empties the queue', () {
      final queue = PlaybackQueue()..replace(songs(2), song('s1'));
      queue.removeAt(1);
      queue.keepOnlyCurrent();
      expect(queue.items, isEmpty);
      expect(queue.index, -1);
    });

    test('shuffleAfterCurrent mixes only what comes after', () {
      final queue = PlaybackQueue(random: Random(7))..replace(songs(12), song('s2'));
      queue.shuffleAfterCurrent();
      expect(ids(queue).take(3), ['s0', 's1', 's2']);
      expect(queue.current!.id, 's2');
      final after = ids(queue).skip(3).toList();
      expect(after.toSet(), {for (var i = 3; i < 12; i++) 's$i'});
      expect(after, isNot([for (var i = 3; i < 12; i++) 's$i']));
    });
  });

  group('navigation in order', () {
    test('repeat off: forward to the end, then nothing', () {
      final queue = PlaybackQueue()..replace(songs(3), song('s0'));
      expect(walk(queue), ['s1', 's2']);
      expect(queue.peekNext(), isNull);
    });

    test('repeat all wraps to the top', () {
      final queue = PlaybackQueue()
        ..setRepeat(PlaybackRepeat.all)
        ..replace(songs(3), song('s2'));
      expect(queue.peekNext(), 0);
    });

    test('repeat one does not change a manual skip', () {
      final queue = PlaybackQueue()
        ..setRepeat(PlaybackRepeat.one)
        ..replace(songs(3), song('s0'));
      expect(queue.peekNext(), 1);
      queue.moveTo(2);
      expect(queue.peekNext(), isNull);
      expect(queue.peekPrevious(), 1);
    });

    test('repeat all on a single song gives the song itself', () {
      final queue = PlaybackQueue()
        ..setRepeat(PlaybackRepeat.all)
        ..replace(songs(1), song('s0'));
      expect(queue.peekNext(), 0);
    });

    test('previous goes one up and stops at the top, also with repeat all', () {
      final queue = PlaybackQueue()
        ..setRepeat(PlaybackRepeat.all)
        ..replace(songs(3), song('s1'));
      expect(queue.peekPrevious(), 0);
      queue.moveTo(0, back: true);
      expect(queue.peekPrevious(), isNull);
    });
  });

  group('shuffle', () {
    test('plays every song once, then ends with repeat off', () {
      final queue = PlaybackQueue(random: Random(42))..replace(songs(8), song('s3'));
      queue.setShuffle(true);
      final visited = walk(queue);
      expect(visited, hasLength(7));
      expect(visited.toSet(), {for (var i = 0; i < 8; i++) 's$i'}..remove('s3'));
      expect(queue.peekNext(), isNull);
    });

    test('the same seed gives the same order', () {
      List<String> run() {
        final queue = PlaybackQueue(random: Random(1234))..replace(songs(10), song('s0'));
        queue.setShuffle(true);
        return walk(queue);
      }

      expect(run(), run());
    });

    test('the order is not the plain one', () {
      final queue = PlaybackQueue(random: Random(42))..replace(songs(10), song('s0'));
      queue.setShuffle(true);
      expect(walk(queue), isNot([for (var i = 1; i < 10; i++) 's$i']));
    });

    test('peekNext keeps returning the track it drew', () {
      final queue = PlaybackQueue(random: Random(5))..replace(songs(10), song('s0'));
      queue.setShuffle(true);
      final first = queue.peekNext();
      for (var i = 0; i < 5; i++) {
        expect(queue.peekNext(), first);
      }
    });

    test('repeat all starts a new round without repeating the last song', () {
      final queue = PlaybackQueue(random: Random(9))
        ..setRepeat(PlaybackRepeat.all)
        ..replace(songs(5), song('s0'));
      queue.setShuffle(true);
      final visited = ['s0', ...walk(queue, limit: 24)];
      expect(visited, hasLength(25));
      for (var i = 1; i < visited.length; i++) {
        expect(visited[i], isNot(visited[i - 1]));
      }
      // Each round of five holds every song once.
      for (var round = 0; round < 5; round++) {
        expect(visited.skip(round * 5).take(5).toSet(), hasLength(5));
      }
    });

    test('repeat all on a single song gives the song itself', () {
      final queue = PlaybackQueue(random: Random(1))
        ..setRepeat(PlaybackRepeat.all)
        ..replace(songs(1), song('s0'));
      queue.setShuffle(true);
      expect(queue.peekNext(), 0);
    });

    test('previous walks back through what was played', () {
      final queue = PlaybackQueue(random: Random(3))..replace(songs(8), song('s0'));
      queue.setShuffle(true);
      final visited = ['s0', ...walk(queue, limit: 3)];

      for (var i = visited.length - 2; i >= 0; i--) {
        final previous = queue.peekPrevious();
        expect(previous, isNotNull);
        queue.moveTo(previous!, back: true);
        expect(queue.current!.id, visited[i]);
      }
      expect(queue.peekPrevious(), isNull);
    });

    test('a song removed from the queue is never drawn', () {
      final queue = PlaybackQueue(random: Random(11))..replace(songs(6), song('s0'));
      queue.setShuffle(true);
      queue.removeAt(4);
      expect(walk(queue), isNot(contains('s4')));
    });

    test('turning shuffle off goes back to the plain order', () {
      final queue = PlaybackQueue(random: Random(2))..replace(songs(5), song('s0'));
      queue.setShuffle(true);
      queue.moveTo(queue.peekNext()!);
      queue.setShuffle(false);
      final at = queue.index;
      expect(queue.peekNext(), at < 4 ? at + 1 : isNull);
    });

    test('a song appended during the round is played in that round', () {
      final queue = PlaybackQueue(random: Random(8))..replace(songs(3), song('s0'));
      queue.setShuffle(true);
      queue.moveTo(queue.peekNext()!);
      queue.append(song('new'));
      expect(walk(queue), contains('new'));
    });
  });
}
