import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/lyrics_model.dart';
import '../models/song.dart';

class LyricsService {
  static final LyricsService instance = LyricsService._internal();
  LyricsService._internal();

  static const int _maxCacheSize = 100;
  final Map<String, Lyrics> _memoryCache = {};
  final http.Client _client = http.Client();

  static const Map<String, String> _headers = {
    'User-Agent': 'Totorify/1.0.0 (https://github.com/ProfSasy/kreate-ios)',
  };

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
  static final RegExp _artistOfficialRegex = RegExp(r'Official(\s+Channel)?$', caseSensitive: false);

  void _cacheLyrics(String songId, Lyrics lyrics) {
    if (_memoryCache.length >= _maxCacheSize) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[songId] = lyrics;
  }

  Future<Lyrics?> _fetchFromGet(String trackName, String artistName, {int? durationSec}) async {
    try {
      final uri = Uri.parse('https://lrclib.net/api/get').replace(
        queryParameters: {
          'track_name': trackName,
          'artist_name': artistName,
          if (durationSec != null && durationSec > 0) 'duration': durationSec.toString(),
        },
      );
      final response = await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final synced = data['syncedLyrics'] as String?;
        final plain = data['plainLyrics'] as String?;

        if (synced != null && synced.trim().isNotEmpty) {
          return Lyrics.fromLrc(synced, plainFallback: plain);
        } else if (plain != null && plain.trim().isNotEmpty) {
          return Lyrics(plainLyrics: plain, syncedLyrics: const [], isSynced: false);
        }
      } else {
        debugPrint('LyricsService._fetchFromGet HTTP ${response.statusCode} for "$trackName" by "$artistName"');
      }
    } catch (e) {
      debugPrint('LyricsService._fetchFromGet error for "$trackName" by "$artistName": $e');
    }
    return null;
  }

  Future<Lyrics?> _fetchFromSearch(
    String query, {
    String? expectedArtist,
    int? expectedDurationSec,
  }) async {
    try {
      final searchUri = Uri.parse('https://lrclib.net/api/search').replace(
        queryParameters: {'q': query},
      );
      final searchResponse = await _client.get(searchUri, headers: _headers).timeout(const Duration(seconds: 8));
      if (searchResponse.statusCode == 200) {
        final results = json.decode(searchResponse.body) as List<dynamic>;
        for (final item in results) {
          final data = item as Map<String, dynamic>;

          // Validate the candidate before accepting it: a wrong-artist hit is
          // worse than no lyrics at all.
          if (expectedArtist != null && expectedArtist.isNotEmpty) {
            final candidateArtist =
                (data['artistName'] as String? ?? '').toLowerCase();
            if (candidateArtist.isNotEmpty &&
                !candidateArtist.contains(expectedArtist.toLowerCase())) {
              continue;
            }
          }
          if (expectedDurationSec != null && expectedDurationSec > 0) {
            final candidateDuration = (data['duration'] as num?)?.toInt() ?? 0;
            if (candidateDuration > 0 &&
                (candidateDuration - expectedDurationSec).abs() > 12) {
              continue;
            }
          }

          final synced = data['syncedLyrics'] as String?;
          final plain = data['plainLyrics'] as String?;
          if (synced != null && synced.trim().isNotEmpty) {
            return Lyrics.fromLrc(synced, plainFallback: plain);
          } else if (plain != null && plain.trim().isNotEmpty) {
            return Lyrics(plainLyrics: plain, syncedLyrics: const [], isSynced: false);
          }
        }
      }
    } catch (e) {
      debugPrint('LyricsService._fetchFromSearch error for "$query": $e');
    }
    return null;
  }


  Future<Lyrics?> _fetchFromBetterLyrics(String title, String artist, {int? durationSec}) async {
    try {
      final uri = Uri.parse('https://lyrics-api.boidu.dev/getLyrics').replace(
        queryParameters: {
          's': title,
          'a': artist,
          if (durationSec != null && durationSec > 0) 'd': durationSec.toString(),
        }
      );
      final response = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        String body = response.body;
        String? ttmlContent;
        if (body.startsWith('{')) {
          final data = json.decode(body);
          ttmlContent = data['ttml'] as String?;
          if (ttmlContent == null && data['lyrics'] != null) {
            final inner = data['lyrics'];
            if (inner is Map && inner['ttml'] != null) {
              ttmlContent = inner['ttml'] as String;
            }
          }
        } else {
          ttmlContent = body;
        }

        if (ttmlContent != null && ttmlContent.contains('<tt')) {
          final pRegex = RegExp(r'<p\s+begin="([^"]+)"[^>]*>(.*?)<\/p>');
          final matches = pRegex.allMatches(ttmlContent);
          final lrcLines = <String>[];
          for (final match in matches) {
            final beginStr = match.group(1)!;
            final rawText = match.group(2)!;
            final cleanText = rawText.replaceAll(RegExp(r'<[^>]*>'), '').trim();
            if (cleanText.isEmpty) continue;
            
            final parts = beginStr.split(':');
            double? seconds;
            if (parts.length == 1) {
              seconds = double.tryParse(parts[0]);
            } else if (parts.length == 2) {
              seconds = (double.tryParse(parts[0]) ?? 0) * 60 + (double.tryParse(parts[1]) ?? 0);
            } else if (parts.length == 3) {
              seconds = (double.tryParse(parts[0]) ?? 0) * 3600 + (double.tryParse(parts[1]) ?? 0) * 60 + (double.tryParse(parts[2]) ?? 0);
            }
            
            if (seconds != null) {
              final mins = (seconds / 60).floor();
              final secs = (seconds % 60).floor();
              final millis = ((seconds - seconds.floor()) * 1000).floor();
              final formattedTime = '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
              lrcLines.add('[$formattedTime] $cleanText');
            }
          }
          if (lrcLines.isNotEmpty) {
            return Lyrics.fromLrc(lrcLines.join('\n'));
          }
        }
      }
    } catch (e) {
      debugPrint('LyricsService._fetchFromBetterLyrics error: $e');
    }
    return null;
  }

  Future<Lyrics?> _fetchFromKuGou(String title, String artist, {int? durationSec}) async {
    try {
      final keyword = '$title - $artist';
      final searchUrl = Uri.parse('https://mobileservice.kugou.com/api/v3/search/song').replace(
        queryParameters: {
          'version': '9108',
          'plat': '0',
          'pagesize': '8',
          'showtype': '0',
          'keyword': keyword,
        }
      );
      
      final searchResp = await _client.get(searchUrl, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
      }).timeout(const Duration(seconds: 8));
      
      if (searchResp.statusCode != 200) return null;
      final searchData = json.decode(searchResp.body);
      final infoList = searchData['data']?['info'] as List<dynamic>? ?? [];
      
      String? targetHash;
      for (final info in infoList) {
        final duration = (info['duration'] as num?)?.toInt() ?? 0;
        if (durationSec == null || durationSec <= 0 || (duration - durationSec).abs() <= 8) {
          targetHash = info['hash'] as String?;
          if (targetHash != null && targetHash.isNotEmpty) break;
        }
      }
      
      if (targetHash == null && infoList.isNotEmpty) {
        targetHash = infoList.first['hash'] as String?;
      }
      
      if (targetHash == null) return null;
      
      final lyricsSearchUrl = Uri.parse('https://lyrics.kugou.com/search').replace(
        queryParameters: {
          'ver': '1',
          'man': 'yes',
          'client': 'pc',
          'hash': targetHash,
        }
      );
      
      final lyricsSearchResp = await _client.get(lyricsSearchUrl).timeout(const Duration(seconds: 8));
      if (lyricsSearchResp.statusCode != 200) return null;
      final lyricsSearchData = json.decode(lyricsSearchResp.body);
      final candidates = lyricsSearchData['candidates'] as List<dynamic>? ?? [];
      if (candidates.isEmpty) return null;
      
      final candidate = candidates.first;
      final id = candidate['id'].toString();
      final accesskey = candidate['accesskey'].toString();
      
      final downloadUrl = Uri.parse('https://lyrics.kugou.com/download').replace(
        queryParameters: {
          'fmt': 'lrc',
          'charset': 'utf8',
          'client': 'pc',
          'ver': '1',
          'id': id,
          'accesskey': accesskey,
        }
      );
      
      final downloadResp = await _client.get(downloadUrl).timeout(const Duration(seconds: 8));
      if (downloadResp.statusCode != 200) return null;
      final downloadData = json.decode(downloadResp.body);
      final contentBase64 = downloadData['content'] as String?;
      
      if (contentBase64 != null && contentBase64.isNotEmpty) {
        final lrcText = utf8.decode(base64Decode(contentBase64));
        return Lyrics.fromLrc(lrcText);
      }
    } catch (e) {
      debugPrint('LyricsService._fetchFromKuGou error: $e');
    }
    return null;
  }

  Future<Lyrics> getLyrics(Song song) async {
    if (_memoryCache.containsKey(song.id)) {
      return _memoryCache[song.id]!;
    }

    try {
      final (cleanTitle, cleanArtist) = _parseSongMetadata(song.title, song.artist);
      final durationSec = song.duration.inSeconds;

      debugPrint('LyricsService: Searching lyrics for "$cleanTitle" by "$cleanArtist" (duration: ${durationSec}s)');
      
      final primaryArtist = cleanArtist.split(RegExp(r'[,&]|feat\.|\+')).first.trim();

      Lyrics? lyrics;
      
      // 1. LRCLIB (Primary Source, very fast and clean)
      lyrics = await _fetchFromGet(cleanTitle, cleanArtist, durationSec: durationSec);
      if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }
      
      if (durationSec > 0) {
        lyrics = await _fetchFromGet(cleanTitle, cleanArtist, durationSec: null);
        if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }
      }
      
      if (primaryArtist != cleanArtist && primaryArtist.isNotEmpty) {
        lyrics = await _fetchFromGet(cleanTitle, primaryArtist, durationSec: null);
        if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }
      }

      // 2. BetterLyrics / Apple Music (Fallback Source 1)
      debugPrint('LyricsService: Falling back to BetterLyrics for "$cleanTitle"');
      lyrics = await _fetchFromBetterLyrics(cleanTitle, primaryArtist, durationSec: durationSec);
      if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }
      
      // 3. KuGou (Fallback Source 2, massive Chinese database)
      debugPrint('LyricsService: Falling back to KuGou for "$cleanTitle"');
      lyrics = await _fetchFromKuGou(cleanTitle, primaryArtist, durationSec: durationSec);
      if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }

      // 4. LRCLIB Search (Last resort fallback)
      debugPrint('LyricsService: Falling back to LRCLIB Search for "$cleanTitle"');
      lyrics = await _fetchFromSearch('$cleanTitle $primaryArtist', expectedArtist: primaryArtist, expectedDurationSec: durationSec);
      if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }
      
      lyrics = await _fetchFromSearch(cleanTitle, expectedArtist: primaryArtist, expectedDurationSec: durationSec);
      if (lyrics != null) { _cacheLyrics(song.id, lyrics); return lyrics; }

    } catch (e) {
      debugPrint('LyricsService.getLyrics: $e');
    }

    // Cache negative results too: without lyrics is a legitimate answer and
    // must not trigger six HTTP requests on every player rebuild.
    _cacheLyrics(song.id, Lyrics.empty);
    return Lyrics.empty;
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
