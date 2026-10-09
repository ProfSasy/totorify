import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'storage_service.dart';
import 'ytmusic_service.dart';
import 'playback_log_service.dart';

class ScoredTrackMatch {
  final Song song;
  final int score;
  final int durationDiffSeconds;
  final String qualityLabel;
  final bool isTopicOrOfficial;

  ScoredTrackMatch({
    required this.song,
    required this.score,
    required this.durationDiffSeconds,
    required this.qualityLabel,
    required this.isTopicOrOfficial,
  });
}

class TrackMatcherService {
  TrackMatcherService._internal();
  static final TrackMatcherService instance = TrackMatcherService._internal();

  static final RegExp _parentheticalRegex = RegExp(r'\s*[\(\[][^\)\]]*[\)\]]');
  static final RegExp _featRegex = RegExp(r'\s*(feat\.?|ft\.?|featuring)\s+.*', caseSensitive: false);
  // Unicode classes on purpose: \w is ASCII-only in Dart, so it erased
  // every non-Latin title down to an empty string.
  static final RegExp _nonAlphaNumRegex = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

  // Versions that are not the track asked for. Matched as whole words:
  // "live" must not fire on "Deliver" or "Olive".
  static final Map<String, RegExp> _wrongVariants = {
    for (final word in const ['live', 'cover', 'sped up', 'slowed'])
      word: RegExp('\\b$word\\b'),
  };

  // Larger than every bonus combined: a candidate with an unrelated title
  // never outranks one with the right title, whatever its duration.
  static const int _unrelatedTitlePenalty = 20000;
  // Scores at or below this come from an unrelated title.
  static const int _unrelatedScore = -5000;

  String _canonicalTitle(String title) {
    return title
        .replaceAll(_parentheticalRegex, '')
        .replaceAll(_featRegex, '')
        .replaceAll(_nonAlphaNumRegex, '')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _canonicalArtist(String artist) {
    return artist
        .split(RegExp(r'\s*[,;&/]\s*|\s+(?:and|&)\s+', caseSensitive: false))
        .map((e) => e.replaceAll(_parentheticalRegex, '').replaceAll(_nonAlphaNumRegex, '').toLowerCase().trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
  }

  bool _titleMatches(String target, String candidate) {
    // If the candidate doesn't even share the main word of the target, it's garbage.
    if (candidate.isEmpty) return false;
    final targetWords = target.split(' ').where((w) => w.length > 2).toList();
    if (targetWords.isEmpty) return true; // too short to filter

    final candidateLower = candidate.toLowerCase();
    for (final w in targetWords) {
      if (candidateLower.contains(w)) return true;
    }
    return false;
  }

  int scoreCandidate(Song candidate, Song target) {
    int score = 0;
    final targetTitle = _canonicalTitle(target.title);
    final candTitle = _canonicalTitle(candidate.title);

    // Duration is the strongest signal, but only when both are known: an
    // unknown duration is no evidence and earns nothing.
    if (target.duration.inSeconds > 0 && candidate.duration.inSeconds > 0) {
      final diff = (target.duration.inSeconds - candidate.duration.inSeconds).abs();
      if (diff == 0) {
        score += 10000;
      } else if (diff <= 2) {
        score += 5000;
      } else if (diff <= 5) {
        score += 2000;
      } else if (diff <= 10) {
        score += 500;
      } else {
        score -= diff * 50; // Penalize heavy duration differences
      }
    }

    // Title match. An empty title (nothing but symbols) is related to
    // nothing: String.contains('') is always true and must not count.
    final comparable = candTitle.isNotEmpty && targetTitle.isNotEmpty;
    if (comparable && candTitle == targetTitle) {
      score += 2000;
    } else if (comparable &&
        (candTitle.contains(targetTitle) || targetTitle.contains(candTitle))) {
      score += 500;
    } else if (_titleMatches(targetTitle, candTitle)) {
      score += 100;
    } else {
      // Not discarded outright (a weak match beats no playback), but ranked
      // below every candidate with a related title.
      score -= _unrelatedTitlePenalty;
    }

    // Official/Topic bonus
    if (candidate.artist.toLowerCase().contains('- topic')) score += 300;
    if (candidate.title.toLowerCase().contains('official audio')) score += 300;

    // Penalty for wrong variants (live, cover)
    final lowerCand = '${candidate.title} ${candidate.artist}'.toLowerCase();
    final lowerTarget = target.title.toLowerCase();
    for (final variant in _wrongVariants.entries) {
      if (variant.value.hasMatch(lowerCand) && !variant.value.hasMatch(lowerTarget)) {
        score -= 2000;
      }
    }

    return score;
  }

  (Song, int)? _bestOf(List<Song> candidates, Song target) {
    (Song, int)? best;
    for (final candidate in candidates) {
      final score = scoreCandidate(candidate, target);
      if (best == null || score > best.$2) best = (candidate, score);
    }
    return best;
  }

  /// Catalog ids (Spotify, Apple, Deezer) carry metadata only and must be
  /// matched to a YouTube video; any other id already is a YouTube video id.
  static bool needsResolution(String id) =>
      id.startsWith('spotify_') || id.startsWith('itunes_') || id.startsWith('deezer_');

  bool _isVideoId(String? id) => id != null && id.isNotEmpty && !needsResolution(id);

  /// YouTube video id to play for [song], or null when none can be found
  /// (no results or no network).
  Future<String?> resolveAndCacheStreamId(Song song) async {
    if (!needsResolution(song.id)) {
      return song.id;
    }

    // A stored value is used only if it really is a video id: older
    // versions could save the catalog id itself here after a failed match.
    if (_isVideoId(song.youtubeVideoId)) return song.youtubeVideoId;

    final cached = StorageService.instance.getCachedYouTubeMapping(song.id);
    if (_isVideoId(cached)) return cached;

    try {
      final cleanTitle = _canonicalTitle(song.title);
      final cleanArtist = _canonicalArtist(song.artist).split(',').first;

      // YouTube Music first: its results are studio tracks, not Vevo videos.
      var best = _bestOf(
        await YTMusicService.instance.search('$cleanTitle $cleanArtist'),
        song,
      );

      // Nothing, or nothing with the right title: widen to plain YouTube.
      if (best == null || best.$2 <= _unrelatedScore) {
        final wider = _bestOf(
          await YTMusicService.instance.explodeSearch('${song.title} ${song.artist} audio'),
          song,
        );
        if (wider != null && (best == null || wider.$2 > best.$2)) best = wider;
      }

      if (best == null) return null;

      PlaybackLogService.instance.log('MATCHER', 'Match Trovato per ${song.title}: ${best.$1.title} (Score: ${best.$2})');
      // A last-resort match with an unrelated title is played but not
      // remembered, so a better one can be found next time.
      if (best.$2 > _unrelatedScore) {
        await StorageService.instance.cacheYouTubeMapping(song.id, best.$1.id);
      }
      return best.$1.id;
    } catch (e) {
      debugPrint('TrackMatcherService.resolveAndCacheStreamId: $e');
      return null;
    }
  }

  Future<List<ScoredTrackMatch>> getAlternativeMatches(Song targetSong, {int limit = 12}) async {
      try {
        final cleanTitle = _canonicalTitle(targetSong.title);
        final cleanArtist = _canonicalArtist(targetSong.artist).split(',').first;
        final query = '$cleanTitle $cleanArtist';

        final results = await YTMusicService.instance.search(query);
        final explode = await YTMusicService.instance.explodeSearch('$query audio');

        final allCandidates = <String, Song>{};
        for (final r in [...results, ...explode]) {
          allCandidates[r.id] = r;
        }

        final scoredList = <ScoredTrackMatch>[];

        for (final candidate in allCandidates.values) {
          final score = scoreCandidate(candidate, targetSong);
          final diff = targetSong.duration > Duration.zero && candidate.duration > Duration.zero
              ? (candidate.duration.inSeconds - targetSong.duration.inSeconds).abs()
              : 0;

          String label;
          if (diff <= 3 && score >= 300) {
            label = 'Match Perfetto (±${diff}s)';
          } else if (diff <= 8 && score >= 100) {
            label = 'Ottimo (±${diff}s)';
          } else if (diff <= 15) {
            label = 'Buono (±${diff}s)';
          } else {
            label = 'Fonte Alternativa (+${diff}s)';
          }

          scoredList.add(ScoredTrackMatch(
            song: candidate,
            score: score,
            durationDiffSeconds: diff,
            qualityLabel: label,
            isTopicOrOfficial: candidate.artist.toLowerCase().contains('- topic'),
          ));
        }

        scoredList.sort((a, b) => b.score.compareTo(a.score));
        return scoredList.take(limit).toList();
      } catch (e) {
        debugPrint('TrackMatcherService.getAlternativeMatches: $e');
        return [];
      }
  }
}
