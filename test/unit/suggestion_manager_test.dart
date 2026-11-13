import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/playback/suggestions.dart';
import 'package:kreate_ios/services/playback_queue.dart';

Song track(String id, {String? title, String artist = 'Artist'}) => Song(
      id: id,
      title: title ?? 'Title $id',
      artist: artist,
      duration: const Duration(minutes: 3),
      thumbnailUrl: '',
    );

class Fixture {
  Fixture(List<Song> queued, {this.recommended = const []}) {
    queue.replace(queued, queued.first);
    manager = SuggestionManager(
      queue: queue,
      recommend: (seed, {youtubeSeedId}) async {
        seeds.add((seed.id, youtubeSeedId));
        return recommended;
      },
      youtubeSeedFor: (song) => 'yt-${song.id}',
      enableShuffle: () async {
        shuffleEnabled++;
        queue.setShuffle(true);
      },
      onQueueChanged: () => queueChanges++,
    );
  }

  final PlaybackQueue queue = PlaybackQueue();
  List<Song> recommended;
  late final SuggestionManager manager;
  final List<(String, String?)> seeds = [];
  int shuffleEnabled = 0;
  int queueChanges = 0;

  List<String> get ids => [for (final s in queue.items) s.id];
}

void main() {
  group('fresh', () {
    test('asks for the seed with its YouTube video', () async {
      final f = Fixture([track('a')], recommended: [track('r1')]);
      await f.manager.fresh(track('a'));
      expect(f.seeds, [('a', 'yt-a')]);
    });

    test('leaves out the songs already in the queue, by id', () async {
      final f = Fixture(
        [track('a'), track('b')],
        recommended: [track('b'), track('r1'), track('a'), track('r2')],
      );
      final fresh = await f.manager.fresh(track('a'));
      expect([for (final s in fresh) s.id], ['r1', 'r2']);
    });

    test('leaves out the same track coming from another catalog', () async {
      final f = Fixture(
        [track('spotify_1', title: 'Blinding Lights', artist: 'The Weeknd')],
        recommended: [
          track('yt1', title: 'Blinding Lights (Official Audio)', artist: 'The Weeknd - Topic'),
          track('r1', title: 'Save Your Tears', artist: 'The Weeknd'),
        ],
      );
      final fresh = await f.manager.fresh(f.queue.current!);
      expect([for (final s in fresh) s.id], ['r1']);
    });

    test('a recommendation given twice is offered once', () async {
      final f = Fixture(
        [track('a')],
        recommended: [
          track('r1', title: 'Song', artist: 'X'),
          track('r2', title: 'SONG', artist: 'x'),
        ],
      );
      final fresh = await f.manager.fresh(track('a'));
      expect([for (final s in fresh) s.id], ['r1']);
    });

    test('forCurrent respects the limit and needs a current song', () async {
      final f = Fixture(
        [track('a')],
        recommended: [for (var i = 0; i < 10; i++) track('r$i')],
      );
      expect(await f.manager.forCurrent(limit: 4), hasLength(4));
      f.queue.removeAt(0);
      expect(await f.manager.forCurrent(), isEmpty);
    });
  });

  group('Smart Shuffle', () {
    List<Song> own(int n) => [for (var i = 0; i < n; i++) track('s$i')];

    test('turning it on enables shuffle and queues three recommendations ahead', () async {
      final f = Fixture(own(10), recommended: [for (var i = 0; i < 8; i++) track('r$i')]);
      await f.manager.setSmartShuffle(true);

      expect(f.shuffleEnabled, 1);
      expect(f.manager.smartShuffleNotifier.value, isTrue);
      // After the current track at +2, +5 and +8.
      expect(f.ids.indexOf('r0'), 2);
      expect(f.ids.indexOf('r1'), 5);
      expect(f.ids.indexOf('r2'), 8);
      expect(f.ids, isNot(contains('r3')));
      expect(f.manager.suggestedIdsNotifier.value, {'r0', 'r1', 'r2'});
      expect(f.queue.current!.id, 's0');
      expect(f.queueChanges, 1);
    });

    test('turning it on twice does nothing more', () async {
      final f = Fixture(own(10), recommended: [for (var i = 0; i < 8; i++) track('r$i')]);
      await f.manager.setSmartShuffle(true);
      await f.manager.setSmartShuffle(true);
      expect(f.shuffleEnabled, 1);
      expect(f.ids, hasLength(13));
    });

    test('a played recommendation makes room for another', () async {
      final f = Fixture(own(10), recommended: [for (var i = 0; i < 8; i++) track('r$i')]);
      await f.manager.setSmartShuffle(true);
      await f.manager.topUp();
      expect(f.ids, hasLength(13));

      f.queue.moveTo(f.ids.indexOf('r0'));
      f.manager.markPlayed('r0');
      await f.manager.topUp();
      expect(f.ids, hasLength(14));
      expect(f.manager.suggestedIdsNotifier.value, hasLength(4));
    });

    test('the budget is about one recommendation every three own tracks', () async {
      // Three own tracks: the minimum budget of three.
      final f = Fixture(own(3), recommended: [for (var i = 0; i < 20; i++) track('r$i')]);
      await f.manager.setSmartShuffle(true);
      for (var round = 0; round < 6; round++) {
        final pending = f.ids.firstWhere((id) => id.startsWith('r') && id != f.queue.current!.id,
            orElse: () => '');
        if (pending.isEmpty) break;
        f.queue.moveTo(f.ids.indexOf(pending));
        f.manager.markPlayed(pending);
        await f.manager.topUp();
      }
      expect(f.ids.where((id) => id.startsWith('r')), hasLength(3));
    });

    test('turning it off drops the recommendations not played yet', () async {
      final f = Fixture(own(10), recommended: [for (var i = 0; i < 8; i++) track('r$i')]);
      await f.manager.setSmartShuffle(true);
      f.queue.moveTo(f.ids.indexOf('r0'));
      f.manager.markPlayed('r0');

      await f.manager.setSmartShuffle(false);
      // The one playing stays, and is still marked as a recommendation.
      expect(f.ids.where((id) => id.startsWith('r')), ['r0']);
      expect(f.queue.current!.id, 'r0');
      expect(f.manager.suggestedIdsNotifier.value, {'r0'});
      expect(f.manager.smartShuffleNotifier.value, isFalse);
    });

    test('nothing is added while it is off', () async {
      final f = Fixture(own(10), recommended: [track('r0')]);
      f.manager.resetBudget();
      await f.manager.topUp();
      expect(f.ids, hasLength(10));
      expect(f.seeds, isEmpty);
    });

    test('recommendations for a track that is no longer current are dropped', () async {
      final f = Fixture(own(10), recommended: [track('r0')]);
      f.manager.smartShuffleNotifier.value = true;
      f.manager.resetBudget();
      final pending = f.manager.topUp();
      f.queue.moveTo(3);
      await pending;
      expect(f.ids, isNot(contains('r0')));
    });

    test('syncWithQueue forgets the recommendations removed from the queue', () async {
      final f = Fixture(own(10), recommended: [for (var i = 0; i < 8; i++) track('r$i')]);
      await f.manager.setSmartShuffle(true);
      f.queue.removeAt(f.ids.indexOf('r1'));
      f.manager.syncWithQueue();
      expect(f.manager.suggestedIdsNotifier.value, {'r0', 'r2'});
    });

    test('a failing source of recommendations is not an error', () async {
      final f = Fixture(own(4));
      final manager = SuggestionManager(
        queue: f.queue,
        recommend: (seed, {youtubeSeedId}) async => throw StateError('offline'),
        youtubeSeedFor: (_) => null,
        enableShuffle: () async {},
        onQueueChanged: () {},
      );
      await manager.setSmartShuffle(true);
      expect(f.ids, hasLength(4));
      // The next change of track tries again.
      await manager.topUp();
    });
  });
}
