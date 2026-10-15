import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyrics_model.dart';
import '../models/song.dart';
import 'app_settings.dart';
import 'lyrics_sources.dart';
import 'storage_service.dart';
import 'track_matcher_service.dart';

/// One answer of a search across all the sources, to choose from.
@immutable
class LyricsCandidate {
  const LyricsCandidate(this.source, this.lyrics);

  final LyricsSource source;
  final Lyrics lyrics;
}

/// The lyrics of the songs: looked up in the sources the user keeps on, in
/// their order (see [LyricsSources]), remembered on disk, and replaced by
/// the ones the user chose or wrote. Each song can also have its lyrics
/// moved earlier or later, when they run ahead of the music or behind.
class LyricsService {
  static final LyricsService instance = LyricsService._internal();
  LyricsService._internal();

  static const int _maxCacheSize = 100;
  // "No lyrics" is remembered only for a while: the sources are often
  // briefly unavailable, and the lyrics of a new release arrive later.
  static const Duration _missTtl = Duration(minutes: 10);
  // On disk a miss lasts longer: it only spares the background pass over
  // the downloads from searching the same songs at every start.
  static const Duration _storedMissTtl = Duration(days: 3);
  final Map<String, Lyrics> _memoryCache = {};
  final Map<String, DateTime> _missUntil = {};
  final Map<String, Future<Lyrics>> _inFlight = {};

  /// Bumped whenever the lyrics of a song change by the user's hand (chosen,
  /// edited, moved in time): whoever shows them reloads.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static final RegExp _titleParenthesesRegex = RegExp(
    r'\((Official|Lyric|Video|Audio|Music Video|Visualizer|HD|4K|Remastered|Sanremo|feat\.|with).*?\)',
    caseSensitive: false,
  );
  static final RegExp _titleBracketsRegex = RegExp(
    r'\[(Official|Lyric|Video|Audio|Music Video|Visualizer|HD|4K|Remastered|Sanremo|feat\.|with).*?\]',
    caseSensitive: false,
  );
  static final RegExp _titlePipeRegex = RegExp(r'\|.*');

  static final RegExp _artistTopicRegex = RegExp(r'\s*-\s*Topic', caseSensitive: false);
  static final RegExp _artistVevoRegex = RegExp(r'vevo$', caseSensitive: false);
  static final RegExp _artistOfficialRegex = RegExp(
    r'Official(\s+Channel)?$',
    caseSensitive: false,
  );

  void _cacheLyrics(String songId, Lyrics lyrics) {
    if (_memoryCache.length >= _maxCacheSize) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[songId] = lyrics;
  }

  /// Lyrics of [song], empty when no source has them. [refresh] searches
  /// again even if "no lyrics" was the answer a moment ago. Concurrent
  /// requests for the same song share one search.
  Future<Lyrics> getLyrics(Song song, {bool refresh = false}) {
    final cached = _memoryCache[song.id];
    if (cached != null) {
      final missUntil = _missUntil[song.id];
      final stale =
          cached.isEmpty && (refresh || missUntil == null || DateTime.now().isAfter(missUntil));
      if (!stale) return Future.value(cached);
    }
    final pending = _inFlight[song.id];
    if (pending != null) return pending;

    // Found before, in any session: shown at once and available offline.
    if (cached == null) {
      final stored = _fromDisk(song.id, acceptMiss: !refresh);
      if (stored != null) {
        _cacheLyrics(song.id, stored);
        if (stored.isEmpty) _missUntil[song.id] = DateTime.now().add(_missTtl);
        return Future.value(stored);
      }
    }

    final future = _searchLyrics(song);
    _inFlight[song.id] = future;
    // Block body on purpose: the callback must not return the future.
    return future.whenComplete(() {
      _inFlight.remove(song.id);
    });
  }

  /// Lyrics saved for [songId]. A saved "none" counts only while it is
  /// recent and [acceptMiss] is set.
  Lyrics? _fromDisk(String songId, {required bool acceptMiss}) {
    final stored = StorageService.instance.getStoredLyrics(songId);
    if (stored == null) return null;
    final lyrics = Lyrics.fromMap(stored);
    if (lyrics.isNotEmpty) return lyrics;
    final at = stored['at'];
    final recent =
        at is int &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at)) < _storedMissTtl;
    return acceptMiss && recent ? Lyrics.empty : null;
  }

  /// True when nothing needs to be fetched to show the lyrics of [songId].
  bool isStored(String songId) =>
      _memoryCache[songId]?.isNotEmpty == true || _fromDisk(songId, acceptMiss: true) != null;

  Future<Lyrics> _searchLyrics(Song song) async {
    final (lyrics, complete) = await _searchSources(song);
    // "None" is saved only when every source answered: a search made
    // without network must not hide the lyrics for days.
    if (lyrics.isNotEmpty || complete) {
      await StorageService.instance.saveLyrics(song.id, {
        ...lyrics.toMap(),
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    }
    return lyrics;
  }

  /// The sources to ask, in the user's order.
  List<LyricsSource> get _enabledSources => [
    for (final id in AppSettings.instance.lyricsSources.value) ?LyricsSources.byId(id),
  ];

  LyricsQuery _queryFor(Song song, {String? title, String? artist}) {
    final (cleanTitle, cleanArtist) = _parseSongMetadata(
      title ?? song.title,
      artist ?? song.artist,
    );
    final primary = cleanArtist.split(RegExp(r'[,&]|feat\.|\+')).first.trim();
    final mapped = StorageService.instance.getCachedYouTubeMapping(song.id);
    final video = (mapped != null && mapped.isNotEmpty)
        ? mapped
        : (song.youtubeVideoId ?? (TrackMatcherService.needsResolution(song.id) ? null : song.id));
    return LyricsQuery(
      title: cleanTitle,
      artist: cleanArtist,
      primaryArtist: primary.isEmpty ? cleanArtist : primary,
      album: song.album,
      durationSec: song.duration.inSeconds,
      videoId: video,
    );
  }

  /// Asks the sources one after the other. The record's second value is
  /// false when one of them could not be asked.
  Future<(Lyrics, bool)> _searchSources(Song song) async {
    _missUntil.remove(song.id);
    final query = _queryFor(song);
    debugPrint(
      'LyricsService: cerco "${query.title}" di "${query.artist}" '
      '(${query.durationSec}s, video ${query.videoId ?? '-'})',
    );
    var complete = true;
    for (final source in _enabledSources) {
      try {
        final lyrics = await source.find(query);
        if (lyrics != null && lyrics.isNotEmpty) {
          debugPrint(
            'LyricsService: trovato su ${source.name}'
            '${lyrics.isWordSynced
                ? ' (parola per parola)'
                : lyrics.isSynced
                ? ' (sincronizzato)'
                : ''}',
          );
          _cacheLyrics(song.id, lyrics);
          return (lyrics, true);
        }
      } catch (e) {
        complete = false;
        debugPrint('LyricsService: ${source.name} non risponde: $e');
      }
    }
    // A miss is remembered too: no lyrics is a legitimate answer and must
    // not send every source a request at every rebuild of the player.
    _cacheLyrics(song.id, Lyrics.empty);
    _missUntil[song.id] = DateTime.now().add(_missTtl);
    return (Lyrics.empty, complete);
  }

  /// Asks every source at once, for the user to choose: with [title] and
  /// [artist] when they want to search for something else.
  Future<List<LyricsCandidate>> searchAll(Song song, {String? title, String? artist}) async {
    final query = _queryFor(song, title: title, artist: artist);
    final answers = await Future.wait([
      for (final source in LyricsSources.all)
        source
            .find(query)
            .then(
              (lyrics) => lyrics == null || lyrics.isEmpty ? null : LyricsCandidate(source, lyrics),
              onError: (Object e) {
                debugPrint('LyricsService.searchAll ${source.name}: $e');
                return null;
              },
            ),
    ]);
    final found = [for (final answer in answers) ?answer];
    // The timed ones first, word by word before line by line.
    int rank(Lyrics lyrics) => lyrics.isWordSynced ? 0 : (lyrics.isSynced ? 1 : 2);
    found.sort((a, b) => rank(a.lyrics).compareTo(rank(b.lyrics)));
    return found;
  }

  /// Keeps [lyrics] as the lyrics of [songId], chosen or written by the
  /// user: they stay until another choice.
  Future<void> setLyrics(String songId, Lyrics lyrics) async {
    _cacheLyrics(songId, lyrics);
    _missUntil.remove(songId);
    await StorageService.instance.saveLyrics(songId, {
      ...lyrics.toMap(),
      'at': DateTime.now().millisecondsSinceEpoch,
      'manual': true,
    });
    changes.value++;
  }

  /// How much the lyrics of [songId] are moved in time, as set by the user.
  Duration offsetOf(String songId) {
    final ms = StorageService.instance.getStoredLyrics(songId)?['offsetMs'];
    return Duration(milliseconds: ms is int ? ms : 0);
  }

  Future<void> setOffset(String songId, Duration offset) async {
    final stored = StorageService.instance.getStoredLyrics(songId);
    if (stored == null) return;
    await StorageService.instance.saveLyrics(songId, {
      ...stored,
      'offsetMs': offset.inMilliseconds,
    });
    changes.value++;
  }

  /// Forgets every lyrics found (not those chosen or written by the user).
  Future<void> clearCache() async {
    _memoryCache.clear();
    _missUntil.clear();
    await StorageService.instance.clearFoundLyrics();
    changes.value++;
  }

  /// Looks up the lyrics of [songs] ahead, one at a time, so that they show
  /// at once when the song starts.
  Future<void> preload(Iterable<Song> songs) async {
    if (!AppSettings.instance.lyricsPreload.value) return;
    for (final song in songs) {
      if (isStored(song.id)) continue;
      try {
        await getLyrics(song);
      } catch (e) {
        debugPrint('LyricsService.preload: $e');
      }
    }
  }

  (String, String) _parseSongMetadata(String rawTitle, String rawArtist) {
    String cleanTitle = rawTitle
        .replaceAll(_titleParenthesesRegex, '')
        .replaceAll(_titleBracketsRegex, '')
        .replaceAll(_titlePipeRegex, '')
        .trim();

    String cleanArtist = rawArtist
        .replaceAll(_artistTopicRegex, '')
        .replaceAll(_artistVevoRegex, '')
        .replaceAll(_artistOfficialRegex, '')
        .trim();

    // Check if title is formatted as "Artist - Song Title" (common on YouTube)
    if (cleanTitle.contains(' - ')) {
      final parts = cleanTitle.split(' - ');
      if (parts.length >= 2) {
        final artistPart = parts[0].trim();
        final titlePart = parts.sublist(1).join(' - ').trim();
        if (titlePart.isNotEmpty) {
          cleanTitle = titlePart;
          final lowerArtist = rawArtist.toLowerCase();
          if (lowerArtist.contains('vevo') ||
              lowerArtist.contains('topic') ||
              lowerArtist.contains('records') ||
              lowerArtist.contains('channel') ||
              rawArtist == 'Artista' ||
              rawArtist.isEmpty) {
            cleanArtist = artistPart;
          } else if (artistPart.length > 2 && cleanArtist.length <= 2) {
            // Only trust the "Artist - Title" form when we have no real
            // artist: Spotify titles often contain " - Remastered 2011".
            cleanArtist = artistPart;
          }
        }
      }
    }

    return (cleanTitle, cleanArtist);
  }
}
