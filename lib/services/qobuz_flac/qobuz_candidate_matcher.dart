import '../../models/song.dart';

/// I campi con cui si identifica un brano da cercare su Qobuz. L'ISRC è
/// l'identificatore più preciso, quando c'è; altrimenti contano artista +
/// titolo, con la durata a scartare le versioni sbagliate (live, extended).
class QobuzTrackQuery {
  const QobuzTrackQuery({
    required this.artist,
    required this.title,
    this.album,
    this.isrc,
    this.durationMs,
  });

  final String artist;
  final String title;
  final String? album;
  final String? isrc;
  final int? durationMs;

  /// La query che si ricava da un brano di Totorify (che l'ISRC non lo ha).
  factory QobuzTrackQuery.of(Song song) => QobuzTrackQuery(
        artist: song.artist,
        title: song.title,
        album: song.album,
        durationMs: song.duration > Duration.zero ? song.duration.inMilliseconds : null,
      );

  /// I termini di ricerca da provare, in ordine di priorità:
  ///  1. l'ISRC, quando c'è (indice preciso);
  ///  2. "artista titolo" per intero (un artista solo il cui nome contiene
  ///     una virgola resta così com'è);
  ///  3. solo l'artista principale (prima della virgola), per i crediti
  ///     multipli tipo "¥$, Kanye West, Ty Dolla $ign".
  List<String> searchTerms() {
    final terms = <String>[];
    final isrc = this.isrc;
    if (isrc != null && isrc.isNotEmpty) terms.add(isrc);
    final full = '$artist $title'.trim();
    if (full.isNotEmpty) terms.add(full);
    final primary = artist.split(',').first.trim();
    if (primary.isNotEmpty && primary.toLowerCase() != artist.trim().toLowerCase()) {
      terms.add('$primary $title'.trim());
    }
    return terms.toSet().toList();
  }
}

/// Quanto bene un candidato del catalogo Qobuz somiglia alla query — port
/// esatto di QobuzCandidateMatcher del riferimento.
class QobuzCandidateMatcher {
  const QobuzCandidateMatcher._();

  /// Sotto questa soglia il candidato è scartato.
  static const double minConfidence = 0.5;

  /// Il punteggio di confidenza in [0, 1]. L'ISRC uguale vale 0.95 (stessa
  /// registrazione, stesso master); altrimenti si combinano la somiglianza
  /// del titolo e dell'artista con una penalità sulla durata, che sfavorisce
  /// i tagli diversi (live, edit) senza scartarli del tutto.
  ///
  /// [candDurationSec] è in SECONDI, l'unità di Qobuz.
  static double confidence({
    required QobuzTrackQuery query,
    required String candTitle,
    required String candArtist,
    required String? candIsrc,
    required int candDurationSec,
    required bool candStreamable,
  }) {
    if (!candStreamable) return 0;

    final queryIsrc = (query.isrc ?? '').trim();
    final candidateIsrc = (candIsrc ?? '').trim();
    if (queryIsrc.isNotEmpty &&
        candidateIsrc.isNotEmpty &&
        queryIsrc.toLowerCase() == candidateIsrc.toLowerCase()) {
      return 0.95;
    }

    final titleSim = jaccard(normalize(query.title), normalize(candTitle));
    // I cataloghi espandono i nomi degli artisti in modo diverso ("Diana
    // Ross and the Supremes" contro "The Supremes"): la somiglianza tra
    // artisti non deve penalizzare i sottoinsiemi.
    final artistSim = artistSimilarity(normalize(query.artist), normalize(candArtist));

    final queryMs = query.durationMs;
    var durationFactor = 1.0;
    if (queryMs != null && queryMs > 0 && candDurationSec > 0) {
      final drift = (queryMs - candDurationSec * 1000).abs() / queryMs;
      if (drift < 0.05) {
        durationFactor = 1.0; // stesso taglio quasi certamente
      } else if (drift < 0.10) {
        durationFactor = 0.85; // differenza tipica di compressione
      } else if (drift < 0.20) {
        durationFactor = 0.6; // forse un altro taglio
      } else {
        durationFactor = 0.3; // live contro studio, ecc.
      }
    }

    return titleSim * artistSim * durationFactor;
  }

  // ── Funzioni pure ─────────────────────────────────────────────────────

  static final RegExp _parenthetical = RegExp(r'\([^)]*\)');
  static final RegExp _bracketed = RegExp(r'\[[^\]]*\]');
  static final RegExp _featuring = RegExp(r'\b(feat\.?|ft\.?|featuring)\b.*');
  // Apostrofi (dritti e curvi) e backtick: vanno tolti PRIMA della
  // punteggiatura, altrimenti "don't" diventa "don t" invece di "dont".
  static final RegExp _apostrophes = RegExp("['\u2018\u2019`]");
  // Lettere, numeri e simboli (¥$, $NOT, +44…) restano: la punteggiatura no.
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}\p{S}\s]', unicode: true);
  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  /// Minuscole, via parentesi e "feat.", via apostrofi e punteggiatura;
  /// spazi collassati.
  static String normalize(String value) => value
      .toLowerCase()
      .replaceAll(_parenthetical, ' ')
      .replaceAll(_bracketed, ' ')
      .replaceAll(_featuring, ' ')
      .replaceAll(_apostrophes, '')
      .replaceAll(_nonWord, ' ')
      .replaceAll(_spaces, ' ')
      .trim();

  /// Somiglianza di Jaccard sui token.
  static double jaccard(String a, String b) {
    final setA = a.split(' ').where((t) => t.isNotEmpty).toSet();
    final setB = b.split(' ').where((t) => t.isNotEmpty).toSet();
    if (setA.isEmpty || setB.isEmpty) return 0;
    final intersection = setA.intersection(setB).length.toDouble();
    final union = setA.union(setB).length.toDouble();
    return intersection / union;
  }

  /// La somiglianza tra artisti: il massimo tra Jaccard e la copertura del
  /// sottoinsieme. Quest'ultima vale 1.0 quando l'artista più corto è tutto
  /// contenuto nel più lungo E almeno un token condiviso è "distintivo"
  /// (più lungo di 3 caratteri, o con un simbolo): è il caso tipico
  /// "creditone" contro nome canonico del catalogo.
  static double artistSimilarity(String a, String b) {
    final setA = a.split(' ').where((t) => t.isNotEmpty).toSet();
    final setB = b.split(' ').where((t) => t.isNotEmpty).toSet();
    if (setA.isEmpty || setB.isEmpty) return 0;

    final intersection = setA.intersection(setB);
    final union = setA.union(setB);
    final jaccardScore = intersection.length / union.length;

    final smallerSize = setA.length < setB.length ? setA.length : setB.length;
    final smallerFullyCovered = intersection.length == smallerSize;
    final hasDistinctiveOverlap = intersection.any(
      (token) => token.length > 3 || _notLetterOrDigit.hasMatch(token),
    );

    final coverageScore = smallerFullyCovered && hasDistinctiveOverlap ? 1.0 : 0.0;
    return jaccardScore > coverageScore ? jaccardScore : coverageScore;
  }
}
