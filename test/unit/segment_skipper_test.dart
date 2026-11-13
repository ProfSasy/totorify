import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/playback/segment_skipper.dart';
import 'package:kreate_ios/services/playback/sleep_timer.dart';
import 'package:kreate_ios/services/sponsor_block_service.dart';

Duration s(int seconds) => Duration(seconds: seconds);

class Rig {
  Rig(this.segments) {
    skipper = SegmentSkipper(
      fetchSegments: (videoId) async => segments,
      currentGeneration: () => generation,
      canSkip: () => canSkip,
      trackDuration: () => trackDuration,
      seek: (position) async => seeks.add(position),
      endTrack: () => ended++,
      reportInfo: infos.add,
    );
  }

  final List<SkipSegment> segments;
  late final SegmentSkipper skipper;
  int generation = 1;
  bool canSkip = true;
  Duration trackDuration = s(200);
  final List<Duration> seeks = [];
  final List<String> infos = [];
  int ended = 0;
}

void main() {
  SkipSegment segment(int start, int end, [String category = 'music_offtopic']) =>
      SkipSegment(s(start), s(end), category);

  group('SegmentSkipper', () {
    test('jumps to the end of the part the position is in, once', () async {
      final rig = Rig([segment(10, 25)]);
      await rig.skipper.load('v', 1);

      rig.skipper.skipAt(s(5));
      expect(rig.seeks, isEmpty);
      rig.skipper.skipAt(s(12));
      rig.skipper.skipAt(s(13));
      expect(rig.seeks, [s(25)]);
      expect(rig.infos, ['Saltata una parte non musicale']);
    });

    test('a part that runs to the end of the track ends it', () async {
      final rig = Rig([segment(190, 199)]);
      await rig.skipper.load('v', 1);
      rig.skipper.skipAt(s(191));
      expect(rig.ended, 1);
      expect(rig.seeks, isEmpty);
    });

    test('a part the user moved into is not skipped', () async {
      final rig = Rig([segment(10, 25), segment(60, 70)]);
      await rig.skipper.load('v', 1);
      rig.skipper.markEntered(s(15));
      rig.skipper.skipAt(s(16));
      expect(rig.seeks, isEmpty);
      rig.skipper.skipAt(s(61));
      expect(rig.seeks, [s(70)]);
    });

    test('nothing is skipped while a seek or a load is in flight', () async {
      final rig = Rig([segment(10, 25)]);
      await rig.skipper.load('v', 1);
      rig.canSkip = false;
      rig.skipper.skipAt(s(12));
      expect(rig.seeks, isEmpty);
      rig.canSkip = true;
      rig.skipper.skipAt(s(12));
      expect(rig.seeks, [s(25)]);
    });

    test('the parts of a superseded load are dropped', () async {
      final rig = Rig([segment(10, 25)]);
      final loading = rig.skipper.load('old', 1);
      rig.generation = 2;
      await loading;
      rig.skipper.skipAt(s(12));
      expect(rig.seeks, isEmpty);
    });

    test('reset forgets the parts of the previous track', () async {
      final rig = Rig([segment(10, 25)]);
      await rig.skipper.load('v', 1);
      rig.skipper.reset();
      rig.skipper.skipAt(s(12));
      expect(rig.seeks, isEmpty);
    });
  });

  group('SleepTimerController', () {
    test('end of track: active, named, and fires nothing by itself', () {
      var elapsed = 0;
      final timer = SleepTimerController(onElapsed: () => elapsed++);
      timer.set(null, endOfTrack: true);
      expect(timer.isActive, isTrue);
      expect(timer.endOfTrack, isTrue);
      expect(timer.notifier.value, 'Fine brano');
      timer.cancel();
      expect(timer.isActive, isFalse);
      expect(timer.notifier.value, isNull);
      expect(elapsed, 0);
    });

    test('a duration fires once and turns itself off', () async {
      var elapsed = 0;
      final timer = SleepTimerController(onElapsed: () => elapsed++);
      timer.set(const Duration(milliseconds: 20));
      expect(timer.isActive, isTrue);
      expect(timer.notifier.value, '0 min');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(elapsed, 1);
      expect(timer.isActive, isFalse);
      expect(timer.notifier.value, isNull);
    });

    test('cancel and a null duration stop a running timer', () async {
      var elapsed = 0;
      final timer = SleepTimerController(onElapsed: () => elapsed++);
      timer.set(const Duration(milliseconds: 20));
      timer.cancel();
      timer.set(const Duration(milliseconds: 20));
      timer.set(null);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(elapsed, 0);
      expect(timer.isActive, isFalse);
    });
  });
}
