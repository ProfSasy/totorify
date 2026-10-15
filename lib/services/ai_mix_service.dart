import 'package:flutter/foundation.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import 'ai_service.dart';
import 'library_extras.dart';
import 'listening_stats.dart';
import 'playback_log_service.dart';
import 'storage_service.dart';
import 'ytmusic_service.dart';

/// A mix the model makes from what the user listens to: it proposes
/// songs, each is looked up in the catalog, and those found make the
/// playlist (YumaPlayer's "Top Mixes" made by the AI).
class AiMixService {
  AiMixService._();
  static final AiMixService instance = AiMixService._();

  static const int _songsAsked = 30;

  /// Builds a mix. [mood] narrows it ("allegro", "per studiare"…).
  Future<Playlist> build({String? mood}) async {
    final stats = ListeningStats.instance;
    final artists = stats.topArtists(StatsPeriod.month, limit: 15).map((r) => r.item).toList();
    final songs = [
      for (final r in stats.topSongs(StatsPeriod.month, limit: 20))
        '${r.item.title} - ${r.item.artist}',
    ];
    final favorites = [
      for (final s in StorageService.instance.getFavorites().take(20)) '${s.title} - ${s.artist}',
    ];
    if (artists.isEmpty && favorites.isEmpty) {
      throw AiException('Ascolta un po\' di musica o metti qualche cuore: il mix nasce da lì');
    }
    final blocked = LibraryExtras.instance.blockedArtists.value;
    final prompt = StringBuffer()
      ..writeln('Crea una playlist di $_songsAsked brani per questa persona.')
      ..writeln('Artisti che ascolta di più: ${artists.join(', ')}.')
      ..writeln('Brani che ascolta di più: ${songs.join('; ')}.')
      ..writeln('Brani che le piacciono: ${favorites.join('; ')}.');
    if (mood != null && mood.trim().isNotEmpty) {
      prompt.writeln('Atmosfera richiesta: ${mood.trim()}.');
    }
    if (blocked.isNotEmpty) prompt.writeln('Non includere questi artisti: ${blocked.join(', ')}.');
    prompt.writeln(
      'Mescola brani che conosce con scoperte simili, tutti brani reali e pubblicati. '
      'Rispondi solo con un oggetto JSON: {"title": nome breve della playlist in italiano, '
      '"description": una frase in italiano, "songs": [{"title": ..., "artist": ...}]}.',
    );

    final answer = await AiService.instance.complete(
      prompt.toString(),
      system: 'Sei un curatore musicale esperto.',
      maxTokens: 6000,
    );
    final data = AiService.extractJson(answer);
    if (data is! Map || data['songs'] is! List) {
      throw AiException('Il modello non ha risposto come previsto');
    }

    final proposals = [
      for (final item in data['songs'] as List)
        if (item is Map && item['title'] != null) ('${item['title']}', '${item['artist'] ?? ''}'),
    ];
    final found = await Future.wait([
      for (final (title, artist) in proposals) _find(title, artist),
    ]);
    final tracks = <Song>[];
    final ids = <String>{};
    for (final song in found) {
      if (song != null && ids.add(song.id) && !LibraryExtras.instance.isBlocked(song.artist)) {
        tracks.add(song);
      }
    }
    if (tracks.isEmpty) throw AiException('Nessuno dei brani proposti è stato trovato');
    PlaybackLogService.instance.log(
      'AI',
      'mix: ${tracks.length}/${proposals.length} brani trovati',
    );
    return Playlist(
      id: 'ai_mix_${DateTime.now().millisecondsSinceEpoch}',
      title: '${data['title'] ?? 'Il tuo mix'}',
      description: '${data['description'] ?? 'Creato dall\'intelligenza artificiale per te'}',
      songs: tracks,
      thumbnailUrl: tracks.first.thumbnailUrl,
      isSystem: true,
    );
  }

  Future<Song?> _find(String title, String artist) async {
    try {
      final results = await YTMusicService.instance.search('$title $artist');
      if (results.isEmpty) return null;
      final wanted = artist.toLowerCase().split(RegExp(r'[,&]')).first.trim();
      for (final song in results.take(5)) {
        if (wanted.isEmpty || song.artist.toLowerCase().contains(wanted)) return song;
      }
      return results.first;
    } catch (e) {
      debugPrint('AiMixService._find: $e');
      return null;
    }
  }
}
