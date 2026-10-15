import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'app_http.dart';
import 'app_settings.dart';

/// A part of a video to jump over.
@immutable
class SkipSegment {
  const SkipSegment(this.start, this.end, this.category);

  final Duration start;
  final Duration end;
  final String category;

  bool contains(Duration position) => position >= start && position < end;

  @override
  String toString() => '$category ${start.inMilliseconds / 1000}-${end.inMilliseconds / 1000}s';
}

/// The parts of YouTube videos that are not music, as marked by the users
/// of SponsorBlock (sponsor.ajay.app): intros, skits, talking. Totorify
/// plays the audio of music videos, which often have them.
///
/// The video is asked by the first characters of the SHA-256 of its id, so
/// the server never learns which video is playing.
class SponsorBlockService {
  SponsorBlockService._();
  static final SponsorBlockService instance = SponsorBlockService._();

  static const String apiUrl = 'https://sponsor.ajay.app';

  /// The kinds of segments, as named by the API, with the Italian label
  /// shown in the settings.
  static const Map<String, String> categories = {
    'music_offtopic': 'Parti non musicali',
    'intro': 'Sigle e intermezzi',
    'outro': 'Titoli di coda',
    'sponsor': 'Sponsor',
    'selfpromo': 'Autopromozione',
    'interaction': 'Inviti a iscriversi',
    'preview': 'Anteprime e riassunti',
    'filler': 'Divagazioni',
  };

  final Map<String, List<SkipSegment>> _cache = {};
  final Map<String, Future<List<SkipSegment>>> _inFlight = {};

  /// The segments of [videoId] to skip, with the categories chosen in the
  /// settings. Empty when the feature is off, when nothing is marked or
  /// when the server cannot be reached.
  Future<List<SkipSegment>> segmentsFor(String videoId) {
    final settings = AppSettings.instance;
    if (!settings.sponsorBlock.value || videoId.isEmpty) return Future.value(const []);
    final wanted = settings.sponsorBlockCategories.value;
    if (wanted.isEmpty) return Future.value(const []);
    final key = '$videoId|${wanted.join(',')}';
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    return _inFlight[key] ??= _fetch(videoId, wanted)
        .then((segments) {
          _cache[key] = segments;
          if (_cache.length > 200) _cache.remove(_cache.keys.first);
          return segments;
        })
        .whenComplete(() {
          // A block on purpose: returning the removed future would make this
          // one wait for itself.
          _inFlight.remove(key);
        });
  }

  Future<List<SkipSegment>> _fetch(String videoId, List<String> wanted) async {
    final prefix = sha256.convert(utf8.encode(videoId)).toString().substring(0, 4);
    final uri = Uri.parse('$apiUrl/api/skipSegments/$prefix').replace(
      queryParameters: {
        'categories': jsonEncode(wanted),
        'actionTypes': jsonEncode(['skip']),
        'service': 'YouTube',
      },
    );
    try {
      final response = await appHttp.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 404) return const [];
      if (response.statusCode != 200) {
        debugPrint('SponsorBlock $videoId: HTTP ${response.statusCode}');
        return const [];
      }
      return parse(response.body, videoId);
    } catch (e) {
      debugPrint('SponsorBlock $videoId: $e');
      return const [];
    }
  }

  /// The segments of [videoId] in an answer of the API, by start, with
  /// overlapping ones merged. Public for the tests.
  static List<SkipSegment> parse(String body, String videoId) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final found = <SkipSegment>[];
    for (final video in decoded) {
      if (video is! Map || video['videoID'] != videoId) continue;
      for (final raw in (video['segments'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final bounds = raw['segment'];
        if (bounds is! List || bounds.length < 2) continue;
        final start = (bounds[0] as num).toDouble();
        final end = (bounds[1] as num).toDouble();
        if (end - start < 1) continue;
        found.add(
          SkipSegment(
            Duration(milliseconds: (start * 1000).round()),
            Duration(milliseconds: (end * 1000).round()),
            '${raw['category'] ?? ''}',
          ),
        );
      }
    }
    found.sort((a, b) => a.start.compareTo(b.start));
    final merged = <SkipSegment>[];
    for (final segment in found) {
      if (merged.isNotEmpty && segment.start <= merged.last.end) {
        final last = merged.removeLast();
        merged.add(
          SkipSegment(last.start, segment.end > last.end ? segment.end : last.end, last.category),
        );
      } else {
        merged.add(segment);
      }
    }
    return merged;
  }
}
