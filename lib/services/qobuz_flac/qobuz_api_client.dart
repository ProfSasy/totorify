import 'dart:convert';

import '../app_http.dart';
import 'qobuz_models.dart';
import 'qobuz_signer.dart';
import 'qobuz_token_pool.dart';

/// Un 401 (autenticazione) — distinto, così il chiamante può marcare il
/// token morto e ruotare.
class QobuzAuthException implements Exception {
  const QobuzAuthException(this.status, [this.detail = '']);

  final int status;
  final String detail;

  @override
  String toString() => 'QobuzAuthException($status): $detail';
}

/// Ogni altro fallimento (HTTP non-2xx, rete) — transitorio: NON si marca
/// nessun token come morto.
class QobuzApiException implements Exception {
  const QobuzApiException(this.status, [this.detail = '']);

  final int status;
  final String detail;

  @override
  String toString() => 'QobuzApiException($status): $detail';
}

/// La firma della richiesta non è (più) accettata: le chiavi dell'app sono
/// cambiate. Non dipende dal token, quindi non si ruota il pool: si
/// aggiornano le chiavi e si riprova una volta.
class QobuzSignatureException implements Exception {
  const QobuzSignatureException(this.status, [this.detail = '']);

  final int status;
  final String detail;

  @override
  String toString() => 'QobuzSignatureException($status): $detail';
}

/// L'accesso diretto all'API Qobuz, firmata a mano: la stessa origine, gli
/// stessi header e la stessa classificazione di qbdlx / del riferimento.
class QobuzApiClient {
  QobuzApiClient({QobuzSigner signer = const QobuzSigner()}) : _signer = signer;

  static const String _origin = 'https://www.qobuz.com';
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/149.0.0.0 Mobile Safari/537.36';

  final QobuzSigner _signer;

  /// Cerca nel catalogo Qobuz. Lancia [QobuzAuthException] su 401,
  /// [QobuzApiException] per il resto.
  Future<List<QobuzTrack>> search({
    required String query,
    required String token,
    required String appId,
    int limit = 10,
  }) async {
    final uri = Uri.parse('$_origin/api.json/0.2/catalog/search').replace(queryParameters: {
      'query': query,
      'type': 'tracks',
      'limit': '$limit',
      'app_id': appId,
    });
    final body = await _get(uri, token, appId);
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return const [];
      final tracks = json['tracks'];
      if (tracks is! Map<String, dynamic>) return const [];
      final items = tracks['items'];
      if (items is! List) return const [];
      return [
        for (final item in items)
          if (item is Map<String, dynamic>) QobuzTrack.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Risolve un track id in un URL FLAC firmato, classificato.
  Future<QobuzResolveResult> getFileUrl({
    required int trackId,
    required int formatId,
    required String token,
    required QobuzSigning signing,
  }) async {
    // Firma con la coppia (app_id, app_secret) DEL TOKEN: il pool può
    // comprendere più app e un account collegato porta la sua; con il
    // segreto sbagliato Qobuz risponde una preview di 30 secondi, non FLAC.
    // ts e sig sono letti UNA volta sola: il timestamp firmato e quello
    // spedito non possono divergere.
    final ts = _signer.requestTs();
    final sig = _signer.signGetFileUrl(
      ts: ts,
      trackId: trackId,
      formatId: formatId,
      appSecret: signing.appSecret,
    );
    final uri = Uri.parse('$_origin/api.json/0.2/track/getFileUrl').replace(queryParameters: {
      'track_id': '$trackId',
      'format_id': '$formatId',
      'app_id': signing.appId,
      'request_ts': '$ts',
      'request_sig': sig,
      'intent': 'stream',
    });
    final body = await _get(uri, token, signing.appId);
    return _classify(QobuzFileUrl.fromJson(jsonDecode(body) as Map<String, dynamic>));
  }

  /// La classificazione del corpo di `getFileUrl`, identica al riferimento.
  QobuzResolveResult _classify(QobuzFileUrl file) {
    final dead = file.sample ||
        file.formatId == 5 ||
        file.restrictionCodes.any((code) => code.toLowerCase() == 'userunauthenticated');
    if (dead) return const QobuzTokenDead();
    final url = file.url;
    if (url == null || url.isEmpty || file.formatId < 6) return const QobuzRegionLocked();
    // formatId >= 6: è sempre FLAC.
    return QobuzResolveOk(
      url: url,
      codec: 'flac',
      bitDepth: file.bitDepth,
      sampleRateHz: (file.samplingRate * 1000).toInt(),
    );
  }

  /// La GET comune. L'app_id è quello del TOKEN, mai una costante del
  /// client: Qobuz lega un `user_auth_token` all'app con cui è stato
  /// generato, e con un altro id la stessa token risponde 401.
  Future<String> _get(Uri url, String token, String appId) async {
    final response = await appHttp.get(
      url,
      headers: {
        'X-App-Id': appId,
        'X-User-Auth-Token': token,
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      },
    );
    final body = response.body;
    if (response.statusCode == 401) {
      throw QobuzAuthException(401, _snippet(body));
    }
    // Un account bannato è un TOKEN MORTO, non un guasto del servizio:
    // Qobuz risponde 403 USER_BLOCKED e va ruotato, non ritentato.
    if (response.statusCode == 403 && body.toUpperCase().contains('USER_BLOCKED')) {
      throw QobuzAuthException(403, _snippet(body));
    }
    // La firma è cambiata (Qobuz ruota le chiavi con le versioni del client
    // web): non è colpa del token, va rinfrescata la coppia dell'app.
    if (response.statusCode == 400 && body.toLowerCase().contains('signature')) {
      throw QobuzSignatureException(400, _snippet(body));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QobuzApiException(response.statusCode, _snippet(body));
    }
    return body;
  }

  /// Prova una coppia (app_id, app_secret) su `track/getFileUrl` con un
  /// token finto: nessun account serve. Qobuz risponde 400 "Invalid
  /// Request Signature" se la firma è sbagliata, 401 se la firma va bene e
  /// manca solo l'autenticazione — che è esattamente il discriminante.
  Future<bool> probeSignature({
    required String appId,
    required String appSecret,
  }) async {
    final ts = _signer.requestTs();
    final sig = _signer.signGetFileUrl(
      ts: ts,
      trackId: _probeTrackId,
      formatId: _probeFormatId,
      appSecret: appSecret,
    );
    final uri = Uri.parse('$_origin/api.json/0.2/track/getFileUrl').replace(queryParameters: {
      'track_id': '$_probeTrackId',
      'format_id': '$_probeFormatId',
      'app_id': appId,
      'request_ts': '$ts',
      'request_sig': sig,
      'intent': 'stream',
    });
    try {
      final response = await appHttp.get(
        uri,
        headers: {
          'X-App-Id': appId,
          'X-User-Auth-Token': 'probe',
          'Accept': 'application/json',
          'User-Agent': _userAgent,
        },
      ).timeout(const Duration(seconds: 10));
      return response.statusCode == 401 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// La sola raggiungibilità dell'API: lo status della ricerca (401 quando
  /// c'è e chiede l'account), oppure null se la rete non risponde.
  Future<int?> ping({required String appId}) async {
    try {
      final response = await appHttp.get(
        Uri.parse('$_origin/api.json/0.2/catalog/search').replace(queryParameters: {
          'query': 'a',
          'type': 'tracks',
          'limit': '1',
          'app_id': appId,
        }),
        headers: {
          'X-App-Id': appId,
          'X-User-Auth-Token': 'probe',
          'Accept': 'application/json',
          'User-Agent': _userAgent,
        },
      ).timeout(const Duration(seconds: 10));
      return response.statusCode;
    } catch (_) {
      return null;
    }
  }

  // Il brano e il formato con cui qopy (qobuz-dl) prova un segreto: fmt 5
  // è il più economico e la risposta 400/401 discrimina senza account.
  static const int _probeTrackId = 5966783;
  static const int _probeFormatId = 5;

  static String _snippet(String body) =>
      body.length <= 160 ? body : body.substring(0, 160);
}
