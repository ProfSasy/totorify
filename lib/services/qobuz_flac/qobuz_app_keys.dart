import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_folder.dart';
import '../app_http.dart';
import 'qobuz_api_client.dart';

/// La coppia (app_id, app_secret) con cui si firmano le richieste Qobuz,
/// ricavata dal client web di Qobuz — la stessa tecnica di qbdlx/qobuz-dl.
///
/// Qobuz cambia le chiavi insieme alle versioni del suo player web: tenere
/// una coppia fissa nel codice significa vedere i brani degradare ad
/// anteprime (o rifiutati) il giorno in cui ruotano. Qui le chiavi si
/// ricavano dal bundle pubblico del player, si PROVANO contro l'API e si
/// mettono in cache.
///
/// Nota verificata sul campo (bundle 8.3.0-b029): il segreto usato per
/// FIRMARE non è il `production.api.appSecret` letterale (Qobuz lo rifiuta
/// con 400 "Invalid Request Signature"), ma quello derivato dai seed del
/// bundle, come fa qobuz-dl. Per questo i candidati sono i tre segreti
/// derivati, provati uno per uno.
class QobuzAppKeys {
  const QobuzAppKeys({
    required this.appId,
    required this.appSecret,
    required this.fetchedAt,
  });

  final String appId;
  final String appSecret;
  final DateTime fetchedAt;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static const String _loginUrl = 'https://play.qobuz.com/login';
  static const String _bundleOrigin = 'https://play.qobuz.com';

  /// Oltre questa dimensione il bundle non è quello che ci aspettiamo.
  static const int _maxBundleChars = 4 * 1024 * 1024;

  static final RegExp _bundlePath = RegExp(
    r'<script src="(/resources/\d+\.\d+\.\d+-[a-z]\d{3}/bundle\.js)"></script>',
  );
  static final RegExp _production = RegExp(
    r'production:\{api:\{appId:"(\d{9})",appSecret:"\w{32}"',
  );
  static final RegExp _seed = RegExp(
    r'[a-z]\.initialSeed\("([\w=]+)",window\.utimezone\.([a-z]+)\)',
  );

  /// L'app_id dichiarato dal client web di produzione.
  static String? parseAppId(String bundle) =>
      _production.firstMatch(bundle)?.group(1);

  /// I segreti candidati, derivati dai seed del bundle (metodo qobuz-dl):
  /// per ogni fuso il segreto è base64(seed + info + extras, senza gli
  /// ultimi 44 caratteri).
  static Map<String, String> deriveSecrets(String bundle) {
    final seeds = <String, List<String>>{};
    for (final match in _seed.allMatches(bundle)) {
      final timezone = match.group(2)!;
      seeds.putIfAbsent(timezone, () => ['', '', ''])[0] = match.group(1)!;
    }
    if (seeds.isEmpty) return {};

    final names = seeds.keys
        .map((timezone) => timezone[0].toUpperCase() + timezone.substring(1))
        .join('|');
    final infoExtras = RegExp(
      'name:"\\w+/($names)",info:"([\\w=]+)",extras:"([\\w=]+)"',
    );
    for (final match in infoExtras.allMatches(bundle)) {
      final timezone = match.group(1)!.toLowerCase();
      final parts = seeds[timezone];
      if (parts == null) continue;
      parts[1] = match.group(2)!;
      parts[2] = match.group(3)!;
    }

    final derived = <String, String>{};
    seeds.forEach((timezone, parts) {
      if (parts[1].isEmpty || parts[2].isEmpty) return;
      final joined = parts.join();
      if (joined.length <= 44) return;
      var encoded = joined.substring(0, joined.length - 44);
      while (encoded.length % 4 != 0) {
        encoded += '=';
      }
      try {
        derived[timezone] = utf8.decode(base64.decode(encoded));
      } catch (_) {
        // Un seed che non decodifica si salta: gli altri restano validi.
      }
    });
    return derived;
  }

  /// Scarica il client web, deriva i segreti e restituisce la prima coppia
  /// che l'API accetta davvero. Null se non ci riesce (rete, formato del
  /// bundle cambiato, nessun segreto accettato).
  static Future<QobuzAppKeys?> discover(QobuzApiClient client) async {
    final bundle = await _fetchBundle();
    if (bundle == null) return null;
    final appId = parseAppId(bundle);
    if (appId == null) return null;
    for (final secret in deriveSecrets(bundle).values) {
      if (secret.length != 32) continue;
      if (await client.probeSignature(appId: appId, appSecret: secret)) {
        return QobuzAppKeys(
          appId: appId,
          appSecret: secret,
          fetchedAt: DateTime.now(),
        );
      }
    }
    return null;
  }

  /// Scarica il bundle FERMANDOSI ai seed: bastano ~2,5 MB dei ~9,4 MB
  /// totali, e solo una volta ogni tanto.
  static Future<String?> _fetchBundle() async {
    try {
      final login = await appHttp
          .get(
            Uri.parse(_loginUrl),
            headers: {'User-Agent': _userAgent, 'Accept': 'text/html'},
          )
          .timeout(const Duration(seconds: 15));
      if (login.statusCode != 200) return null;
      final match = _bundlePath.firstMatch(login.body);
      if (match == null) return null;

      final request = http.Request('GET', Uri.parse('$_bundleOrigin${match.group(1)}'))
        ..headers.addAll({'User-Agent': _userAgent, 'Accept': '*/*'});
      final response =
          await appHttp.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;

      final chunks = <String>[];
      var length = 0;
      var seedsSeen = 0;
      var closed = false;
      final completer = Completer<String?>();
      late final StreamSubscription<String> subscription;

      void finish(String? value) {
        if (closed) return;
        closed = true;
        if (!completer.isCompleted) completer.complete(value);
        unawaited(subscription.cancel());
      }

      subscription = response.stream
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              chunks.add(chunk);
              length += chunk.length;
              seedsSeen += 'initialSeed('.allMatches(chunk).length;
              // I tre initialSeed stanno dopo produzione e info/extras:
              // quando li abbiamo visti, il resto del file non serve.
              if (seedsSeen >= 3) {
                finish(chunks.join());
              } else if (length > _maxBundleChars) {
                finish(null);
              }
            },
            onDone: () => finish(chunks.join()),
            onError: (_) => finish(null),
            cancelOnError: true,
          );

      return await completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          finish(null);
          return null;
        },
      );
    } catch (_) {
      return null;
    }
  }

  // ── Cache su disco ─────────────────────────────────────────────────────

  static const String _cacheFileName = 'qobuz_app_keys.json';

  static Future<File> _cacheFile() async {
    final directory = await appFolder();
    if (!await directory.exists()) await directory.create(recursive: true);
    return File('${directory.path}/$_cacheFileName');
  }

  /// L'ultima coppia scoperta, se c'è. Nessuna scadenza: se Qobuz la
  /// rifiuta, la firma fallisce, il servizio la rinfresca e riprova.
  static Future<QobuzAppKeys?> loadCached() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final appId = json['appId'] as String? ?? '';
      final appSecret = json['appSecret'] as String? ?? '';
      if (appId.length != 9 || appSecret.length != 32) return null;
      final fetchedAtMs = json['fetchedAtMs'];
      return QobuzAppKeys(
        appId: appId,
        appSecret: appSecret,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          fetchedAtMs is int ? fetchedAtMs : 0,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveCached(QobuzAppKeys keys) async {
    try {
      final file = await _cacheFile();
      await file.writeAsString(jsonEncode({
        'appId': keys.appId,
        'appSecret': keys.appSecret,
        'fetchedAtMs': keys.fetchedAt.millisecondsSinceEpoch,
      }));
    } catch (_) {
      // Una cache che non si scrive non deve fermare nulla.
    }
  }
}
