import 'dart:async';

import 'package:flutter/foundation.dart';

/// Pauses the playback after a while, or at the end of the current track.
class SleepTimerController {
  SleepTimerController({required this.onElapsed});

  /// Called when the time is up.
  final void Function() onElapsed;

  Timer? _timer;

  /// True while the playback is to stop at the end of the current track.
  bool get endOfTrack => _endOfTrack;
  bool _endOfTrack = false;

  /// What the timer waits for ("30 min", "Fine brano"), or null when off.
  final ValueNotifier<String?> notifier = ValueNotifier<String?>(null);

  bool get isActive => _timer != null || _endOfTrack;

  void set(Duration? duration, {bool endOfTrack = false}) {
    _timer?.cancel();
    _timer = null;
    _endOfTrack = endOfTrack;

    if (endOfTrack) {
      notifier.value = 'Fine brano';
      return;
    }

    if (duration != null) {
      final minutes = duration.inMinutes;
      notifier.value = '$minutes min';
      _timer = Timer(duration, () {
        onElapsed();
        _timer = null;
        _endOfTrack = false;
        notifier.value = null;
      });
    } else {
      notifier.value = null;
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _endOfTrack = false;
    notifier.value = null;
  }
}
