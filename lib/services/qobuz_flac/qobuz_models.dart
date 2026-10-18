/// I tipi dell'API Qobuz, come li legge il motore lossless del riferimento
/// (flaccore/qbdlx di YumaPlayer): stessi campi, stesse unità di misura.
library;

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

double _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return 0;
}

/// Un brano del catalogo Qobuz (risposta di `catalog/search`).
class QobuzTrack {
  const QobuzTrack({
    required this.id,
    required this.title,
    required this.isrc,
    required this.durationSec,
    required this.streamable,
    required this.performerName,
    required this.maximumBitDepth,
    required this.maximumSamplingRate,
    required this.imageLarge,
    required this.imageSmall,
    required this.imageThumbnail,
  });

  final int id;
  final String title;
  final String? isrc;

  /// Durata in SECONDI (l'unità dell'API Qobuz).
  final int durationSec;
  final bool streamable;
  final String performerName;
  final int maximumBitDepth;

  /// Frequenza massima in kHz (l'API risponde 44.1, 96, 192…).
  final double maximumSamplingRate;
  final String? imageLarge;
  final String? imageSmall;
  final String? imageThumbnail;

  factory QobuzTrack.fromJson(Map<String, dynamic> json) {
    final performer = json['performer'];
    final album = json['album'];
    final image = album is Map<String, dynamic> ? album['image'] : null;
    final images = image is Map<String, dynamic> ? image : const <String, dynamic>{};
    return QobuzTrack(
      id: _asInt(json['id']),
      title: json['title'] as String? ?? '',
      isrc: json['isrc'] as String?,
      durationSec: _asInt(json['duration']),
      streamable: json['streamable'] as bool? ?? true,
      performerName: performer is Map<String, dynamic>
          ? (performer['name'] as String? ?? '')
          : '',
      maximumBitDepth: _asInt(json['maximum_bit_depth']),
      maximumSamplingRate: _asDouble(json['maximum_sampling_rate']),
      imageLarge: images['large'] as String?,
      imageSmall: images['small'] as String?,
      imageThumbnail: images['thumbnail'] as String?,
    );
  }

  /// La copertina migliore che l'album offre.
  String? get coverArtUrl => imageLarge ?? imageThumbnail ?? imageSmall;
}

/// La risposta di `track/getFileUrl`, grezza.
class QobuzFileUrl {
  const QobuzFileUrl({
    required this.url,
    required this.formatId,
    required this.bitDepth,
    required this.samplingRate,
    required this.sample,
    required this.restrictionCodes,
  });

  final String? url;
  final int formatId;
  final int bitDepth;

  /// Frequenza di campionamento in kHz, come la dichiara Qobuz.
  final double samplingRate;

  /// True quando Qobuz ha servito una PREVIEW di 30 secondi invece del
  /// brano intero: succede quando il token è scaduto o la firma è di un'app
  /// diversa da quella del token.
  final bool sample;
  final List<String> restrictionCodes;

  factory QobuzFileUrl.fromJson(Map<String, dynamic> json) {
    final restrictions = json['restrictions'];
    return QobuzFileUrl(
      url: json['url'] as String?,
      formatId: _asInt(json['format_id']),
      bitDepth: _asInt(json['bit_depth']),
      samplingRate: _asDouble(json['sampling_rate']),
      sample: json['sample'] as bool? ?? false,
      restrictionCodes: [
        if (restrictions is List)
          for (final entry in restrictions)
            if (entry is Map<String, dynamic>)
              entry['code'] as String? ?? '',
      ],
    );
  }
}

/// Esito di `getFileUrl`, classificato dal corpo JSON — identico al
/// riferimento: un token morto fa ruotare, un brano non licenziato per la
/// regione fa provare altri token, il resto è uno stream FLAC.
sealed class QobuzResolveResult {
  const QobuzResolveResult();
}

class QobuzResolveOk extends QobuzResolveResult {
  const QobuzResolveOk({
    required this.url,
    required this.codec,
    required this.bitDepth,
    required this.sampleRateHz,
  });

  final String url;
  final String codec;
  final int bitDepth;
  final int sampleRateHz;
}

/// Il token non autentica più (preview, format 5, UserUnauthenticated):
/// va marcato morto e sostituito.
class QobuzTokenDead extends QobuzResolveResult {
  const QobuzTokenDead();
}

/// Il token va bene, il brano non è licenziato per la sua regione.
class QobuzRegionLocked extends QobuzResolveResult {
  const QobuzRegionLocked();
}

/// Uno stream FLAC risolto, pronto per il lettore.
class QobuzStream {
  const QobuzStream({
    required this.url,
    required this.expiresAtMs,
    required this.codec,
    required this.bitsPerSample,
    required this.sampleRateHz,
    required this.coverArtUrl,
    required this.trackId,
  });

  final String url;

  /// Quando l'URL firmato scade (epoch ms, dal parametro `etsp`).
  final int expiresAtMs;
  final String codec;
  final int bitsPerSample;
  final int sampleRateHz;
  final String? coverArtUrl;
  final int trackId;
}
