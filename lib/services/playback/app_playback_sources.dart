import '../../models/song.dart';
import '../storage_service.dart';
import '../track_matcher_service.dart';
import '../ytmusic_service.dart';
import 'stream_opener.dart';

/// The sources of the app: the downloads kept by [StorageService], the
/// videos matched by [TrackMatcherService] and the streams of YouTube.
class AppPlaybackSources implements PlaybackSources {
  const AppPlaybackSources();

  @override
  Future<bool> hasLocalFile(String songId) => StorageService.instance.hasLocalAudioFile(songId);

  @override
  Future<String> localPath(String songId) => StorageService.instance.getLocalAudioPath(songId);

  @override
  Duration? localDuration(String songId) => StorageService.instance.getDownloadDuration(songId);

  @override
  Future<String?> resolveStreamId(Song song) =>
      TrackMatcherService.instance.resolveAndCacheStreamId(song);

  @override
  Future<String?> alternativeStreamId(Song song, {required Set<String> exclude}) =>
      TrackMatcherService.instance.alternativeStreamId(song, exclude: exclude);

  @override
  Future<void> rememberSource(String songId, String videoId) =>
      StorageService.instance.cacheYouTubeMapping(songId, videoId);

  @override
  bool get opusFirst => YTMusicService.opusPlayable;

  @override
  bool hasCachedAudioUrl(String videoId) => YTMusicService.instance.hasCachedAudioUrl(videoId);

  @override
  Duration? streamDuration(String videoId) => YTMusicService.instance.streamDuration(videoId);

  @override
  Future<String?> hlsAudioUrl(String videoId, {bool force = false}) =>
      YTMusicService.instance.getHlsAudioUrl(videoId, force: force);

  @override
  Future<String?> audioStreamUrl(String videoId, {bool force = false}) =>
      YTMusicService.instance.getAudioStreamUrl(videoId, force: force);

  @override
  Future<String?> hlsUrl(String videoId) => YTMusicService.instance.getHlsUrl(videoId);
}
