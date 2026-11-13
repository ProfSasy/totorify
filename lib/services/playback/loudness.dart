import 'dart:async';
import 'dart:math';

/// Lowers the tracks that are louder than YouTube's reference, so that
/// every track sounds as loud as the others.
class LoudnessNormalizer {
  LoudnessNormalizer({
    required this.isEnabled,
    required this.knownLoudness,
    required this.fetchLoudness,
    required this.currentGeneration,
    required this.currentVideoId,
    required this.onGainChanged,
  });

  /// Whether the user wants the volume normalized.
  final bool Function() isEnabled;

  /// The loudness of a video whose streams were already looked up, or null
  /// when they were not. A known video can still have no loudness.
  final ({double? loudnessDb})? Function(String videoId) knownLoudness;

  /// Asks for the loudness of a video.
  final Future<double?> Function(String videoId) fetchLoudness;

  /// The load in progress: an answer for an older one is dropped.
  final int Function() currentGeneration;

  /// The YouTube video that is playing, when there is one.
  final String? Function() currentVideoId;

  /// Called when [gain] changes, to apply it to the player.
  final void Function() onGainChanged;

  /// How much the current track is lowered (1 = not at all).
  double get gain => _gain;
  double _gain = 1.0;

  /// How much a track [loudnessDb] louder than YouTube's reference is
  /// lowered. Quieter ones are left as they are: the player cannot go above
  /// full volume.
  static double gainFor(double? loudnessDb) {
    if (loudnessDb == null || loudnessDb <= 0) return 1.0;
    return pow(10, -loudnessDb / 20).toDouble().clamp(0.2, 1.0);
  }

  void setGain(double gain) {
    if (gain == _gain) return;
    _gain = gain;
    onGainChanged();
  }

  /// Sets the gain for [videoId], loaded as [generation].
  Future<void> apply(String videoId, int generation) async {
    if (!isEnabled()) {
      setGain(1.0);
      return;
    }
    final known = knownLoudness(videoId);
    // Known already (the streams were just looked up): set before playing.
    if (known != null) {
      setGain(gainFor(known.loudnessDb));
      return;
    }
    final db = await fetchLoudness(videoId);
    if (generation != currentGeneration()) return;
    setGain(gainFor(db));
  }

  /// The user turned the normalization on or off.
  void onSettingChanged() {
    final videoId = currentVideoId();
    if (videoId == null) return;
    unawaited(apply(videoId, currentGeneration()));
  }
}
