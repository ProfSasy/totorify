class Artist {
  /// Deezer artist id.
  final String id;
  final String name;
  final String imageUrl;
  final int fans;

  const Artist({
    required this.id,
    required this.name,
    this.imageUrl = '',
    this.fans = 0,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'imageUrl': imageUrl,
        'fans': fans,
      };

  factory Artist.fromMap(Map<String, dynamic> map) => Artist(
        id: map['id']?.toString() ?? '',
        name: map['name'] as String? ?? 'Artista sconosciuto',
        imageUrl: map['imageUrl'] as String? ?? '',
        fans: map['fans'] as int? ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Artist && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
