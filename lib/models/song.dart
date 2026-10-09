import 'package:audio_service/audio_service.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final Duration duration;
  final String thumbnailUrl;

  /// YouTube video to play instead of the one the matcher would pick: a
  /// source chosen by the user, or pre-resolved when a playlist is imported.
  final String? youtubeVideoId;
  final String? spotifyTrackId;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    required this.duration,
    required this.thumbnailUrl,
    this.youtubeVideoId,
    this.spotifyTrackId,
  });

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? thumbnailUrl,
    String? youtubeVideoId,
    String? spotifyTrackId,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      spotifyTrackId: spotifyTrackId ?? this.spotifyTrackId,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'durationMs': duration.inMilliseconds,
      'thumbnailUrl': thumbnailUrl,
      'youtubeVideoId': youtubeVideoId,
      'spotifyTrackId': spotifyTrackId,
    };
  }

  /// Maps saved by older versions carry more keys; they are ignored.
  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? 'Brano sconosciuto',
      artist: map['artist'] as String? ?? 'Artista sconosciuto',
      album: map['album'] as String?,
      duration: Duration(milliseconds: map['durationMs'] as int? ?? 0),
      thumbnailUrl: map['thumbnailUrl'] as String? ?? '',
      youtubeVideoId: map['youtubeVideoId'] as String?,
      spotifyTrackId: map['spotifyTrackId'] as String?,
    );
  }

  MediaItem toMediaItem() {
    final cleanThumb = thumbnailUrl.trim();
    final validUri = (cleanThumb.startsWith('http://') ||
            cleanThumb.startsWith('https://') ||
            cleanThumb.startsWith('file://'))
        ? Uri.tryParse(cleanThumb)
        : null;

    return MediaItem(
      id: id,
      album: album ?? 'Totorify',
      title: title,
      artist: artist,
      duration: duration > Duration.zero ? duration : const Duration(seconds: 1),
      artUri: validUri,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
