import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../models/song.dart';
import 'app_settings.dart';
import 'audio_handler.dart';
import 'playback_log_service.dart';

/// A service that keeps what the user listens to ("scrobbling").
enum ScrobbleService {
  lastfm('Last.fm', 'https://ws.audioscrobbler.com/2.0/'),
  librefm('Libre.fm', 'https://libre.fm/2.0/');

  const ScrobbleService(this.label, this.endpoint);

  final String label;
  final String endpoint;
}

/// Sends what is listened to Last.fm, Libre.fm and ListenBrainz, as the
/// players that support them do: "now playing" when a song starts, a
/// scrobble once it played half its length (or four minutes). Scrobbles
/// that cannot be sent wait and go with the next ones.
///
/// Last.fm wants an API key of the user's own (free, from last.fm/api);
/// Libre.fm accepts any key. The password is used once, to get a session,
/// and not kept.
class Scrobbler {
  Scrobbler._();
  static final Scrobbler instance = Scrobbler._();

  static const String _boxName = 'kreate_scrobble';
  final http.Client _client = http.Client();
  Box? _box;

  /// Who is signed in, per service; null when no one.
  final ValueNotifier<String?> audioscrobblerUser = ValueNotifier<String?>(null);
  final ValueNotifier<String?> listenBrainzUser = ValueNotifier<String?>(null);

  Song? _song;
  DateTime? _startedAt;
  Duration _listened = Duration.zero;
  DateTime? _since;
  bool _sent = false;
  Timer? _ticker;

  Future<void> attach(AudioPlayerHandler handler) async {
    try {
      _box = await Hive.openBox(_boxName);
    } catch (e) {
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox(_boxName);
    }
    audioscrobblerUser.value = _box!.get('as_user') as String?;
    listenBrainzUser.value = _box!.get('lb_user') as String?;

    handler.mediaItem.listen((_) {
      final song = handler.currentSong;
      if (song?.id == _song?.id) return;
      _song = song;
      _startedAt = DateTime.now();
      _listened = Duration.zero;
      _sent = false;
      _since = handler.playbackState.value.playing ? DateTime.now() : null;
      if (song != null && handler.playbackState.value.playing) unawaited(_nowPlaying(song));
    });
    handler.playbackState.map((state) => state.playing).distinct().listen((playing) {
      if (playing) {
        _since ??= DateTime.now();
        final song = _song;
        if (song != null && _listened == Duration.zero) unawaited(_nowPlaying(song));
      } else {
        final since = _since;
        if (since != null) _listened += DateTime.now().difference(since);
        _since = null;
      }
    });
    // Checked every few seconds: a scrobble goes as soon as it is due.
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) => _check());
    unawaited(_flushPending());
  }

  bool get _active => audioscrobblerUser.value != null || listenBrainzUser.value != null;

  void _check() {
    final song = _song;
    if (song == null || _sent || !_active) return;
    if (song.duration < const Duration(seconds: 30)) return;
    var listened = _listened;
    final since = _since;
    if (since != null) listened += DateTime.now().difference(since);
    final half = song.duration ~/ 2;
    final due = half < const Duration(minutes: 4) ? half : const Duration(minutes: 4);
    if (listened < due) return;
    _sent = true;
    if (AppSettings.instance.pauseListenHistory.value) return;
    unawaited(_scrobble(song, _startedAt ?? DateTime.now()));
  }

  // ── Last.fm / Libre.fm ──────────────────────────────────────────────────

  ScrobbleService get _service => ScrobbleService.values.firstWhere(
    (s) => s.name == _box?.get('as_service'),
    orElse: () => ScrobbleService.lastfm,
  );

  String get serviceLabel => _service.label;

  String _apiKey(ScrobbleService service) =>
      service == ScrobbleService.librefm ? 'totorify' : (_box?.get('as_key') as String? ?? '');
  String _secret(ScrobbleService service) =>
      service == ScrobbleService.librefm ? 'totorify' : (_box?.get('as_secret') as String? ?? '');

  static String signature(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format' && k != 'callback').toList()..sort();
    final text = StringBuffer();
    for (final key in keys) {
      text
        ..write(key)
        ..write(params[key]);
    }
    text.write(secret);
    return md5.convert(utf8.encode(text.toString())).toString();
  }

  Future<Map<String, dynamic>> _call(
    ScrobbleService service,
    String method,
    Map<String, String> params,
  ) async {
    final all = {...params, 'method': method, 'api_key': _apiKey(service)};
    all['api_sig'] = signature(all, _secret(service));
    all['format'] = 'json';
    final response = await _client
        .post(Uri.parse(service.endpoint), body: all)
        .timeout(const Duration(seconds: 12));
    final data = jsonDecode(response.body);
    if (data is Map && data['error'] != null) {
      throw ScrobbleException('${data['message'] ?? 'errore ${data['error']}'}');
    }
    if (response.statusCode != 200) throw ScrobbleException('HTTP ${response.statusCode}');
    return Map<String, dynamic>.from(data as Map);
  }

  /// Signs in with [username] and [password]; the password is not kept.
  Future<void> signIn(
    ScrobbleService service, {
    required String username,
    required String password,
    String apiKey = '',
    String secret = '',
  }) async {
    final box = _box!;
    await box.putAll({
      'as_service': service.name,
      'as_key': apiKey.trim(),
      'as_secret': secret.trim(),
    });
    if (service == ScrobbleService.lastfm && (apiKey.trim().isEmpty || secret.trim().isEmpty)) {
      throw ScrobbleException('Per Last.fm servono la tua API key e il segreto condiviso');
    }
    final data = await _call(service, 'auth.getMobileSession', {
      'username': username.trim(),
      'password': password,
    });
    final session = data['session'];
    if (session is! Map || session['key'] == null) throw ScrobbleException('Accesso non riuscito');
    await box.putAll({'as_session': session['key'], 'as_user': session['name'] ?? username});
    audioscrobblerUser.value = '${session['name'] ?? username}';
    PlaybackLogService.instance.log(
      'SCROBBLE',
      'accesso a ${service.label} come ${audioscrobblerUser.value}',
    );
  }

  Future<void> signOut() async {
    await _box?.deleteAll(['as_session', 'as_user']);
    audioscrobblerUser.value = null;
  }

  // ── ListenBrainz ────────────────────────────────────────────────────────

  Future<void> setListenBrainzToken(String token) async {
    final clean = token.trim();
    final response = await _client
        .get(
          Uri.parse('https://api.listenbrainz.org/1/validate-token'),
          headers: {'Authorization': 'Token $clean'},
        )
        .timeout(const Duration(seconds: 12));
    final data = jsonDecode(response.body);
    if (data is! Map || data['valid'] != true) throw ScrobbleException('Token non valido');
    await _box?.putAll({'lb_token': clean, 'lb_user': data['user_name']});
    listenBrainzUser.value = '${data['user_name']}';
  }

  Future<void> forgetListenBrainz() async {
    await _box?.deleteAll(['lb_token', 'lb_user']);
    listenBrainzUser.value = null;
  }

  Future<void> _listenBrainz(String type, Song song, {DateTime? at}) async {
    final token = _box?.get('lb_token') as String?;
    if (token == null) return;
    final response = await _client
        .post(
          Uri.parse('https://api.listenbrainz.org/1/submit-listens'),
          headers: {'Authorization': 'Token $token', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'listen_type': type,
            'payload': [
              {
                if (at != null) 'listened_at': at.millisecondsSinceEpoch ~/ 1000,
                'track_metadata': {
                  'artist_name': song.artist,
                  'track_name': song.title,
                  if (song.album != null && song.album!.isNotEmpty) 'release_name': song.album,
                  'additional_info': {
                    'media_player': 'Totorify',
                    'duration_ms': song.duration.inMilliseconds,
                  },
                },
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) throw ScrobbleException('HTTP ${response.statusCode}');
  }

  // ── Sending ─────────────────────────────────────────────────────────────

  Future<void> _nowPlaying(Song song) async {
    if (!_active || AppSettings.instance.pauseListenHistory.value) return;
    try {
      final session = _box?.get('as_session') as String?;
      if (session != null) {
        await _call(_service, 'track.updateNowPlaying', {
          'artist': song.artist,
          'track': song.title,
          if (song.album != null && song.album!.isNotEmpty) 'album': song.album!,
          'duration': '${song.duration.inSeconds}',
          'sk': session,
        });
      }
      await _listenBrainz('playing_now', song);
    } catch (e) {
      debugPrint('Scrobbler.nowPlaying: $e');
    }
  }

  Future<void> _scrobble(Song song, DateTime at) async {
    final pending = [
      ...List<Map>.from(_box?.get('pending', defaultValue: const []) as List),
      {'song': song.toMap(), 'at': at.millisecondsSinceEpoch},
    ];
    await _box?.put('pending', pending);
    await _flushPending();
  }

  /// Sends the scrobbles that are waiting; those that fail wait more.
  Future<void> _flushPending() async {
    final box = _box;
    if (box == null) return;
    final pending = List<Map>.from(box.get('pending', defaultValue: const []) as List);
    if (pending.isEmpty) return;
    final left = <Map>[];
    for (final item in pending) {
      try {
        final song = Song.fromMap(Map<String, dynamic>.from(item['song'] as Map));
        final at = DateTime.fromMillisecondsSinceEpoch(item['at'] as int);
        final session = box.get('as_session') as String?;
        if (session != null) {
          await _call(_service, 'track.scrobble', {
            'artist': song.artist,
            'track': song.title,
            'timestamp': '${at.millisecondsSinceEpoch ~/ 1000}',
            if (song.album != null && song.album!.isNotEmpty) 'album': song.album!,
            'duration': '${song.duration.inSeconds}',
            'sk': session,
          });
        }
        await _listenBrainz('single', song, at: at);
        PlaybackLogService.instance.log('SCROBBLE', '"${song.title}" inviato');
      } catch (e) {
        debugPrint('Scrobbler: invio rimandato ($e)');
        // Kept for two weeks at most.
        final at = item['at'] as int? ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - at < const Duration(days: 14).inMilliseconds) {
          left.add(item);
        }
      }
    }
    await box.put('pending', left);
  }

  @visibleForTesting
  void dispose() => _ticker?.cancel();
}

class ScrobbleException implements Exception {
  ScrobbleException(this.message);
  final String message;
  @override
  String toString() => message;
}
