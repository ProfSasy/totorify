import 'dart:convert';
import 'dart:typed_data';

/// Hand-rolled protobuf for Spotify's canvas endpoint (`canvaz-cache`), the
/// one the Spotify app itself calls. Only the two fields the app needs are
/// handled, which avoids a protobuf dependency:
///
///     message EntityCanvazRequest  { repeated Entity entities = 1; }
///     message Entity               { string entity_uri = 1; }
///     message EntityCanvazResponse { repeated Canvaz canvases = 1; }
///     message Canvaz               { string url = 2; ... }

const int _lengthDelimited = 2;

/// Request asking for the canvas of one Spotify track.
Uint8List encodeCanvazRequest(String trackId) {
  final uri = utf8.encode('spotify:track:$trackId');
  final entity = [0x0A, ..._varint(uri.length), ...uri];
  return Uint8List.fromList([0x0A, ..._varint(entity.length), ...entity]);
}

/// First looping-video URL in a canvas response, or null when the track has
/// no canvas (or only a still image, which the player cannot loop).
String? decodeCanvazVideoUrl(Uint8List bytes) {
  try {
    for (final canvas in _fields(bytes, 1)) {
      for (final raw in _fields(canvas, 2)) {
        final url = utf8.decode(raw);
        if (Uri.tryParse(url)?.path.toLowerCase().endsWith('.mp4') ?? false) {
          return url;
        }
      }
    }
  } catch (_) {
    // Truncated or unexpected payload: treated as "no canvas".
  }
  return null;
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
