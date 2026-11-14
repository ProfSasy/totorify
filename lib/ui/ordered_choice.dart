/// Things the user can put in the order they like and hide one by one: the
/// tabs of the bar, the buttons of the player.
///
/// What is saved is the order chosen and the names hidden. Names the saved
/// order does not know (added by a later version) go where the design put
/// them among those that follow.
class OrderedChoice {
  const OrderedChoice(this.designed, {this.alwaysShown = const {}});

  /// Every item, in the order it was designed with.
  final List<String> designed;

  /// Items that cannot be hidden.
  final Set<String> alwaysShown;

  /// Every item in the order chosen.
  List<String> order(List<String> saved) {
    final known = <String>[];
    for (final id in saved) {
      if (designed.contains(id) && !known.contains(id)) known.add(id);
    }
    for (final id in designed) {
      if (known.contains(id)) continue;
      // Before the first item that comes after it in the design.
      final later = designed.sublist(designed.indexOf(id) + 1);
      final at = known.indexWhere(later.contains);
      at == -1 ? known.add(id) : known.insert(at, id);
    }
    return known;
  }

  /// The items to show, in order.
  List<String> visible(List<String> saved, List<String> hidden) => [
        for (final id in order(saved))
          if (alwaysShown.contains(id) || !hidden.contains(id)) id,
      ];

  /// [saved] after the item at [from] is dropped at [to] (the indices a
  /// reorderable list gives).
  List<String> moved(List<String> saved, int from, int to) {
    final items = order(saved);
    if (from < 0 || from >= items.length) return items;
    if (from < to) to -= 1;
    items.insert(to.clamp(0, items.length - 1), items.removeAt(from));
    return items;
  }
}

/// The tabs of the bar at the bottom.
class NavLayout {
  NavLayout._();

  static const String home = 'home';
  static const String search = 'search';
  static const String library = 'library';
  static const String create = 'create';

  static const OrderedChoice tabs = OrderedChoice(
    [home, search, library, create],
    // Without the Home there would be no way to the settings.
    alwaysShown: {home},
  );

  static const Map<String, (String, String)> labels = {
    home: ('Home', 'Sempre presente'),
    search: ('Cerca', ''),
    library: ('La tua libreria', ''),
    create: ('Crea', 'Apre il menu per creare o importare'),
  };
}

/// The buttons under the transport of the player.
class PlayerActions {
  PlayerActions._();

  static const String devices = 'devices';
  static const String sources = 'sources';
  static const String lyrics = 'lyrics';
  static const String queue = 'queue';

  static const OrderedChoice buttons = OrderedChoice([devices, sources, lyrics, queue]);

  static const Map<String, (String, String)> labels = {
    devices: ('Dispositivi', 'Dove suona la musica'),
    sources: ('Fonti alternative', 'Per cambiare versione del brano'),
    lyrics: ('Testo', ''),
    queue: ('Coda', ''),
  };
}

/// The buttons of the mini player, beside play and pause.
class MiniPlayerButtons {
  MiniPlayerButtons._();

  static const String devices = 'devices';
  static const String favorite = 'favorite';
  static const String previous = 'previous';
  static const String next = 'next';

  static const List<(String, String)> all = [
    (devices, 'Dispositivi'),
    (favorite, 'Preferito'),
    (previous, 'Brano precedente'),
    (next, 'Brano successivo'),
  ];
}
