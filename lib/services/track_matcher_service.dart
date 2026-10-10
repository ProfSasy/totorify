import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'storage_service.dart';
import 'ytmusic_catalog_service.dart';
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
    for (final word in const [
      'live',
      'cover',
      'sped up',
      'speed up',
      'slowed',
      'reverb',
      'nightcore',
      '8d',
      '8 bit',
      '8bit',
      'karaoke',
      'instrumental',
      'strumentale',
      'remix',
      'mashup',
      'acoustic',
      'acustica',
      'acustico',
      'piano',
      'violin',
      'hypertechno',
      'tribute',
      'made popular',
      'originally performed',
      'in the style of',
      'bass boosted',
      'lofi',
      'parody',
      'parodia',
    ])
      word: RegExp('\\b$word\\b'),
  };

  // Larger than every bonus combined: a candidate with an unrelated title
  // never outranks one with the right title, whatever its duration.
  static const int _unrelatedTitlePenalty = 20000;
  // Scores at or below this come from an unrelated title.
  static const int _unrelatedScore = -5000;
  // Below this the best candidate is doubtful (another artist, another
  // length): worth looking further.
  static const int _weakScore = 4500;

  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _channelSuffix =
      RegExp(r'(\s*-\s*topic|\s*vevo|\s+official)$', caseSensitive: false);
  static final RegExp _artistSeparators = RegExp(
    r'\s*[,;&/]\s*|\s+(?:x|e|and|feat\.?|ft\.?|featuring|con|with)\s+',
    caseSensitive: false,
  );
  static final RegExp _bracketed = RegExp(r'[\(\[]([^\)\]]*)[\)\]]');
  // "(feat. X)", "(con X)", "[prod. Y]": credits, not a different version.
  static final RegExp _credit = RegExp(
    r'^\s*(feat\.?|ft\.?|featuring|con|with|prod\.?|produced)\b',
    caseSensitive: false,
  );
  static final RegExp _digits = RegExp(r'^\d+$');

  // Words an upload adds to a title without making it another version.
  static const Set<String> _neutralWords = {
    'official', 'ufficiale', 'audio', 'video', 'videoclip', 'music', 'musicale',
    'testo', 'lyrics', 'lyric', 'visual', 'visualizer', 'hd', 'hq', '4k',
    'explicit', 'remaster', 'remastered', 'mono', 'stereo', 'album', 'single',
    'original', 'originale', 'version', 'versione', 'prod', 'ft', 'feat',
    'con', 'with', 'by', 'di', 'e', 'x',
  };

  static const Map<String, String> _accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ç': 'c', 'ñ': 'n', 'ß': 'ss',
  };
  static final RegExp _accented = RegExp('[${_accents.keys.join()}]');

  /// Catalogs disagree on accents ("Beyoncé", "Beyonce"): compare without.
  static String _fold(String text) =>
      text.toLowerCase().replaceAllMapped(_accented, (m) => _accents[m.group(0)]!);

  /// Lowercase words only: punctuation becomes a space.
  static String _plain(String text) =>
      _fold(text).replaceAll(_nonAlphaNumRegex, ' ').replaceAll(_spaces, ' ').trim();

  /// True when [phrase] appears in [text] as whole words.
  static bool _hasPhrase(String text, String phrase) =>
      phrase.isNotEmpty && ' $text '.contains(' $phrase ');

  String _canonicalTitle(String title) {
    return _fold(title
            .replaceAll(_parentheticalRegex, '')
            .replaceAll(_featRegex, '')
            .replaceAll(_nonAlphaNumRegex, ''))
        .replaceAll(_spaces, ' ')
        .trim();
  }

  /// Every artist credited on [song], main one first: the artist field plus
  /// the names in a "(feat. X)" of the title.
  List<String> _artistsOf(Song song) {
    final names = <String>[
      ...song.artist.replaceAll(_channelSuffix, '').split(_artistSeparators),
      for (final match in _bracketed.allMatches(song.title))
        if (_credit.hasMatch(match.group(1)!))
          ...match.group(1)!.replaceFirst(_credit, '').split(_artistSeparators),
    ];
    final seen = <String>{};
    return [
      for (final name in names)
        if (_plain(name).isNotEmpty && seen.add(_plain(name))) _plain(name),
    ];
  }

  static const Set<String> _unknownArtists = {'artista', 'artista sconosciuto', 'unknown'};

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
    // Nothing to compare by ("J$ JP" has no word of three letters): the
    // exact and contained-title checks have already had their say, and
    // anything else must not pass for a match.
    if (targetWords.isEmpty) return false;

    final candidateLower = candidate.toLowerCase();
    for (final w in targetWords) {
      if (candidateLower.contains(w)) return true;
    }
    return false;
  }

  /// How well [candidate] (a YouTube result) is the recording [target].
  /// Title, artist and length weigh the same: a track is trusted only when
  /// all three agree, so a cover with the exact length does not beat the
  /// original that is a few seconds off. [fromMusicCatalog] marks a result
  /// of YouTube Music's song search, which lists studio tracks.
  int scoreCandidate(Song candidate, Song target, {bool fromMusicCatalog = false}) {
    int score = 0;
    final targetTitle = _canonicalTitle(target.title);
    final candTitle = _canonicalTitle(candidate.title);
    final artists = _artistsOf(target);
    final candArtist = _plain(candidate.artist.replaceAll(_channelSuffix, ''));
    final candText = _plain(candidate.title);

    // Length, only when both are known: an unknown one is no evidence.
    if (target.duration.inSeconds > 0 && candidate.duration.inSeconds > 0) {
      final diff = (target.duration.inSeconds - candidate.duration.inSeconds).abs();
      if (diff <= 2) {
        score += 3000;
      } else if (diff <= 5) {
        score += 2500;
      } else if (diff <= 10) {
        score += 1200;
      } else if (diff > 20) {
        score -= diff * 50 > 4000 ? 4000 : diff * 50;
      }
    }

    // Title. An upload often reads "Artist - Title (Audio)": compared again
    // without the artist names and the filler words. An empty title (nothing
    // but symbols) is related to nothing.
    final comparable = candTitle.isNotEmpty && targetTitle.isNotEmpty;
    var core = candTitle;
    for (final artist in artists) {
      core = ' $core '.replaceAll(' $artist ', ' ').trim();
    }
    core = core.split(' ').where((w) => !_neutralWords.contains(w)).join(' ');

    if (comparable && candTitle == targetTitle) {
      score += 3000;
    } else if (comparable && core == targetTitle) {
      score += 2600;
    } else if (comparable && _hasPhrase(candTitle, targetTitle)) {
      // The title plus other words: possibly another song ("Collane e
      // bugie" for "Bugie").
      score += 800;
    } else if (comparable && _hasPhrase(targetTitle, candTitle)) {
      score += 300;
    } else if (_titleMatches(targetTitle, candTitle)) {
      score += 100;
    } else {
      // Kept in the list (the sources sheet shows it), but ranked
      // below every candidate with a related title.
      score -= _unrelatedTitlePenalty;
    }

    // Artist: the same title by someone else is a cover or another song.
    // On plain YouTube the channel can be anyone, so the artist named in the
    // title counts too; in the music catalog the artist field is the real
    // one, and a title that names the artist is a tribute ("Halo (Beyoncé)").
    if (artists.isNotEmpty && !_unknownArtists.contains(artists.first)) {
      final named = fromMusicCatalog ? '' : candText;
      if (_hasPhrase(candArtist, artists.first)) {
        score += 3000;
      } else if (_hasPhrase(named, artists.first)) {
        score += 2000;
      } else if (artists.skip(1).any((a) => _hasPhrase(candArtist, a) || _hasPhrase(named, a))) {
        score += 1000;
      } else {
        score -= 3000;
      }
    }

    // Studio tracks first.
    if (fromMusicCatalog) score += 500;
    if (candidate.artist.toLowerCase().contains('- topic')) score += 300;
    if (candidate.title.toLowerCase().contains('official audio')) score += 300;

    // Versions that are not the one asked for (live, cover, karaoke...).
    final lowerCand = '${candidate.title} ${candidate.artist}'.toLowerCase();
    final lowerTarget = target.title.toLowerCase();
    for (final variant in _wrongVariants.entries) {
      if (variant.value.hasMatch(lowerCand) && !variant.value.hasMatch(lowerTarget)) {
        score -= 3000;
      }
    }

    // A qualifier in brackets the target does not have: "(8 Bit Version)",
    // "(Violin)". Credits and filler ("Official Video") do not count.
    for (final match in _bracketed.allMatches(candidate.title)) {
      final content = match.group(1)!;
      if (_credit.hasMatch(content)) continue;
      final plain = _plain(content);
      if (plain.isEmpty || _hasPhrase(_plain(target.title), plain)) continue;
      var rest = plain;
      for (final artist in artists) {
        rest = ' $rest '.replaceAll(' $artist ', ' ').trim();
      }
      final meaningful = rest
          .split(' ')
          .where((w) => w.isNotEmpty && !_neutralWords.contains(w) && !_digits.hasMatch(w));
      if (meaningful.isNotEmpty) {
        score -= 1500;
        break;
      }
    }

    return score;
  }

  (Song, int)? _bestOf(List<Song> candidates, Song target, {bool fromMusicCatalog = false}) {
    (Song, int)? best;
    for (final candidate in candidates) {
      final score = scoreCandidate(candidate, target, fromMusicCatalog: fromMusicCatalog);
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
    // A source chosen for this song (by the user, or after its own video
    // failed) wins for every kind of song, YouTube ones included. A stored
    // value is used only if it really is a video id: older versions could
    // save the catalog id itself here after a failed match.
    if (_isVideoId(song.youtubeVideoId)) return song.youtubeVideoId;

    final cached = StorageService.instance.getCachedYouTubeMapping(song.id);
    if (_isVideoId(cached)) return cached;

    if (!needsResolution(song.id)) {
      return song.id;
    }

    try {
      final cleanTitle = _canonicalTitle(song.title);
      final cleanArtist = _canonicalArtist(song.artist).split(',').first;

      // YouTube Music first: its results are studio tracks, not Vevo videos.
      var best = _bestOf(
        await YTMusicService.instance.search('$cleanTitle $cleanArtist'),
        song,
        fromMusicCatalog: true,
      );

      // Nothing, or nothing convincing: the song may have been released
      // only as a video. Music videos first, then plain YouTube.
      if (best == null || best.$2 < _weakScore) {
        final wider = await Future.wait([
          YTMusicCatalogService.instance.searchVideos('$cleanTitle $cleanArtist'),
          YTMusicService.instance.explodeSearch('${song.title} ${song.artist} audio'),
        ]);
        final video = _bestOf([...wider[0], ...wider[1]], song);
        if (video != null && (best == null || video.$2 > best.$2)) best = video;
      }

      if (best == null) {
        PlaybackLogService.instance
            .error('MATCHER', 'nessun risultato per "${song.title}" - ${song.artist}');
        return null;
      }

      // The best result has an unrelated title: it is another song. Playing
      // or downloading it under this title is worse than saying that
      // nothing was found.
      if (best.$2 <= _unrelatedScore) {
        PlaybackLogService.instance.error(
          'MATCHER',
          'nessun risultato attinente per "${song.title}" - ${song.artist} '
          '(il migliore era "${best.$1.title}" di ${best.$1.artist})',
        );
        return null;
      }

      PlaybackLogService.instance.log(
        'MATCHER',
        '"${song.title}" -> ${best.$1.id} "${best.$1.title}" di ${best.$1.artist} '
        '(${best.$1.duration.inSeconds}s contro ${song.duration.inSeconds}s, punteggio ${best.$2})',
      );
      await StorageService.instance.cacheYouTubeMapping(song.id, best.$1.id);
      return best.$1.id;
    } catch (e, stack) {
      PlaybackLogService.instance
          .error('MATCHER', 'ricerca fallita per "${song.title}": $e', stack);
      return null;
    }
  }

  /// Another source for [song], best first, skipping the ids in [exclude]
  /// (the ones that already failed). Null when nothing related is left.
  Future<String?> alternativeStreamId(Song song, {required Set<String> exclude}) async {
    final matches = await getAlternativeMatches(song);
    for (final match in matches) {
      if (exclude.contains(match.song.id)) continue;
      // Sorted by score: from here on the titles are unrelated.
      if (match.score <= _unrelatedScore) break;
      PlaybackLogService.instance.log(
        'MATCHER',
        'alternativa per "${song.title}": ${match.song.id} "${match.song.title}" '
        'di ${match.song.artist} (punteggio ${match.score})',
      );
      return match.song.id;
    }
    PlaybackLogService.instance
        .log('MATCHER', 'nessuna alternativa per "${song.title}" (${matches.length} candidati)');
    return null;
  }

  Future<List<ScoredTrackMatch>> getAlternativeMatches(Song targetSong, {int limit = 12}) async {
      try {
        final cleanTitle = _canonicalTitle(targetSong.title);
        final cleanArtist = _canonicalArtist(targetSong.artist).split(',').first;
        final query = '$cleanTitle $cleanArtist';

        final results = await YTMusicService.instance.search(query);
        final explode = [
          ...await YTMusicCatalogService.instance.searchVideos(query),
          ...await YTMusicService.instance.explodeSearch('$query audio'),
        ];

        // The catalog entry wins when a video is in both lists.
        final catalogIds = {for (final r in results) r.id};
        final allCandidates = <String, Song>{};
        for (final r in [...explode, ...results]) {
          allCandidates[r.id] = r;
        }

        final scoredList = <ScoredTrackMatch>[];

        for (final candidate in allCandidates.values) {
          final score = scoreCandidate(
            candidate,
            targetSong,
            fromMusicCatalog: catalogIds.contains(candidate.id),
          );
          final diff = targetSong.duration > Duration.zero && candidate.duration > Duration.zero
              ? (candidate.duration.inSeconds - targetSong.duration.inSeconds).abs()
              : 0;

          String label;
          if (diff <= 3 && score >= 8000) {
            label = 'Match Perfetto (±${diff}s)';
          } else if (diff <= 8 && score >= 5500) {
            label = 'Ottimo (±${diff}s)';
          } else if (diff <= 15 && score >= 2500) {
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
