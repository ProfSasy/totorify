import '../models/song.dart';
import 'deezer_service.dart';
import 'storage_service.dart';

/// Replaces YouTube video thumbnails (16:9 frames, low resolution) with the
/// official album cover of the track.
class CoverArtService {
  CoverArtService._internal();
  static final CoverArtService instance = CoverArtService._internal();

  /// True when [url] is missing or is a YouTube video frame rather than
  /// album artwork. YouTube Music, Spotify, Apple and Deezer covers are kept.
  static bool needsOriginal(String url) {
    final clean = url.trim();
    return clean.isEmpty || clean.contains('ytimg.com');
  }

  /// Official cover for [song], or null when the catalog has no confident
  /// match. Results are persisted, so each song is looked up once.
  Future<String?> originalCover(Song song) async {
    final stored = StorageService.instance.getCachedCover(song.id);
    if (stored != null) return stored;

    final match = await DeezerService.instance.matchTrack(song);
    if (match == null) return null;
    await StorageService.instance.cacheCover(song.id, match.coverUrl);
    return match.coverUrl;
  }

  /// [song] with its official cover when it needs one and one is found;
  /// otherwise [song] unchanged.
  Future<Song> withOriginalCover(Song song) async {
    if (!needsOriginal(song.thumbnailUrl)) return song;
    final cover = await originalCover(song);
    return cover == null ? song : song.copyWith(thumbnailUrl: cover);
  }

  Future<List<Song>> withOriginalCovers(List<Song> songs) =>
      Future.wait(songs.map(withOriginalCover));
}
