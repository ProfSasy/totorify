import 'song.dart';

class Playlist {
  final String id;
  final String title;
  final String? description;
  final String? thumbnailUrl;
  final List<Song> songs;
  final bool isSystem;

  const Playlist({
    required this.id,
    required this.title,
    this.description,
    this.thumbnailUrl,
    this.songs = const [],
    this.isSystem = false,
  });

  Playlist copyWith({
    String? id,
    String? title,
    String? description,
    String? thumbnailUrl,
    List<Song>? songs,
    bool? isSystem,
  }) {
    return Playlist(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      songs: songs ?? this.songs,
      isSystem: isSystem ?? this.isSystem,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'thumbnailUrl': thumbnailUrl,
      'songs': songs.map((x) => x.toMap()).toList(),
      'isSystem': isSystem,
    };
  }

  factory Playlist.fromMap(Map<String, dynamic> map) {
    return Playlist(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? 'Playlist',
      description: map['description'] as String?,
      thumbnailUrl: map['thumbnailUrl'] as String?,
      songs: (map['songs'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((x) => Song.fromMap(Map<String, dynamic>.from(x)))
              .toList() ??
          [],
      isSystem: map['isSystem'] as bool? ?? false,
    );
  }
}
