import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'storage_service.dart'; // IMPORT STORAGE SERVICE

class SpotifyInternalAuthService {
  static final SpotifyInternalAuthService instance = SpotifyInternalAuthService._internal();
  SpotifyInternalAuthService._internal();

  static const _serverTimeUrl = 'https://open.spotify.com/api/server-time';
  static const _nuanceUrl = 'https://gist.githubusercontent.com/sonic-liberation/22ed9c6ba463899e933427f7de1f0eef/raw/nuances.json';
  static const _tokenUrl = 'https://open.spotify.com/api/token';
  
  String? _accessToken;
  int _tokenExpirationTime = 0;

  Future<void> saveSpDcCookie(String spDc) async {
    await StorageService.instance.setSpDcCookie(spDc);
    _accessToken = null; // Invalidate current token
  }

  String? getSpDcCookie() {
    return StorageService.instance.spDcCookie;
  }

  bool get hasSpDcCookie {
    final cookie = getSpDcCookie();
    return cookie != null && cookie.isNotEmpty;
  }

  /// Restituisce l'access token interno, rigenerandolo tramite TOTP se scaduto.
  Future<String?> getInternalAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null && now < _tokenExpirationTime) {
      return _accessToken;
    }

    final spDc = getSpDcCookie();
    if (spDc == null || spDc.isEmpty) {
      debugPrint('SpotifyInternalAuth: Nessun cookie sp_dc trovato.');
      return null;
    }

    try {
      final totpData = await _generateTotp();
      final code = totpData['code'] as String;
      final version = totpData['version'] as int;

      final url = '$_tokenUrl?reason=transport&productType=web-player&totp=$code&totpServer=$code&totpVer=$version';
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          'Cookie': 'sp_dc=$spDc',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final token = data['accessToken'] as String?;
        final isAnonymous = data['isAnonymous'] as bool? ?? true;
        
        if (isAnonymous || token == null || token.isEmpty) {
          debugPrint('SpotifyInternalAuth: Il cookie sp_dc fornito è invalido o scaduto.');
          return null;
        }

        _accessToken = token;
        _tokenExpirationTime = now + 3500000; // Valido per ~1 ora
        return _accessToken;
      } else {
        debugPrint('SpotifyInternalAuth: HTTP ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('SpotifyInternalAuth: Errore durante il recupero del token: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>> _generateTotp() async {
    final nuanceResp = await http.get(Uri.parse(_nuanceUrl));
    final nuances = jsonDecode(nuanceResp.body) as List<dynamic>;
    
    String secret = '';
    int version = 0;
    for (var n in nuances) {
      if (n['v'] > version && _isValidBase32(n['s'])) {
        version = n['v'];
        secret = n['s'];
      }
    }
    
    final timeResp = await http.get(Uri.parse(_serverTimeUrl));
    final serverTimeSec = jsonDecode(timeResp.body)['serverTime'] as int;
    
    final code = _generateTotpFromSecret(secret, serverTimeSec);
    return {'code': code, 'version': version};
  }

  bool _isValidBase32(String secret) {
    return RegExp(r'^[A-Z2-7]+=*$').hasMatch(secret);
  }

  String _generateTotpFromSecret(String secret, int serverTimeSec) {
    final timeStep = (serverTimeSec / 30).floor();
    
    final key = _base32Decode(secret);
    
    final timeBytes = List<int>.filled(8, 0);
    var value = timeStep;
    for (var i = 7; i >= 0; i--) {
      timeBytes[i] = value & 0xFF;
      value = value >> 8;
    }
    
    final hmac = Hmac(sha1, key);
    final digest = hmac.convert(timeBytes).bytes;
    
    final offset = digest[digest.length - 1] & 0x0F;
    final binary = ((digest[offset] & 0x7F) << 24) |
                   ((digest[offset + 1] & 0xFF) << 16) |
                   ((digest[offset + 2] & 0xFF) << 8) |
                   (digest[offset + 3] & 0xFF);
                   
    final otp = binary % 1000000;
    return otp.toString().padLeft(6, '0');
  }

  List<int> _base32Decode(String input) {
    final alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final cleaned = input.toUpperCase().replaceAll('=', '');
    final output = <int>[];
    var buffer = 0;
    var bitsLeft = 0;
    
    for (var i = 0; i < cleaned.length; i++) {
      final val = alphabet.indexOf(cleaned[i]);
      if (val < 0) continue;
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return output;
  }
}
