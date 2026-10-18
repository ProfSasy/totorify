import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../models/song.dart';
import '../app_settings.dart';
import '../playback_log_service.dart';
import 'qobuz_api_client.dart';
import 'qobuz_candidate_matcher.dart';
import 'qobuz_models.dart';
import 'qobuz_token_pool.dart';

/// Esito interno di un tentativo di `getFileUrl`.
sealed class _FlacOutcome {
  const _FlacOutcome();
}

class _FlacResolved extends _FlacOutcome {
  const _FlacResolved(this.result);

  final QobuzResolveOk result;
}

class _FlacDead extends _FlacOutcome {
  const _FlacDead();
}

class _FlacRegion extends _FlacOutcome {
  const _FlacRegion();
}

class _FlacAbort extends _FlacOutcome {
  const _FlacAbort();
}

/// Il servizio FLAC senza perdita: risolve un brano di Totorify in uno
/// stream Qobuz firmato, come fa il motore del riferimento (flaccore/qbdlx).
///
/// Porta, nello stesso ordine: la ricerca nel catalogo con rotazione dei
/// token morti, il matching dei candidati, la firma MD5 di `getFileUrl` e
/// la risoluzione per regione su un brano bloccato. Qualunque passo fallisca
/// la risposta è null: chi chiama (il lettore) riproduce da YouTube come
/// sempre.
class QobuzFlacService {
  QobuzFlacService._();

  static final QobuzFlacService instance = QobuzFlacService._();

  // ── Credenziali (nel keychain, mai in un backup) ───────────────────────

  static const String _appIdKey = 'qobuz_app_id';
  static const String _appSecretKey = 'qobuz_app_secret';
  static const String _tokenKey = 'qobuz_user_auth_token';

  /// La coppia pubblica con cui è firmato il client qbdlx: sono i valori
  /// reali catturati nei vettori HAR del progetto di riferimento. L'utente
  /// può sovrascriverli dalle impostazioni.
  static const String defaultAppId = '798273057';
  static const String defaultAppSecret = 'abb21364945c0583309667d13ca3d93a';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final QobuzApiClient _api = QobuzApiClient();
  final QobuzTokenPool _pool = QobuzTokenPool();

  String _storedAppId = '';
  String _storedAppSecret = '';
  String _storedPool = '';
  Future<void>? _loading;

  /// True quando c'è almeno un token nel pool (le impostazioni lo mostrano).
  final ValueNotifier<bool> configuredNotifier = ValueNotifier(false);

  /// Quanti token contiene il pool.
  final ValueNotifier<int> poolCountNotifier = ValueNotifier(0);

  String get appId => _storedAppId.isEmpty ? defaultAppId : _storedAppId;
  String get appSecret => _storedAppSecret.isEmpty ? defaultAppSecret : _storedAppSecret;
  bool get appIdIsDefault => _storedAppId.isEmpty;
  bool get appSecretIsDefault => _storedAppSecret.isEmpty;
  String get tokenPool => _storedPool;
  int get poolTokenCount => _pool.length;

  /// Legge le credenziali dal keychain (una volta sola per avvio).
  Future<void> init() => _ensureLoaded();

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _storedAppId = await _secure.read(key: _appIdKey) ?? '';
      _storedAppSecret = await _secure.read(key: _appSecretKey) ?? '';
      _storedPool = await _secure.read(key: _tokenKey) ?? '';
    } catch (e) {
      debugPrint('QobuzFlacService: credenziali non leggibili ($e)');
    }
    _applyPool();
  }

  void _applyPool() {
    _pool.configure(primaryAppId: appId, primaryAppSecret: appSecret);
    _pool.poolRaw = _storedPool;
    poolCountNotifier.value = _pool.length;
    configuredNotifier.value = _storedPool.trim().isNotEmpty;
  }

  /// Salva l'App ID (stringa vuota = torna al predefinito).
  Future<void> setAppId(String? value) async {
    await _ensureLoaded();
    _storedAppId = value?.trim() ?? '';
    await _writeSecure(_appIdKey, _storedAppId);
    _applyPool();
  }

  /// Salva l'App Secret (stringa vuota = torna al predefinito).
  Future<void> setAppSecret(String? value) async {
    await _ensureLoaded();
    _storedAppSecret = value?.trim() ?? '';
    await _writeSecure(_appSecretKey, _storedAppSecret);
    _applyPool();
  }

  /// Salva il token (o il pool: più token separati da virgola).
  Future<void> setTokenPool(String? value) async {
    await _ensureLoaded();
    _storedPool = value?.trim() ?? '';
    await _writeSecure(_tokenKey, _storedPool);
    _applyPool();
  }

  Future<void> _writeSecure(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
    } catch (e) {
      debugPrint('QobuzFlacService: credenziale non salvata ($e)');
    }
  }

  // ── Qualità ────────────────────────────────────────────────────────────

  /// format_id di Qobuz: 6 = FLAC CD, 7 = Hi-Res 24/96, 27 = Max 24/192.
  static const List<(int, String)> qualityOptions = [
    (6, 'CD · 16 bit/44,1 kHz'),
    (7, 'Hi-Res · 24 bit/96 kHz'),
    (27, 'Max · 24 bit/192 kHz'),
  ];

  static String qualityLabel(int formatId) => switch (formatId) {
        6 => 'CD · 16 bit/44,1 kHz',
        7 => 'Hi-Res · 24 bit/96 kHz',
        _ => 'Max · 24 bit/192 kHz',
      };

  /// "24 bit/192 kHz" per lo stream risolto, per l'etichetta del player.
  static String describeQuality(QobuzStream stream) {
    final parts = <String>[
      if (stream.bitsPerSample > 0) '${stream.bitsPerSample} bit',
      if (stream.sampleRateHz > 0) '${(stream.sampleRateHz / 1000).round()} kHz',
    ];
    return parts.isEmpty ? 'FLAC' : parts.join('/');
  }

  /// Gli header con cui il riferimento riproduce le origini qbdlx.
  static const Map<String, String> playbackHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Referer': 'https://music.youtube.com/',
  };

  // ── Cache degli stream risolti ─────────────────────────────────────────

  // Gli URL firmati durano a lungo: risolverli due volte per lo stesso
  // brano nella stessa sessione è solo latenza. Margine di 60s sotto la
  // scadenza dichiarata, come il riferimento.
  static const int _cacheSafetyMs = 60 * 1000;
  static const int _cacheMaxEntries = 80;
  static const Duration _resolveTimeout = Duration(seconds: 10);

  final Map<String, QobuzStream> _streamCache = {};
  final Map<String, Future<QobuzStream?>> _inFlight = {};

  void _pruneCache() {
    while (_streamCache.length > _cacheMaxEntries) {
      _streamCache.remove(_streamCache.keys.first);
    }
  }

  QobuzStream? _cachedStream(String songId) {
    final entry = _streamCache[songId];
    if (entry == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (entry.expiresAtMs - _cacheSafetyMs <= now) {
      _streamCache.remove(songId);
      return null;
    }
    return entry;
  }

  /// Butta via l'URL risolto per [songId]: lo stream non era riproducibile.
  void discard(String songId) {
    _streamCache.remove(songId);
  }

  /// Riscalda in anticipo la cache per [song]: la prossima traccia parte
  /// senza attendere la risoluzione. No-op quando la funzione è spenta.
  Future<void> prefetch(Song song) async {
    if (!AppSettings.instance.flacEnabled.value) return;
    try {
      await resolve(song);
    } catch (e) {
      debugPrint('QobuzFlacService.prefetch: $e');
    }
  }

  // ── Risoluzione ────────────────────────────────────────────────────────

  /// Lo stream FLAC per [song], o null quando: la funzione è spenta, il pool
  /// è senza token vivi, la ricerca non trova niente di convincente, o la
  /// risoluzione fallisce. Chi chiama prosegue su YouTube.
  Future<QobuzStream?> resolve(Song song, {int? formatId}) async {
    if (!AppSettings.instance.flacEnabled.value) return null;
    await _ensureLoaded();

    if (_pool.allDead()) {
      PlaybackLogService.instance.log(
        'FLAC',
        'nessun token vivo nel pool: riproduco da YouTube',
      );
      return null;
    }

    final cached = _cachedStream(song.id);
    if (cached != null) return cached;

    final pending = _inFlight[song.id];
    if (pending != null) return pending;

    final job = _resolveUncached(song, formatId: formatId);
    _inFlight[song.id] = job;
    try {
      return await job;
    } finally {
      _inFlight.remove(song.id);
    }
  }

  Future<QobuzStream?> _resolveUncached(Song song, {int? formatId}) async {
    final log = PlaybackLogService.instance;
    final format = formatId ?? AppSettings.instance.flacQuality.value;
    final query = QobuzTrackQuery.of(song);
    log.log('FLAC', 'cerco "${query.title}" - ${query.artist} (formato $format)');
    try {
      final stream = await _resolveInternal(query, format).timeout(_resolveTimeout);
      if (stream == null) {
        log.log('FLAC', 'nessun risultato per "${song.title}": riproduco da YouTube');
        return null;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (stream.expiresAtMs - _cacheSafetyMs > now) {
        _streamCache[song.id] = stream;
        _pruneCache();
      }
      final minutes = ((stream.expiresAtMs - now) / 60000).floor();
      log.log(
        'FLAC',
        'risolto "${song.title}" in ${describeQuality(stream)} '
        '(scade tra $minutes min)',
      );
      return stream;
    } on TimeoutException {
      log.log(
        'FLAC',
        'risoluzione oltre il tempo massimo per "${song.title}": riproduco da YouTube',
      );
      return null;
    } catch (e, stack) {
      log.error('FLAC', 'risoluzione fallita per "${song.title}": $e', stack);
      return null;
    }
  }

  Future<QobuzStream?> _resolveInternal(QobuzTrackQuery query, int formatId) async {
    final match = await _search(query);
    if (match == null) return null;
    final (track, confidence, token) = match;
    return _resolveFile(track, confidence, token, formatId);
  }

  /// Ricerca + matching, con rotazione dei token morti. Il tried-set fa da
  /// terminatore: un pool finito si esaurisce.
  Future<(QobuzTrack, double, String)?> _search(QobuzTrackQuery query) async {
    final log = PlaybackLogService.instance;
    String? token = _pool.activeToken();
    if (token == null) return null;
    final tried = <String>{};
    var guard = 0;

    while (guard++ < QobuzTokenPool.maxTokenAttempts) {
      final current = token;
      if (current == null) return null;
      tried.add(current);
      try {
        for (final term in query.searchTerms()) {
          final candidates = await _api.search(
            query: term,
            token: current,
            appId: _pool.signingFor(current).appId,
          );
          (QobuzTrack, double)? best;
          for (final candidate in candidates) {
            final score = QobuzCandidateMatcher.confidence(
              query: query,
              candTitle: candidate.title,
              candArtist: candidate.performerName,
              candIsrc: candidate.isrc,
              candDurationSec: candidate.durationSec,
              candStreamable: candidate.streamable,
            );
            if (score >= QobuzCandidateMatcher.minConfidence &&
                (best == null || score > best.$2)) {
              best = (candidate, score);
            }
          }
          if (best != null) {
            log.log(
              'FLAC',
              'trovato "${best.$1.title}" (id ${best.$1.id}, confidenza '
              '${best.$2.toStringAsFixed(2)}) per "${query.title}"',
            );
            return (best.$1, best.$2, current);
          }
        }
        return null; // tutti i termini provati: nessun match
      } on QobuzAuthException catch (e) {
        // Token morto, non un guasto del servizio: si marca e si ruota.
        log.log('FLAC', 'token rifiutato (${e.status}) nella ricerca: passo a un altro');
        _pool.markDead(current);
        final next = _pool.activeToken();
        token = (next != null && !tried.contains(next)) ? next : null;
      } on QobuzApiException catch (e) {
        log.log('FLAC', 'ricerca non riuscita (HTTP ${e.status}): riproduco da YouTube');
        return null;
      }
    }
    return null;
  }

  /// Risolve [track] in un URL firmato, ruotando i token su morte e
  /// provando i token di altre regioni su un brano bloccato.
  Future<QobuzStream?> _resolveFile(
    QobuzTrack track,
    double confidence,
    String startToken,
    int formatId,
  ) async {
    final tried = <String>{};
    String? token = startToken;
    var guard = 0;

    while (token != null && guard++ < QobuzTokenPool.maxTokenAttempts) {
      if (!tried.add(token)) {
        final next = _pool.activeToken();
        token = (next != null && !tried.contains(next)) ? next : null;
        continue;
      }
      final outcome = await _resolveOnce(track, token, formatId);
      switch (outcome) {
        case _FlacResolved(:final result):
          _pool.recordAlive(token);
          return _build(track, result);
        case _FlacDead():
          _pool.markDead(token);
          final next = _pool.activeToken();
          token = (next != null && !tried.contains(next)) ? next : null;
        case _FlacRegion():
          // Il token va bene, il brano non è licenziato per i suoi diritti:
          // si provano altri token, senza marcare nessuno come morto.
          return _resolveRegion(track, tried, formatId);
        case _FlacAbort():
          return null;
      }
    }
    return null;
  }

  Future<QobuzStream?> _resolveRegion(
    QobuzTrack track,
    Set<String> tried,
    int formatId,
  ) async {
    for (final token in _pool.tokensForRegion(null)) {
      if (!tried.add(token)) continue;
      final outcome = await _resolveOnce(track, token, formatId);
      switch (outcome) {
        case _FlacResolved(:final result):
          _pool.recordAlive(token);
          return _build(track, result);
        case _FlacDead():
          _pool.markDead(token);
        case _FlacRegion():
          break; // ancora bloccato con questo token
        case _FlacAbort():
          return null;
      }
    }
    return null;
  }

  /// Un tentativo di `getFileUrl`, tradotto in esito.
  Future<_FlacOutcome> _resolveOnce(QobuzTrack track, String token, int formatId) async {
    try {
      final result = await _api.getFileUrl(
        trackId: track.id,
        formatId: formatId,
        token: token,
        signing: _pool.signingFor(token),
      );
      return switch (result) {
        QobuzResolveOk() => _FlacResolved(result),
        QobuzTokenDead() => const _FlacDead(),
        QobuzRegionLocked() => const _FlacRegion(),
      };
    } on QobuzAuthException {
      // Un 401 qui è lo stesso segnale di un corpo UserUnauthenticated.
      return const _FlacDead();
    } on QobuzApiException catch (e) {
      PlaybackLogService.instance
          .log('FLAC', 'richiesta dello stream non riuscita (HTTP ${e.status})');
      return const _FlacAbort();
    }
  }

  QobuzStream? _build(QobuzTrack track, QobuzResolveOk ok) {
    final expiresAtMs = _parseEtspMs(ok.url);
    if (expiresAtMs == null) {
      PlaybackLogService.instance.log('FLAC', 'URL firmato senza scadenza (etsp): scartato');
      return null;
    }
    return QobuzStream(
      url: ok.url,
      expiresAtMs: expiresAtMs,
      codec: ok.codec,
      bitsPerSample: ok.bitDepth,
      sampleRateHz: ok.sampleRateHz,
      coverArtUrl: track.coverArtUrl,
      trackId: track.id,
    );
  }

  /// La scadenza dell'URL firmato, dall'`etsp` in secondi.
  static int? _parseEtspMs(String url) {
    final match = RegExp(r'[?&]etsp=(\d+)').firstMatch(url);
    final seconds = int.tryParse(match?.group(1) ?? '');
    return seconds == null ? null : seconds * 1000;
  }

  // ── Verifica dei token (per le impostazioni) ───────────────────────────

  /// Prova ogni token del pool con una ricerca: dice quali rispondono e
  /// quali vanno rifatti. Non prova la qualità piena (che richiede un
  /// abbonamento attivo): solo che l'account autentichi.
  Future<String> verifyPool() async {
    await _ensureLoaded();
    final entries = _pool.entries;
    if (entries.isEmpty) return 'Nessun token nel pool.';

    final lines = <String>[];
    for (final entry in entries.take(20)) {
      final signing = _pool.signingFor(entry.token);
      try {
        await _api.search(
          query: 'daft punk',
          token: entry.token,
          appId: signing.appId,
          limit: 1,
        );
        _pool.recordAlive(entry.token);
        lines.add('\u2713 ${_shortToken(entry.token)} — risponde');
      } on QobuzAuthException {
        _pool.markDead(entry.token);
        lines.add('\u2717 ${_shortToken(entry.token)} — rifiutato: va rifatto');
      } on QobuzApiException catch (e) {
        lines.add('\u2717 ${_shortToken(entry.token)} — errore HTTP ${e.status}');
      } catch (_) {
        lines.add('\u2717 ${_shortToken(entry.token)} — non raggiungibile');
      }
    }
    if (entries.length > 20) {
      lines.add('… e altri ${entries.length - 20} token');
    }
    return lines.join('\n');
  }

  /// "••••" più la coda del token: riconoscibile senza mostrarlo.
  static String _shortToken(String token) =>
      token.length <= 6 ? '••••' : '••••${token.substring(token.length - 6)}';
}
