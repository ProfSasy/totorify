import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/track_matcher_service.dart';

Song track(String title, String artist, {int seconds = 200, String id = 'id', String thumb = ''}) =>
    Song(
      id: id,
      title: title,
      artist: artist,
      duration: Duration(seconds: seconds),
      thumbnailUrl: thumb,
    );

void main() {
  final matcher = TrackMatcherService.instance;
  int score(Song candidate, Song target, {bool catalog = false}) =>
      matcher.scoreCandidate(candidate, target, fromMusicCatalog: catalog);

  final target = track('Blinding Lights', 'The Weeknd');
  final studio = track('Blinding Lights', 'The Weeknd');

  group('the right version wins', () {
    test('same title, artist and length is the top score', () {
      expect(score(studio, target), 9000);
    });

    for (final wrong in [
      track('Blinding Lights (Live)', 'The Weeknd'),
      track('Blinding Lights - Live at Wembley', 'The Weeknd'),
      track('Blinding Lights (Cover)', 'Some Band'),
      track('Blinding Lights (Remix)', 'The Weeknd'),
      track('Blinding Lights (Sped Up)', 'The Weeknd'),
      track('Blinding Lights (Slowed + Reverb)', 'The Weeknd'),
      track('Blinding Lights (Karaoke Version)', 'Sing King'),
      track('Blinding Lights (Instrumental)', 'The Weeknd'),
      track('Blinding Lights (8 Bit Version)', 'The Weeknd'),
      track('Blinding Lights (Violin)', 'The Weeknd'),
    ]) {
      test('studio beats "${wrong.title}" by ${wrong.artist}', () {
        expect(score(wrong, target), lessThan(score(studio, target) - 2000));
      });
    }

    test('a studio track a few seconds off beats a cover of the exact length', () {
      final offByFour = track('Blinding Lights', 'The Weeknd', seconds: 204);
      final cover = track('Blinding Lights', 'Cover Band');
      expect(score(offByFour, target), greaterThan(score(cover, target)));
    });

    test('a version the target itself is does not lose points', () {
      final live = track('Blinding Lights (Live)', 'The Weeknd');
      expect(score(live, live), 9000);
      final remix = track('Blinding Lights - Remix', 'The Weeknd');
      expect(score(remix, remix), greaterThan(score(studio, remix)));
    });

    test('"live" is matched as a whole word', () {
      final olive = track('Olive', 'Deliverance');
      expect(score(olive, olive), 9000);
    });

    test('upload filler in brackets is not another version', () {
      for (final title in [
        'Blinding Lights (Official Audio)',
        'Blinding Lights (Official Video)',
        'Blinding Lights [Lyrics]',
        'Blinding Lights (Remastered 2020)',
        'Blinding Lights (Visualizer)',
      ]) {
        expect(score(track(title, 'The Weeknd'), target), greaterThanOrEqualTo(9000),
            reason: title);
      }
    });
  });

  group('title', () {
    test('"Artist - Title (Official Audio)" from another channel is trusted', () {
      final upload = track('The Weeknd - Blinding Lights (Official Audio)', 'MusicChannel');
      // Title without the artist name, artist named in the title, the length.
      expect(score(upload, target), 2600 + 2000 + 3000 + 300);
    });

    test('the title inside a longer one is weaker than the exact title', () {
      final bugie = track('Bugie', 'Madame');
      final longer = track('Collane e bugie', 'Madame');
      expect(score(longer, bugie), lessThan(score(track('Bugie', 'Madame'), bugie) - 2000));
    });

    test('an unrelated title ranks below everything, whatever its length', () {
      final unrelated = track('Save Your Tears', 'The Weeknd');
      final worstRelated = track('Blinding Lights (Karaoke)', 'Nobody', seconds: 400);
      expect(score(unrelated, target), lessThanOrEqualTo(-5000));
      expect(score(unrelated, target), lessThan(score(worstRelated, target)));
    });

    test('a title of filler words is still a title', () {
      final video = track('Video', 'India.Arie');
      expect(score(track('Video', 'India.Arie'), video), 9000);
    });

    test('non-Latin titles are compared, not erased', () {
      final yoru = track('夜に駆ける', 'YOASOBI');
      expect(score(track('夜に駆ける', 'YOASOBI'), yoru), 9000);
      expect(score(track('群青', 'YOASOBI'), yoru), lessThanOrEqualTo(-5000));
    });

    test('a title made of symbols only matches nothing', () {
      final symbols = track('???', 'Artist');
      expect(score(track('!!!', 'Artist'), symbols), lessThanOrEqualTo(-5000));
    });

    test('"ft" inside a word does not cut the title', () {
      final leftBehind = track('Left Behind', 'Band');
      final other = track('Left Outside Alone', 'Band');
      expect(score(other, leftBehind), lessThan(score(track('Left Behind', 'Band'), leftBehind)));
    },
        skip: 'BUG: _featRegex (\\s*(feat|ft)...) non richiede uno spazio prima: '
            '"Left Behind" diventa "le", quindi titoli diversi che iniziano con '
            '"Left ", "Gift ", "Drift "… risultano identici.');
  });

  group('feat. and artists', () {
    final stay = track('Stay (feat. Justin Bieber)', 'The Kid LAROI');

    test('feat. in the title does not change the title', () {
      expect(score(track('Stay', 'The Kid LAROI'), stay), 9000);
      expect(score(track('STAY (with Justin Bieber)', 'The Kid LAROI'), stay), 9000);
      expect(score(track('Stay ft. Justin Bieber', 'The Kid LAROI'), stay), 9000);
    });

    test('the featured artist of the title counts as a credited artist', () {
      final byGuest = track('Stay', 'Justin Bieber');
      final byStranger = track('Stay', 'Rihanna');
      expect(score(byGuest, stay), 3000 + 3000 + 1000);
      expect(score(byStranger, stay), 3000 + 3000 - 3000);
    });

    test('the main artist weighs more than a secondary one', () {
      expect(score(track('Stay', 'The Kid LAROI'), stay),
          greaterThan(score(track('Stay', 'Justin Bieber'), stay)));
    });

    for (final credited in [
      'Marracash, Guè',
      'Marracash & Guè',
      'Marracash x Guè',
      'Marracash e Guè',
      'Marracash feat. Guè',
      'Marracash / Guè',
      'Marracash; Guè',
    ]) {
      test('artists are split in "$credited"', () {
        final song = track('Brivido', credited);
        expect(score(track('Brivido', 'Marracash'), song), 9000);
        expect(score(track('Brivido', 'Guè'), song), 7000);
        expect(score(track('Brivido', 'Sfera Ebbasta'), song), 3000);
      });
    }

    test('channel suffixes are not part of the artist', () {
      expect(score(track('Blinding Lights', 'The Weeknd - Topic'), target), 9300);
      expect(score(track('Blinding Lights', 'TheWeekndVEVO'), target), lessThan(9000));
      expect(score(track('Blinding Lights', 'The Weeknd VEVO'), target), 9000);
    });

    test('an artist name is matched as whole words', () {
      final song = track('Halo', 'Art');
      expect(score(track('Halo', 'Artemas'), song), 3000);
    });

    test('an unknown artist is no evidence either way', () {
      final unknown = track('Blinding Lights', 'Artista sconosciuto');
      expect(score(track('Blinding Lights', 'Anyone'), unknown), 6000);
    });

    test('in the music catalog a title naming the artist is a tribute', () {
      final halo = track('Halo', 'Beyoncé');
      final tribute = track('Halo (Beyoncé)', 'Studio Stars');
      expect(score(tribute, halo), 3000 + 3000 + 2000);
      expect(score(tribute, halo, catalog: true), 3000 + 3000 - 3000 + 500);
    });

    test('the music catalog is preferred for the same track', () {
      expect(score(studio, target, catalog: true), score(studio, target) + 500);
    });
  });

  group('accents', () {
    test('accented and plain spellings are the same', () {
      final deja = track('Déjà Vu', 'Beyoncé');
      expect(score(track('Deja Vu', 'Beyonce'), deja), 9000);
      expect(score(deja, track('Deja Vu', 'Beyonce')), 9000);
    });

    test('case and punctuation do not matter', () {
      final song = track("Don't Stop Me Now", 'Queen');
      expect(score(track('DONT STOP ME NOW', 'QUEEN'), song), 9000);
    });
  });

  group('length', () {
    test('the closer the length the higher the score', () {
      final scores = [
        for (final seconds in [200, 204, 208, 215, 240, 320])
          score(track('Blinding Lights', 'The Weeknd', seconds: seconds), target),
      ];
      expect(scores, [9000, 8500, 7200, 6000, 4000, 2000]);
    });

    test('an unknown length neither helps nor hurts', () {
      expect(score(track('Blinding Lights', 'The Weeknd', seconds: 0), target), 6000);
      expect(score(studio, track('Blinding Lights', 'The Weeknd', seconds: 0)), 6000);
    });
  });

  group('videos', () {
    test('isVideoOf: the same song with pictures, whatever its length', () {
      final video = track('The Weeknd - Blinding Lights (Official Video)', 'TheWeekndVEVO',
          seconds: 262);
      expect(matcher.isVideoOf(video, target), isTrue);
      expect(matcher.isVideoOf(track('Blinding Lights (Live)', 'The Weeknd'), target), isFalse);
      expect(matcher.isVideoOf(track('Blinding Lights', 'Cover Band'), target), isFalse);
      expect(matcher.isVideoOf(track('Save Your Tears', 'The Weeknd'), target), isFalse);
    });

    test('needsResolution tells catalog ids from YouTube ids', () {
      expect(TrackMatcherService.needsResolution('spotify_abc'), isTrue);
      expect(TrackMatcherService.needsResolution('itunes_1'), isTrue);
      expect(TrackMatcherService.needsResolution('deezer_1'), isTrue);
      expect(TrackMatcherService.needsResolution('dQw4w9WgXcQ'), isFalse);
    });

    test('isMusicVideo goes by the title or the video frame', () {
      expect(TrackMatcherService.isMusicVideo(track('Song (Official Video)', 'A')), isTrue);
      expect(TrackMatcherService.isMusicVideo(track('Song [Video]', 'A')), isTrue);
      expect(
        TrackMatcherService.isMusicVideo(
            track('Song', 'A', thumb: 'https://i.ytimg.com/vi/abc/hq720.jpg')),
        isTrue,
      );
      expect(
        TrackMatcherService.isMusicVideo(
            track('Song', 'A', thumb: 'https://lh3.googleusercontent.com/x=w544')),
        isFalse,
      );
      // A catalog entry is never a video, whatever its title says.
      expect(
        TrackMatcherService.isMusicVideo(track('Song (Official Video)', 'A', id: 'spotify_1')),
        isFalse,
      );
    });
  });
}
