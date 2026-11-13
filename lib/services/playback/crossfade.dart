import 'dart:async';

import '../playback_log_service.dart';
import 'player_backend.dart';

/// What the crossfade needs from the audio handler.
abstract interface class CrossfadeHost {
  /// Length of the fade chosen by the user, in seconds; 0 turns it off.
  int get crossfadeSeconds;

  /// False when the track must end by itself: another device is playing,
  /// the end of the track was already handled, the track repeats, the sleep
  /// timer waits for its end, or the user paused.
  bool get mayFadeToNext;

  Duration get trackDuration;

  /// Index of the track that follows, or null at the end of the queue.
  int? peekNext();

  /// The player of the current track.
  PlayerBackend? get player;

  /// How loud the current player plays, the fade included.
  double get playerVolume;

  /// The current player starts to fade out: it is no longer the player
  /// (what it reports is not published, the next load does not silence it)
  /// and the end of its track is not reported.
  void releasePlayerToFade();

  /// Sets [playerVolume] on the current player.
  void applyPlayerVolume();

  /// Loads and plays the track at [index].
  void playIndex(int index);

  void disposePlayer(PlayerBackend player);
}

/// Near the end of a track, with crossfade on, starts the next one while
/// this one goes on: this one fades out as the other fades in.
class CrossfadeController {
  CrossfadeController(this._host);

  final CrossfadeHost _host;

  // The player of the song fading out while the next one fades in, and how
  // loud it was when it started to fade.
  PlayerBackend? _fadingOut;
  double _fadingOutVolume = 0;
  Timer? _fadeTimer;
  // True while the load of the song coming in is being started by the
  // crossfade itself: any other load ends the crossfade at once.
  bool _starting = false;

  /// The level of the song coming in, from 0 to 1 (1 when nothing fades).
  double get fadeIn => _fadeIn;
  double _fadeIn = 1.0;

  /// True while a song is fading out.
  bool get isFading => _fadingOut != null;

  /// Called a few times a second with the position of the current track.
  void maybeStart(Duration position) {
    final seconds = _host.crossfadeSeconds;
    if (seconds <= 0 || _fadingOut != null || !_host.mayFadeToNext) return;
    final trackDuration = _host.trackDuration;
    // A short track would be all fade.
    if (trackDuration < Duration(seconds: seconds * 3)) return;
    if (position < trackDuration - Duration(seconds: seconds)) return;
    final next = _host.peekNext();
    final old = _host.player;
    if (next == null || old == null) return;

    PlaybackLogService.instance.log('FADE', 'dissolvenza di ${seconds}s verso il prossimo brano');
    _fadingOutVolume = _host.playerVolume;
    _fadingOut = old;
    _host.releasePlayerToFade();
    _fadeIn = 0.0;
    _starting = true;
    _host.playIndex(next);
  }

  /// A load begins: the one the crossfade asked for goes on with it, any
  /// other ends the crossfade.
  void onLoadStarting() {
    if (_starting) {
      _starting = false;
    } else {
      finish();
    }
  }

  /// The song coming in has started to play: the levels begin to move.
  void startRamp() {
    final total = _host.crossfadeSeconds * 1000;
    final started = DateTime.now();
    final old = _fadingOut;
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final level = total <= 0
          ? 1.0
          : (DateTime.now().difference(started).inMilliseconds / total).clamp(0.0, 1.0);
      _fadeIn = level;
      _host.applyPlayerVolume();
      if (old != null) {
        unawaited(old.setVolume(_fadingOutVolume * (1 - level)).catchError((_) {}));
      }
      if (level >= 1) finish();
    });
  }

  /// Ends a crossfade at once: the song fading out stops, the one coming in
  /// plays at its full volume.
  void finish() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final old = _fadingOut;
    _fadingOut = null;
    _starting = false;
    if (_fadeIn != 1.0) {
      _fadeIn = 1.0;
      _host.applyPlayerVolume();
    }
    if (old != null) _host.disposePlayer(old);
  }
}
