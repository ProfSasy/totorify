import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../models/song.dart';
import '../app_settings.dart';
import '../playback_log_service.dart';
import '../qobuz_flac/qobuz_candidate_matcher.dart';

/// Uno stream già pronto dal bridge: l'URL del file sulla CDN di
/// flacdownloader (audio/flac o mp3, `Accept-Ranges: bytes`: suona in
/// streaming e si scarica a blocchi), con i metadati che il job riporta.
class FlacDlStream {
  const FlacDlStream({
    required this.url,
    required this.name,
    required this.format,
    required this.size,
    required this.resolvedAt,
  });

  final String url;
  final String name;
  final String format;
  final int size;
  final DateTime resolvedAt;

  bool get isFlac => url.toLowerCase().contains('.flac');
}

/// FLAC senza credenziali: parla con il bridge locale (vedi `bridge/README.md`
/// — un Turnstile umano ogni tanto sul PC, il rinnovo va da solo) e cerca nel
/// catalogo Qobuz con le chiavi correnti che il sito pubblica su
/// `/api/qobuz/keys` — firma identica a quella di `qobuz_signer.dart`.
///
/// I ruoli: l'app chiede al bridge solo l'URL finale del file (lì vivono la
/// sessione e il job, e il traffico verso il sito parte dall'IP di casa);
/// l'URL poi va riprodotto (`cdnHeaders`) o scaricato a blocchi come i m4a.
class FlacDlService {
  static final FlacDlService instance = FlacDlService._internal();
  FlacDlService._internal();

  /// UA con cui la CDN ha risposto 200/206 in ogni prova: niente cookie,
  /// niente token nel link del file.
  static const String _cdnUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 '
      'Safari/537.36';

  /// Header per riprodurre e scaricare i file della CDN.
  static const Map<String, String> cdnHeaders = {'User-Agent': _cdnUa};

  static const String _site = 'https://flacdownloader.com';
  static const String _qobuzApi = 'https://www.qobuz.com/api.json/0.2';

  static const Duration _keysLife = Duration(minutes: 5);
  static const Duration _cacheLife = Duration(hours: 6);
  static const Duration _deadCooldown = Duration(minutes: 10);

  String _appId = '';
  String _appSecret = '';
  DateTime _keysAt = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<String, FlacDlStream> _cache = {};
  final Map<String, DateTime> _dead = {};

  /// `http://<host>:7491` senza barre finali, o '' se non impostato.
  String get _bridgeUrl {
    var raw = AppSettings.instance.flacDlBridge.value.trim();
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    return raw;
  }

  // ── Bridge ──────────────────────────────────────────────────────────────

  /// `{alive, needHuman, expiry, expiresInSec}`, o null se irraggiungibile
  /// (e per una LAN: timeout corti).
  Future<Map<String, dynamic>?> health() async {
    final bridge = _bridgeUrl;
    if (bridge.isEmpty) return null;
    final r = await _get('$bridge/health', const Duration(seconds: 5));
    if (r == null || r.status != 200) return null;
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> alive() async {
    final h = await health();
    return h != null && h['alive'] == true;
  }

  // ── Qobuz con le chiavi del sito ─────────────────────────────────────────

  /// `{appId, appSecret}` correnti, cache 5 min come succede nei browser.
  Future<({String appId, String secret})?> _keys() async {
    if (_appSecret.isNotEmpty &&
        DateTime.now().difference(_keysAt) < _keysLife) {
      return (appId: _appId, secret: _appSecret);
    }
    final r = await _get(
      '$_site/api/qobuz/keys',
      const Duration(seconds: 8),
      headers: cdnHeaders,
    );
    if (r == null || r.status != 200) return null;
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final appId = '${j['appId'] ?? ''}';
      final secret = '${j['appSecret'] ?? ''}';
      if (appId.isEmpty || secret.isEmpty) return null;
      _appId = appId;
      _appSecret = secret;
      _keysAt = DateTime.now();
      return (appId: appId, secret: secret);
    } catch (_) {
      return null;
    }
  }

  /// Firma Qobuz: `md5('<metodo><chiave><valore>…[chiavi A-z]<ts><segreto>)`.
  String _sign(String method, Map<String, String> params, String appSecret) {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final concat = <String>[];
    for (final k in params.keys.toList()..sort()) {
      concat.add('$k${params[k]}');
    }
    return md5
        .convert(utf8.encode('$method${concat.join()}$ts$appSecret'))
        .toString();
  }

  /// Ricerca firmata nel catalogo Qobuz; [] quando fallisce.
  Future<List<Map<String, dynamic>>> _search(String query) async {
    final k = await _keys();
    if (k == null) return const [];
    final sig = _sign('catalogsearch', {'limit': '20', 'offset': '0', 'query': query}, k.secret);
    final u = Uri.parse(
      '$_qobuzApi/catalog/search?limit=20&offset=0'
      '&query=${Uri.encodeQueryComponent(query)}'
      '&app_id=${Uri.encodeQueryComponent(k.appId)}'
      '&request_sig=${Uri.encodeQueryComponent(sig)}',
    );
    final r = await _get('$u', const Duration(seconds: 9));
    if (r == null || r.status != 200) return const [];
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final items = (j['tracks'] as Map<String, dynamic>?)?['items'];
      if (items is! List) return const [];
      return [
        for (final i in items) if (i is Map<String, dynamic>) i,
      ];
    } catch (_) {
      return const [];
    }
  }

  // ── Risoluzione ───────────────────────────────────────────────────────────

  /// Risolve [song] in FLAC: match di confidenza ≥ 0.5 nel catalogo, poi il
  /// job sul bridge. Null se il bridge è spento/senza sessione, la
  /// confidenza non basta o il job fallisce: chi chiama prosegue con le
  /// sorgenti abituali (Qobuz, YouTube) senza rumore.
  Future<FlacDlStream?> resolveDownload(Song song) async {
    if (_bridgeUrl.isEmpty) {
      PlaybackLogService.instance.log(
        'FLACDL',
        'Bridge non configurato: URL vuoto (Impostazioni ▸ Riproduzione ▸ FLAC)',
      );
      return null;
    }
    final now = DateTime.now();
    final hit = _cache[song.id];
    if (hit != null && now.difference(hit.resolvedAt) < _cacheLife) {
      return hit;
    }
    final dead = _dead[song.id];
    if (dead != null && now.difference(dead) < _deadCooldown) return null;

    final stream = await _resolveRemote(song);
    if (stream == null) {
      _dead[song.id] = now;
      return null;
    }
    _cache[song.id] = stream;
    _dead.remove(song.id);
    return stream;
  }

  /// Helper per `prefetch(L song)`-like: risolve ignorando i ritorni.
  Future<void> prefetch(Song song) async {
    unawaited(resolveDownload(song).then((_) {}, onError: (_) {}));
    await Future<void>.value();
  }

  /// Dimentica una risoluzione (riprovato subito dopo un fallimento:
  /// per esempio un file della CDN sparito).
  Future<void> discard(String songId) async {
    _cache.remove(songId);
    _dead.remove(songId);
  }

  Future<FlacDlStream?> _resolveRemote(Song song) async {
    final log = PlaybackLogService.instance;
    if (!await alive()) {
      log.log(
        'FLACDL',
        'Bridge spento o sessione senza Turnstile: flacdl disattivo',
      );
      return null;
    }

    final query = QobuzTrackQuery.of(song);
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final term in query.searchTerms()) {
      for (final item in await _search(term)) {
        final artistItem = item['performer'];
        final score = QobuzCandidateMatcher.confidence(
          query: query,
          candTitle: '${item['title'] ?? ''}',
          candArtist:
              artistItem is Map<String, dynamic> ? '${artistItem['name'] ?? ''}' : '',
          candIsrc: item['isrc']?.toString(),
          candDurationSec:
              item['duration'] is num ? (item['duration'] as num).toInt() : 0,
          candStreamable: item['streamable'] == true,
        );
        if (score > bestScore) {
          best = item;
          bestScore = score;
        }
      }
      if (bestScore >= 0.95) break;
    }
    if (best == null || bestScore < QobuzCandidateMatcher.minConfidence) {
      log.log(
        'FLACDL',
        '"${song.title}": nessun match fidato nel catalogo '
        '(migliore ${bestScore.toStringAsFixed(2)})',
      );
      return null;
    }
    final trackId = best['id'];
    if (trackId == null) return null;

    final album = best['album'];
    final performer = best['performer'];
    var albumTitle = song.album ?? '';
    var albumArtist = song.artist;
    String? cover;
    String trackTotal = '';
    if (album is Map<String, dynamic>) {
      albumTitle = '${album['title'] ?? ''}';
      trackTotal = '${album['tracks_count'] ?? ''}';
      final images = album['image'];
      if (images is Map<String, dynamic>) {
        final large = images['large'];
        if (large is String && large.isNotEmpty) cover = large;
      }
      final albumArt = album['artist'];
      if (albumArt is Map<String, dynamic>) {
        final name = albumArt['name'];
        if (name is String && name.isNotEmpty) albumArtist = name;
      }
    }
    final body = <String, Object?>{
      'trackId': '$trackId',
      'title': '${best['title'] ?? song.title}',
      'artist':
          performer is Map<String, dynamic> ? '${performer['name'] ?? ''}' : song.artist,
      'album': albumTitle,
      'cover': cover,
      'albumArtist': albumArtist,
      'trackNumber': best['track_number']?.toString() ?? '',
      'trackTotal': trackTotal,
      'isrc': '${best['isrc'] ?? ''}',
      'bitDepth': best['maximum_bit_depth'] ?? 16,
      'samplingRate': best['maximum_sampling_rate'] ?? 44.1,
      'hires': best['hires_streamable'] == true,
    };
    final done = await _job(body);
    if (done == null) {
      log.log(
        'FLACDL',
        '"${song.title}": job non completato (confidenza '
        '${bestScore.toStringAsFixed(2)})',
      );
      return null;
    }
    log.log(
      'FLACDL',
      '"${song.title}" → ${done.name} '
      '(${(done.size / (1024 * 1024)).toStringAsFixed(1)} MB · '
      'confidenza ${bestScore.toStringAsFixed(2)})',
    );
    return done;
  }

  Future<FlacDlStream?> _job(Map<String, Object?> body) async {
    final j = await _postJson('$_bridgeUrl/job', body, const Duration(seconds: 300));
    if (j == null || j['status'] != 'done') return null;
    final url = '${j['url'] ?? ''}';
    if (url.isEmpty) return null;
    return FlacDlStream(
      url: url,
      name: '${j['name'] ?? ''}',
      format: '${j['format'] ?? 'flac'}',
      size: j['size'] is num ? (j['size'] as num).toInt() : 0,
      resolvedAt: DateTime.now(),
    );
  }

  /// Etichetta della sorgente che il player mostra in status.
  String describeQuality(FlacDlStream stream) =>
      '${stream.isFlac ? 'FLAC' : 'MP3'} · bridge';

  // ── HTTP minimi su HttpClient (già in dardo) ─────────────────────────────

  Future<({int status, String body})?> _get(
    String url,
    Duration timeout, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      return (status: resp.statusCode, body: body);
    } catch (e) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _postJson(
    String url,
    Object body,
    Duration timeout,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl('POST', Uri.parse(url)).timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      try {
        final j = jsonDecode(text);
        if (j is Map<String, dynamic>) return j;
      } catch (_) {}
      return null;
    } catch (e) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
