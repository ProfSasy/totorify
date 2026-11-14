/// The sections of the Home, and the order the user wants them in.
class HomeLayout {
  HomeLayout._();

  static const String quick = 'quick';
  static const String pinned = 'pinned';
  static const String aiMix = 'ai_mix';
  static const String mixes = 'mixes';
  static const String recent = 'recent';
  static const String stats = 'stats';
  static const String artists = 'artists';
  static const String playlists = 'playlists';
  static const String charts = 'charts';
  static const String listenNow = 'listen_now';

  /// Every section, in the order the Home was designed with.
  static const List<String> defaultOrder = [
    quick,
    pinned,
    aiMix,
    mixes,
    recent,
    stats,
    artists,
    playlists,
    charts,
    listenNow,
  ];

  /// What each section is called in the settings, and what it shows.
  static const Map<String, (String, String)> labels = {
    quick: ('Accesso rapido', 'La griglia in cima: preferiti e ultimi ascolti'),
    pinned: ('Fissati', 'Playlist, artisti e brani che hai fissato'),
    aiMix: ('Mix con l\'IA', 'Compare se hai configurato l\'intelligenza artificiale'),
    mixes: ('Mix per te', 'Dagli artisti che ascolti di più'),
    recent: ('Ascoltati di recente', 'Gli ultimi brani'),
    stats: ('Più ascoltati e da riascoltare', 'Dalle tue statistiche'),
    artists: ('I tuoi artisti', 'Gli artisti che segui'),
    playlists: ('Le tue playlist', 'Quelle che hai creato o importato'),
    charts: ('Classifiche e novità', 'Le playlist editoriali'),
    listenNow: ('Da ascoltare ora', 'I brani per categoria, in fondo'),
  };

  /// Every section in the order chosen: [saved] first, as far as it names
  /// sections that exist, then the ones it does not know (added by a later
  /// version), where the design put them among those that follow.
  static List<String> order(List<String> saved) {
    final known = <String>[];
    for (final id in saved) {
      if (defaultOrder.contains(id) && !known.contains(id)) known.add(id);
    }
    for (final id in defaultOrder) {
      if (known.contains(id)) continue;
      // Before the first section that comes after it in the design.
      final later = defaultOrder.sublist(defaultOrder.indexOf(id) + 1);
      final at = known.indexWhere(later.contains);
      at == -1 ? known.add(id) : known.insert(at, id);
    }
    return known;
  }

  /// The sections to show, in order: [saved] without those in [hidden].
  static List<String> visible(List<String> saved, List<String> hidden) =>
      [for (final id in order(saved)) if (!hidden.contains(id)) id];
}
