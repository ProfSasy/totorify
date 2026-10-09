import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'storage_service.dart';

/// Access token of Spotify's own web player, obtained from the user's
/// `sp_dc` session cookie. It is what the canvas endpoint asks for.
class SpotifyInternalAuthService {
  static final SpotifyInternalAuthService instance = SpotifyInternalAuthService._internal();
  SpotifyInternalAuthService._internal();

  static const _serverTimeUrl = 'https://open.spotify.com/api/server-time';
  // Secrets of the web player's one-time code, which Spotify rotates.
  static const _secretsUrl =
      'https://gist.githubusercontent.com/sonic-liberation/22ed9c6ba463899e933427f7de1f0eef/raw/nuances.json';
  static const _tokenUrl = 'https://open.spotify.com/api/token';

  static const Duration _requestTimeout = Duration(seconds: 8);
  // After a failure the three requests are not repeated for every song.
  static const Duration _retryAfterFailure = Duration(minutes: 2);
  static const Duration _defaultValidity = Duration(minutes: 55);

  String? _accessToken;
  DateTime? _expiresAt;
  DateTime? _retryAt;
  Future<String?>? _inFlight;

  /// Stores the session cookie; an empty value logs out.
  Future<void> saveSpDcCookie(String spDc) async {
    await StorageService.instance.setSpDcCookie(spDc);
    _accessToken = null;
    _expiresAt = null;
    _retryAt = null;
  }

  bool get hasSpDcCookie {
    final cookie = StorageService.instance.spDcCookie;
    return cookie != null && cookie.isNotEmpty;
  }

  /// A valid access token, or null without a login or when Spotify refuses
  /// the cookie. Callers asking at the same time share one request.
  Future<String?> getInternalAccessToken() {
    final now = DateTime.now();
    final expiresAt = _expiresAt;
    if (_accessToken != null && expiresAt != null && now.isBefore(expiresAt)) {
      return Future.value(_accessToken);
    }
    if (!hasSpDcCookie) return Future.value(null);
    final retryAt = _retryAt;
    if (retryAt != null && now.isBefore(retryAt)) return Future.value(null);

    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _requestToken();
    _inFlight = future;
    // Block body on purpose: the callback must not return the future.
    return future.whenComplete(() {
      _inFlight = null;
    });
  }

  Future<String?> _requestToken() async {
    final spDc = StorageService.instance.spDcCookie ?? '';
    try {
      final (code, version) = await _oneTimeCode();
      final response = await http.get(
        Uri.parse(
          '$_tokenUrl?reason=transport&productType=web-player'
          '&totp=$code&totpServer=$code&totpVer=$version',
        ),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Cookie': 'sp_dc=$spDc',
        },
      ).timeout(_requestTimeout);

      if (response.statusCode != 200) {
        debugPrint('SpotifyInternalAuth: HTTP ${response.statusCode}');
        return _failed();
      }
      final data = json.decode(response.body) as Map<String, dynamic>;
      final token = data['accessToken'] as String?;
      if ((data['isAnonymous'] as bool? ?? true) || token == null || token.isEmpty) {
        debugPrint('SpotifyInternalAuth: cookie sp_dc non valido o scaduto');
        return _failed();
      }

      final expiryMs = (data['accessTokenExpirationTimestampMs'] as num?)?.toInt();
      final expiry = expiryMs == null
          ? DateTime.now().add(_defaultValidity)
          // A minute early, so a token is never used on its last breath.
          : DateTime.fromMillisecondsSinceEpoch(expiryMs).subtract(const Duration(minutes: 1));
      _accessToken = token;
      _expiresAt = expiry;
      _retryAt = null;
      return token;
    } catch (e) {
      debugPrint('SpotifyInternalAuth: token non ottenuto: $e');
      return _failed();
    }
  }

  String? _failed() {
    _accessToken = null;
    _expiresAt = null;
    _retryAt = DateTime.now().add(_retryAfterFailure);
    return null;
  }

  /// The time-based code the web player sends with a token request, and the
  /// version of the secret it was made from.
  Future<(String, int)> _oneTimeCode() async {
    final secretsResponse = await http.get(Uri.parse(_secretsUrl)).timeout(_requestTimeout);
    final secrets = jsonDecode(secretsResponse.body) as List<dynamic>;

    var secret = '';
    var version = 0;
    for (final entry in secrets) {
      final v = (entry['v'] as num?)?.toInt() ?? 0;
      final s = entry['s'] as String? ?? '';
      if (v > version && _isBase32(s)) {
        version = v;
        secret = s;
      }
    }
    if (secret.isEmpty) throw const FormatException('nessun segreto valido');

    final timeResponse = await http.get(Uri.parse(_serverTimeUrl)).timeout(_requestTimeout);
    final serverTime = (jsonDecode(timeResponse.body)['serverTime'] as num).toInt();
    return (_totp(secret, serverTime), version);
  }

  static final RegExp _base32 = RegExp(r'^[A-Z2-7]+=*$');

  bool _isBase32(String secret) => _base32.hasMatch(secret);

  /// RFC 6238 code: HMAC-SHA1 over the 30-second step, six digits.
  String _totp(String secret, int serverTimeSec) {
    var step = serverTimeSec ~/ 30;
    final counter = List<int>.filled(8, 0);
    for (var i = 7; i >= 0; i--) {
      counter[i] = step & 0xFF;
      step >>= 8;
    }

    final digest = Hmac(sha1, _base32Decode(secret)).convert(counter).bytes;
    final offset = digest.last & 0x0F;
    final binary = ((digest[offset] & 0x7F) << 24) |
        (digest[offset + 1] << 16) |
        (digest[offset + 2] << 8) |
        digest[offset + 3];
    return (binary % 1000000).toString().padLeft(6, '0');
  }

  List<int> _base32Decode(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final output = <int>[];
    var buffer = 0;
    var bitsLeft = 0;
    for (final char in input.toUpperCase().replaceAll('=', '').split('')) {
      final value = alphabet.indexOf(char);
      if (value < 0) continue;
      buffer = (buffer << 5) | value;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return output;
  }
}
