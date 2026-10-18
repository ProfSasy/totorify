import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Firma le richieste all'API Qobuz, esattamente come qbdlx (e YumaPlayer):
/// Qobuz valida `request_sig = md5(... + request_ts + app_secret)`, con i
/// parametri in un ordine letterale fisso, per endpoint.
///
/// La firma è stata verificata contro i vettori HAR reali del progetto di
/// riferimento (`QbdlxSignerTest`): due chiamate storiche a `getFileUrl`
/// (format 27 e 6) e una a `lyricsUrl` riproducono gli MD5 attesi.
class QobuzSigner {
  const QobuzSigner();

  /// Il timestamp della richiesta, in epoch SECONDI. Chi firma lo legge UNA
  /// volta sola e usa lo stesso valore sia nel parametro `request_ts` sia
  /// nella firma, così non possono divergere.
  int requestTs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// La firma per `track/getFileUrl`.
  ///
  /// [appSecret] è quello dell'app con cui è nato il token: firmare con un
  /// segreto di un'altra app fa rispondere a Qobuz un 200 con una preview di
  /// 30 secondi (`sample:true`), indistinguibile da "brano non disponibile"
  /// se non lo si sa.
  String signGetFileUrl({
    required int ts,
    required int trackId,
    required int formatId,
    required String appSecret,
  }) =>
      _md5('trackgetFileUrl'
          'format_id$formatId'
          'intentstream'
          'track_id$trackId'
          '$ts'
          '$appSecret');

  String _md5(String value) => md5.convert(utf8.encode(value)).toString();
}
