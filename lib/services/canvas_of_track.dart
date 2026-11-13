part of 'canvas_service.dart';

extension CanvasOfTrack on CanvasService {
  // ── The track's own Canvas ────────────────────────────────────────────────

  Future<_Lookup> _fetchCanvas(String trackId) async {
    final direct = await _fromSpotify([trackId]);
    final url = direct?[trackId] ?? direct?[''];
    if (url != null) return (value: url, failed: false);
    // No login, or Spotify gave nothing: the public mirror has the same
    // per-track data and needs no account.
    return _fromCanvasDownloader(trackId);
  }

  /// Spotify's own canvas endpoint, the one its app calls, for several
  /// tracks at once: the canvases found, by track id. It only answers a
  /// logged-in account; null without one or on failure.
  Future<Map<String, String>?> _fromSpotify(List<String> trackIds) async {
    if (trackIds.isEmpty || !SpotifyInternalAuthService.instance.hasSpDcCookie) return null;
    try {
      final token = await SpotifyInternalAuthService.instance.getInternalAccessToken();
      if (token == null) {
        debugPrint('CanvasService._fromSpotify: accesso a Spotify non valido, nessun token');
        return null;
      }
      final response = await appHttp.post(
        Uri.parse(CanvasService._spotifyCanvasEndpoint),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/x-protobuf',
          'Accept': 'application/protobuf',
        },
        body: encodeCanvazRequest(trackIds),
      ).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        debugPrint('CanvasService._fromSpotify: HTTP ${response.statusCode}');
        return null;
      }
      final found = decodeCanvazVideoUrls(response.bodyBytes);
      debugPrint(
        'CanvasService._fromSpotify: ${found.length} canvas su ${trackIds.length} '
        'brani chiesti (${response.bodyBytes.length} byte)',
      );
      return found;
    } catch (e) {
      debugPrint('CanvasService._fromSpotify: $e');
      return null;
    }
  }

  Future<_Lookup> _fromCanvasDownloader(String trackId) async {
    try {
      final response = await appHttp.get(
        Uri.parse('${CanvasService._provider}/canvas?link=https://open.spotify.com/track/$trackId'),
        headers: CanvasService._browserHeaders,
      ).timeout(const Duration(seconds: 8));

      // The site answers 200 for "no canvas" too: only a page with a video
      // source is a hit. Anything else than 200 is a failure worth retrying.
      if (response.statusCode != 200) {
        debugPrint('CanvasService._fromCanvasDownloader $trackId: HTTP ${response.statusCode}');
        return (value: null, failed: true);
      }
      final match = CanvasService._sourceTag.firstMatch(response.body);
      if (match == null) return (value: null, failed: false);
      // The page appends a media fragment that AVPlayer rejects.
      return (value: match.group(1)!.split('#').first, failed: false);
    } catch (e) {
      debugPrint('CanvasService._fromCanvasDownloader: $e');
      return (value: null, failed: true);
    }
  }
}
