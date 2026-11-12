import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/ytmusic_service.dart';

final base = Uri.parse('https://manifest.example.com/api/manifest/hls_variant/id/abc/master.m3u8');

String? pick(String manifest, {required bool highQuality}) =>
    YTMusicService.pickHlsAudioRendition(manifest, base, highQuality: highQuality);

// Shaped like YouTube's master manifest: two audio groups (233 = HE-AAC,
// 234 = AAC-LC), the original track and a dubbed one in each.
const master = '''
#EXTM3U
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:URI="https://cdn.example.com/itag/233/dub/index.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="English (dubbed)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=NO
#EXT-X-MEDIA:URI="https://cdn.example.com/itag/233/original/index.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="Italian",LANGUAGE="it",DEFAULT=YES,AUTOSELECT=YES
#EXT-X-MEDIA:URI="https://cdn.example.com/itag/234/dub/index.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="English (dubbed)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=NO
#EXT-X-MEDIA:URI="https://cdn.example.com/itag/234/original/index.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Italian",LANGUAGE="it",DEFAULT=YES,AUTOSELECT=YES
#EXT-X-MEDIA:URI="https://cdn.example.com/subs/it.m3u8",TYPE=SUBTITLES,GROUP-ID="vtt",NAME="Italian",DEFAULT=NO
#EXT-X-STREAM-INF:BANDWIDTH=290288,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=256x144,AUDIO="233",SUBTITLES="vtt"
https://cdn.example.com/itag/269/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1566746,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=1280x720,AUDIO="234",SUBTITLES="vtt"
https://cdn.example.com/itag/232/index.m3u8
''';

void main() {
  test('high quality picks the full AAC-LC rendition', () {
    expect(pick(master, highQuality: true), 'https://cdn.example.com/itag/234/original/index.m3u8');
  });

  test('low quality picks the lighter HE-AAC rendition', () {
    expect(pick(master, highQuality: false), 'https://cdn.example.com/itag/233/original/index.m3u8');
  });

  test('a dubbed track is never chosen over the original', () {
    expect(pick(master, highQuality: true), isNot(contains('dub')));
    expect(pick(master, highQuality: false), isNot(contains('dub')));
  });

  test('a manifest without audio renditions gives null', () {
    const videoOnly = '''
#EXTM3U
#EXT-X-MEDIA:URI="https://cdn.example.com/subs/it.m3u8",TYPE=SUBTITLES,GROUP-ID="vtt",NAME="Italian"
#EXT-X-STREAM-INF:BANDWIDTH=1566746,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=1280x720
https://cdn.example.com/itag/232/index.m3u8
''';
    expect(pick(videoOnly, highQuality: true), isNull);
    expect(pick(videoOnly, highQuality: false), isNull);
    expect(pick('', highQuality: true), isNull);
    expect(pick('not a manifest', highQuality: true), isNull);
  });

  test('an audio rendition without a URI is not a playlist', () {
    const muxed = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="234",NAME="Original",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=1566746,CODECS="avc1.4D401F,mp4a.40.2",AUDIO="234"
https://cdn.example.com/itag/232/index.m3u8
''';
    expect(pick(muxed, highQuality: true), isNull);
  });

  test('with one quality only, that one is used for both settings', () {
    const lightOnly = '''
#EXTM3U
#EXT-X-MEDIA:URI="https://cdn.example.com/itag/233/index.m3u8",TYPE=AUDIO,GROUP-ID="233",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=290288,CODECS="avc1.4D4015,mp4a.40.5",AUDIO="233"
https://cdn.example.com/itag/269/index.m3u8
''';
    expect(pick(lightOnly, highQuality: true), 'https://cdn.example.com/itag/233/index.m3u8');
    expect(pick(lightOnly, highQuality: false), 'https://cdn.example.com/itag/233/index.m3u8');
  });

  test('without a default track every rendition is a candidate', () {
    final noDefault = master.replaceAll('DEFAULT=YES', 'DEFAULT=NO');
    expect(pick(noDefault, highQuality: true), 'https://cdn.example.com/itag/234/dub/index.m3u8');
    expect(pick(noDefault, highQuality: false), 'https://cdn.example.com/itag/233/dub/index.m3u8');
  });

  test('relative URIs are resolved against the manifest', () {
    const relative = '''
#EXTM3U
#EXT-X-MEDIA:URI="audio/234/index.m3u8",TYPE=AUDIO,GROUP-ID="234",DEFAULT=YES
#EXT-X-MEDIA:URI="/root/233/index.m3u8",TYPE=AUDIO,GROUP-ID="233",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="mp4a.40.2,avc1.4D401F",AUDIO="234"
v1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="mp4a.40.5,avc1.4D4015",AUDIO="233"
v2.m3u8
''';
    expect(
      pick(relative, highQuality: true),
      'https://manifest.example.com/api/manifest/hls_variant/id/abc/audio/234/index.m3u8',
    );
    expect(pick(relative, highQuality: false), 'https://manifest.example.com/root/233/index.m3u8');
  });

  test('Windows line endings and indentation are tolerated', () {
    final crlf = master.split('\n').map((line) => '  $line').join('\r\n');
    expect(pick(crlf, highQuality: true), 'https://cdn.example.com/itag/234/original/index.m3u8');
    expect(pick(crlf, highQuality: false), 'https://cdn.example.com/itag/233/original/index.m3u8');
  });
}
