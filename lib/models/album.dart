/// A release in the catalog: an album, a single or an EP.
class Album {
  /// Catalog id of the release page.
  final String id;
  final String title;
  final String artist;

  /// "Album", "Singolo" or "EP".
  final String type;
  final String year;
  final String coverUrl;

  const Album({
    required this.id,
    required this.title,
    required this.artist,
    this.type = 'Album',
    this.year = '',
    this.coverUrl = '',
  });

  /// "Singolo • 2024", or what is known of it.
  String get caption => [type, if (year.isNotEmpty) year].join(' • ');
}
