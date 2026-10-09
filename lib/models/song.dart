import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final Duration duration;
  final String thumbnailUrl;
  final String? audioUrl;
  final String? localFilePath;
  final bool isDownloaded;
  final bool isFavorite;
  final String? youtubeVideoId;
  final String? spotifyTrackId;
  final String? canvasUrl;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    required this.duration,
    required this.thumbnailUrl,
    this.audioUrl,
    this.localFilePath,
    this.isDownloaded = false,
    this.isFavorite = false,
    this.youtubeVideoId,
    this.spotifyTrackId,
    this.canvasUrl,
  });

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? thumbnailUrl,
    String? audioUrl,
    String? localFilePath,
    bool? isDownloaded,
    bool? isFavorite,
    String? youtubeVideoId,
    String? spotifyTrackId,
    String? canvasUrl,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      localFilePath: localFilePath ?? this.localFilePath,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      isFavorite: isFavorite ?? this.isFavorite,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      spotifyTrackId: spotifyTrackId ?? this.spotifyTrackId,
      canvasUrl: canvasUrl ?? this.canvasUrl,
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
      'audioUrl': audioUrl,
      'localFilePath': localFilePath,
      'isDownloaded': isDownloaded,
      'isFavorite': isFavorite,
      'youtubeVideoId': youtubeVideoId,
      'spotifyTrackId': spotifyTrackId,
      'canvasUrl': canvasUrl,
    };
  }

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? 'Brano sconosciuto',
      artist: map['artist'] as String? ?? 'Artista sconosciuto',
      album: map['album'] as String?,
      duration: Duration(milliseconds: map['durationMs'] as int? ?? 0),
      thumbnailUrl: map['thumbnailUrl'] as String? ?? '',
      audioUrl: map['audioUrl'] as String?,
      localFilePath: map['localFilePath'] as String?,
      isDownloaded: map['isDownloaded'] as bool? ?? false,
      isFavorite: map['isFavorite'] as bool? ?? false,
      youtubeVideoId: map['youtubeVideoId'] as String?,
      spotifyTrackId: map['spotifyTrackId'] as String?,
      canvasUrl: map['canvasUrl'] as String?,
    );
  }

  String toJson() => json.encode(toMap());

  factory Song.fromJson(String source) {
    try {
      final decoded = json.decode(source);
      if (decoded is Map<String, dynamic>) {
        return Song.fromMap(decoded);
      } else if (decoded is Map) {
        return Song.fromMap(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      debugPrint('Song.fromJson decode error: $e');
    }
    return const Song(
      id: '',
      title: 'Unknown',
      artist: 'Unknown',
      duration: Duration.zero,
      thumbnailUrl: '',
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
      extras: {
        'audioUrl': audioUrl,
        'localFilePath': localFilePath,
        'isDownloaded': isDownloaded,
        'canvasUrl': canvasUrl,
      },
    );
  }

  factory Song.fromMediaItem(MediaItem item) {
    return Song(
      id: item.id,
      title: item.title,
      artist: item.artist ?? 'Artista sconosciuto',
      album: item.album,
      duration: item.duration ?? Duration.zero,
      thumbnailUrl: item.artUri?.toString() ?? '',
      audioUrl: item.extras?['audioUrl'] as String?,
      localFilePath: item.extras?['localFilePath'] as String?,
      isDownloaded: item.extras?['isDownloaded'] as bool? ?? false,
      canvasUrl: item.extras?['canvasUrl'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
