import 'dart:convert';
import 'dart:typed_data';

/// Hand-rolled protobuf for Spotify's canvas endpoint (`canvaz-cache`), the
/// one the Spotify app itself calls. Only the two fields the app needs are
/// handled, which avoids a protobuf dependency:
///
///     message EntityCanvazRequest  { repeated Entity entities = 1; }
///     message Entity               { string entity_uri = 1; }
///     message EntityCanvazResponse { repeated Canvaz canvases = 1; }
///     message Canvaz               { string url = 2; string entity_uri = 5; ... }

const int _lengthDelimited = 2;
const String _trackUriPrefix = 'spotify:track:';

/// Request asking for the canvases of the given Spotify tracks.
Uint8List encodeCanvazRequest(Iterable<String> trackIds) {
  final out = <int>[];
  for (final trackId in trackIds) {
    final uri = utf8.encode('$_trackUriPrefix$trackId');
    final entity = [0x0A, ..._varint(uri.length), ...uri];
    out.addAll([0x0A, ..._varint(entity.length), ...entity]);
  }
  return Uint8List.fromList(out);
}

/// Looping-video URL of each track in a canvas response, by track id.
/// Tracks without a canvas (or with only a still image, which the player
/// cannot loop) are absent. A canvas that does not say which track it
/// belongs to is filed under an empty id.
Map<String, String> decodeCanvazVideoUrls(Uint8List bytes) {
  final urls = <String, String>{};
  try {
    for (final canvas in _fields(bytes, 1)) {
      String? url;
      for (final raw in _fields(canvas, 2)) {
        final candidate = utf8.decode(raw);
        if (Uri.tryParse(candidate)?.path.toLowerCase().endsWith('.mp4') ?? false) {
          url = candidate;
          break;
        }
      }
      if (url == null) continue;
      var trackId = '';
      for (final raw in _fields(canvas, 5)) {
        final uri = utf8.decode(raw);
        if (uri.startsWith(_trackUriPrefix)) trackId = uri.substring(_trackUriPrefix.length);
      }
      urls.putIfAbsent(trackId, () => url!);
    }
  } catch (_) {
    // Truncated or unexpected payload: what was read so far is kept.
  }
  return urls;
}

List<int> _varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add((value & 0x7F) | 0x80);
    value >>= 7;
  }
  out.add(value);
  return out;
}

/// Payloads of every length-delimited field numbered [number] in [bytes].
Iterable<Uint8List> _fields(Uint8List bytes, int number) sync* {
  var i = 0;

  int readVarint() {
    var value = 0;
    var shift = 0;
    while (true) {
      final byte = bytes[i++];
      value |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
  }

  while (i < bytes.length) {
    final key = readVarint();
    final wireType = key & 0x07;
    switch (wireType) {
      case 0: // varint
        readVarint();
      case 1: // 64-bit
        i += 8;
      case _lengthDelimited:
        final length = readVarint();
        if (key >> 3 == number) {
          yield Uint8List.sublistView(bytes, i, i + length);
        }
        i += length;
      case 5: // 32-bit
        i += 4;
      default:
        throw FormatException('Unsupported wire type $wireType');
    }
  }
}
