class Artist {
  /// Catalog id of the artist page (a YouTube Music channel, "UC…"). Artists
  /// followed with older versions carry a Deezer id instead: the artist page
  /// looks them up by name and replaces it.
  final String id;
  final String name;
  final String imageUrl;

  /// What the catalog says about the artist's following, already worded:
  /// "2,2 mln di ascoltatori al mese". Empty when unknown.
  final String audience;

  const Artist({
    required this.id,
    required this.name,
    this.imageUrl = '',
    this.audience = '',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'imageUrl': imageUrl,
        'audience': audience,
      };

  factory Artist.fromMap(Map<String, dynamic> map) => Artist(
        id: map['id']?.toString() ?? '',
        name: map['name'] as String? ?? 'Artista sconosciuto',
        imageUrl: map['imageUrl'] as String? ?? '',
        audience: map['audience'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Artist && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
