import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/audio_handler.dart';

void main() {
  const gainFor = AudioPlayerHandler.gainFor;

  test('an unknown loudness leaves the volume as it is', () {
    expect(gainFor(null), 1.0);
  });

  test('tracks at or below the reference are not raised', () {
    expect(gainFor(0), 1.0);
    expect(gainFor(-0.1), 1.0);
    expect(gainFor(-12), 1.0);
  });

  test('louder tracks are lowered by their decibels', () {
    expect(gainFor(6), closeTo(0.5012, 0.0001));
    expect(gainFor(3), closeTo(0.7079, 0.0001));
    expect(gainFor(0.5), closeTo(0.9441, 0.0001));
  });

  test('the louder the track, the lower the gain', () {
    final gains = [for (var db = 0.0; db <= 14; db += 0.5) gainFor(db)];
    for (var i = 1; i < gains.length; i++) {
      expect(gains[i], lessThan(gains[i - 1]));
    }
  });

  test('the gain never goes below the floor', () {
    expect(gainFor(14), closeTo(0.2, 0.001));
    expect(gainFor(20), 0.2);
    expect(gainFor(60), 0.2);
    expect(gainFor(double.infinity), 0.2);
  });

  test('the gain is never above full volume', () {
    for (var db = -30.0; db <= 30; db += 0.25) {
      expect(gainFor(db), inInclusiveRange(0.2, 1.0), reason: '$db dB');
    }
  });

  test('a loudness that is not a number does not become a volume', () {
    expect(gainFor(double.nan).isNaN, isFalse);
  });
}
