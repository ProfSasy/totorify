import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';

class ITunesService {
  ITunesService._internal();
  static final ITunesService instance = ITunesService._internal();

  Future<List<Song>> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    try {
      final url = Uri.parse('https://itunes.apple.com/search?term=${Uri.encodeComponent(clean)}&entity=song&limit=25');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List<dynamic>;
        
        final songs = <Song>[];
        for (final item in results) {
          final trackId = item['trackId'].toString();
          final title = item['trackName'] as String?;
          final artist = item['artistName'] as String?;
          final album = item['collectionName'] as String?;
          final durationMs = item['trackTimeMillis'] as int?;
          final artwork100 = item['artworkUrl100'] as String?;
          
          if (title == null || artist == null || durationMs == null || artwork100 == null) {
            continue;
          }

          // Ottieni copertina in alta risoluzione
          final highResArtwork = artwork100.replaceAll('100x100bb.jpg', '600x600bb.jpg');

          songs.add(Song(
            id: 'itunes_$trackId',
            title: title,
            artist: artist,
            album: album,
            duration: Duration(milliseconds: durationMs),
            thumbnailUrl: highResArtwork,
          ));
        }
        return songs;
      }
    } catch (e) {
      debugPrint('ITunesService search error: $e');
    }
    return [];
  }

  Future<List<Song>> getTrendingSongs(String category) async {
    // L'RSS di Apple è morto/lentissimo (timeout 10-20s).
    // Demus usa direttamente la search API per simulare le categorie.
    final query = category == 'Top Hits Italia' ? 'hit italia' : category;
    final results = await search(query);
    if (category != 'Top Hits Italia') {
      results.shuffle();
    }
    return results.take(20).toList();
  }
}
