import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Playlist;
import '../models/song.dart';
import '../models/playlist.dart';
import 'auth_service.dart';
import 'storage_service.dart';
import 'app_http.dart';
import 'playback_log_service.dart';
import 'ytmusic_catalog_service.dart';

part 'ytmusic_streams.dart';
part 'ytmusic_search.dart';
part 'ytmusic_playlists.dart';

/// Where the audio of a YouTube video can be streamed from, and its length.
typedef _VideoStreams = ({String? audioUrl, String? hlsManifestUrl, Duration? duration});

/// What YouTube says about the audio of a video: how loud it is, and the
/// format of the direct stream picked for it.
@immutable
class StreamDetails {
  const StreamDetails({
    this.loudnessDb,
    this.mimeType,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.contentLength,
    this.itag,
  });

  /// How much louder than YouTube's reference the video is, in dB: positive
  /// for a loud master. YouTube lowers those by as much.
  final double? loudnessDb;
  final String? mimeType;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final int? contentLength;
  final int? itag;

  /// The codec, as the mime type names it ("mp4a.40.2", "opus").
  String? get codec {
    final mime = mimeType;
    if (mime == null) return null;
    final match = RegExp(r'codecs="([^"]+)"').firstMatch(mime);
    return match?.group(1);
  }
}

/// YouTube Music service using authenticated & Apple VisionOS InnerTube APIs
/// for rock-solid stream extraction on iOS devices.
class YTMusicService {
  static final YTMusicService instance = YTMusicService._internal();
  YTMusicService._internal();

  final YoutubeExplode _yt = YoutubeExplode();
  // ── InnerTube API constants ───────────────────────────────────────────────

  static const _innerTubeApiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-NKNELL6OA';
  static const _baseUrl = 'https://music.youtube.com/youtubei/v1';

  static const _visionOsUa =
      'com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; IT)';

  // What AVPlayer itself sends when it fetches a stream.
  static const _appleMediaUa =
      'AppleCoreMedia/1.0.0.23G93 (iPhone; U; CPU OS 26_6 like Mac OS X; it_it)';

  static const _visionOsHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': _visionOsUa,
    'X-Goog-Api-Format-Version': '2',
  };

  String? _cachedVisitorData;
  DateTime? _visitorDataExpiry;

  // ── Shared short-TTL caches ─────────────────────────────────────────────
  // Signed googlevideo URLs stay valid for hours: paying the InnerTube round
  // trip twice for the same video in one session is pure latency. Playback,
  // downloads, canvas and the matcher all share these caches, and parallel
  // requests for the same id are collapsed into one.

  static const Duration _urlCacheTtl = Duration(hours: 3);
  static const Duration _searchCacheTtl = Duration(minutes: 10);
  static const int _cacheMaxEntries = 80;

  final Map<String, (String, DateTime)> _audioUrlCache = {};
  final Map<String, Future<String?>> _audioUrlInFlight = {};
  final Map<String, (_VideoStreams, DateTime)> _streamsCache = {};
  final Map<String, Future<_VideoStreams?>> _streamsInFlight = {};
  final Map<String, (String, DateTime)> _hlsAudioCache = {};
  final Map<String, StreamDetails> _details = {};

  final Map<String, (List<Song>, DateTime)> _searchCache = {};
  final Map<String, Future<List<Song>>> _searchInFlight = {};

  void _pruneCache(Map<dynamic, dynamic> cache) {
    while (cache.length > _cacheMaxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  String _randomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// Obtains and caches a valid visitorData token from YouTube
  Future<String?> _getVisitorData({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedVisitorData != null &&
        _visitorDataExpiry != null &&
        DateTime.now().isBefore(_visitorDataExpiry!)) {
      return _cachedVisitorData;
    }

    try {
      final body = {
        'context': {
          'client': {
            'clientName': 'VISIONOS',
            'clientVersion': '1.04',
            'clientScreen': 'WATCH',
            'platform': 'MOBILE',
            'deviceMake': 'Apple',
            'deviceModel': 'RealityDevice17,1',
            'osName': 'visionOS',
            'osVersion': '26.6.0.23O770',
            'hl': 'it',
            'gl': 'IT',
          }
        }
      };

      final resp = await appHttp.post(
        Uri.parse(
            'https://youtubei.googleapis.com/youtubei/v1/visitor_id?prettyPrint=false'),
        headers: _visionOsHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final visitor =
            data['responseContext']?['visitorData'] as String?;
        if (visitor != null && visitor.isNotEmpty) {
          _cachedVisitorData = visitor;
          _visitorDataExpiry = DateTime.now().add(const Duration(hours: 12));
          return visitor;
        }
      }
    } catch (e) { debugPrint('YTMusic.getVisitorData: $e'); }
    return null;
  }

  /// ANDROID_MUSIC client payload — matches YouTube Music Android app.
  Map<String, dynamic> _androidMusicContext() => {
        'context': {
          'client': {
            'clientName': 'ANDROID_MUSIC',
            'clientVersion': '7.27.52',
            'androidSdkVersion': 34,
            'userAgent':
                'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14; en_US) gzip',
            'hl': 'it',
            'gl': 'IT',
            'utcOffsetMinutes': 60,
          },
        },
      };

  /// How much louder than YouTube's target the audio is, in dB: given for
  /// each format, or worked out from the whole track's measure.
  static double? _loudnessOf(Map<String, dynamic>? format, Object? audioConfig) {
    final own = format?['loudnessDb'];
    if (own is num) return own.toDouble();
    if (audioConfig is! Map) return null;
    final measured = audioConfig['trackAbsoluteLoudnessLkfs'] ?? audioConfig['perceptualLoudnessDb'];
    final target = audioConfig['loudnessTargetLkfs'] ?? -14;
    if (measured is! num || target is! num) return null;
    return measured.toDouble() - target.toDouble();
  }

  static final RegExp _hlsAttribute = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

  static Map<String, String> _hlsAttributes(String line) => {
        for (final match in _hlsAttribute.allMatches(line.substring(line.indexOf(':') + 1)))
          match.group(1)!: match.group(2)!.replaceAll('"', ''),
      };

  /// Picks the audio-only playlist out of an HLS master manifest: the
  /// default track (not a dubbed one), AAC-LC for high quality and the
  /// lighter HE-AAC otherwise.
  static String? pickHlsAudioRendition(String manifest, Uri base, {required bool highQuality}) {
    final lines = manifest.split('\n').map((line) => line.trim()).toList();

    // Which codec each audio group carries, from the variants that use it.
    final groupCodec = <String, String>{};
    for (final line in lines) {
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final attributes = _hlsAttributes(line);
      final group = attributes['AUDIO'];
      if (group == null) continue;
      final codec = (attributes['CODECS'] ?? '')
          .split(',')
          .map((c) => c.trim())
          .firstWhere((c) => c.startsWith('mp4a'), orElse: () => '');
      if (codec.isNotEmpty) groupCodec.putIfAbsent(group, () => codec);
    }

    final renditions = <({String uri, String group, bool isDefault})>[];
    for (final line in lines) {
      if (!line.startsWith('#EXT-X-MEDIA')) continue;
      final attributes = _hlsAttributes(line);
      final uri = attributes['URI'];
      if (attributes['TYPE'] != 'AUDIO' || uri == null || uri.isEmpty) continue;
      renditions.add((
        uri: uri,
        group: attributes['GROUP-ID'] ?? '',
        isDefault: attributes['DEFAULT'] == 'YES',
      ));
    }
    if (renditions.isEmpty) return null;

    final originals = renditions.where((r) => r.isDefault).toList();
    final pool = originals.isNotEmpty ? originals : renditions;
    // mp4a.40.2 is AAC-LC (about 128 kbps), mp4a.40.5 is HE-AAC (about 48).
    bool isFull(({String uri, String group, bool isDefault}) r) =>
        groupCodec[r.group] == 'mp4a.40.2';
    final chosen = pool.firstWhere(
      (r) => isFull(r) == highQuality,
      orElse: () => pool.first,
    );
    return base.resolve(chosen.uri).toString();
  }

  /// True where the player decodes Opus in WebM (ExoPlayer on Android,
  /// libmpv on Windows and Linux). AVPlayer on iOS does not.
  static final bool opusPlayable =
      !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isLinux);

  /// The bitrate a format keeps on average; the peak one when not given.
  static int _averageBitrate(dynamic format) =>
      int.tryParse('${format['averageBitrate'] ?? format['bitrate'] ?? ''}') ?? 0;

  /// Set while the lighter streams must be played whatever the quality
  /// setting says (a mobile connection, with "save data" on).
  static bool lowDataNow = false;

  /// The id of the video a YouTube or YouTube Music link points to.
  static String? videoIdOfLink(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') return uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    if (!host.contains('youtube.com')) return null;
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return v;
    final segments = uri.pathSegments;
    if (segments.length >= 2 && (segments.first == 'shorts' || segments.first == 'live')) {
      return segments[1];
    }
    return null;
  }
}


