import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/song.dart';
import 'package:kreate_ios/services/recommendation_service.dart';

var _nextId = 0;

/// A song with an id of its own: the same track has a different id in each
/// catalog, so nothing here may rely on ids.
Song track(String title, String artist) => Song(
      id: 'id${_nextId++}',
      title: title,
      artist: artist,
      duration: const Duration(minutes: 3),
      thumbnailUrl: '',
    );

List<String> titles(List<Song> songs) => [for (final s in songs) s.title];

void main() {
  const songKey = RecommendationService.songKey;
  const artistKey = RecommendationService.artistKey;
  const artistAffinity = RecommendationService.artistAffinity;

  final seed = track('Seed', 'Seed Artist');

  group('songKey and artistKey', () {
    test('the same track has the same key in every catalog', () {
      final keys = {
        songKey(track('Blinding Lights', 'The Weeknd')),
        songKey(track('Blinding Lights (Official Audio)', 'The Weeknd - Topic')),
        songKey(track('BLINDING LIGHTS [Remastered]', 'the weeknd')),
        songKey(track('Blinding Lights feat. Someone', 'The Weeknd, Someone')),
        songKey(track('Blinding  Lights!', 'The Weeknd & Someone')),
      };
      expect(keys, {'blinding lights|the weeknd'});
    });

    test('different songs and different artists have different keys', () {
      expect(songKey(track('Halo', 'Beyoncé')), isNot(songKey(track('Halo', 'Depeche Mode'))));
      expect(songKey(track('Halo', 'Beyoncé')), isNot(songKey(track('Hello', 'Beyoncé'))));
    });

    test('artistKey is the first credited artist, without channel suffixes', () {
      expect(artistKey(track('x', 'Marracash, Guè')), 'marracash');
      expect(artistKey(track('x', 'Marracash x Guè')), 'marracash');
      expect(artistKey(track('x', 'Marracash e Guè')), 'marracash');
      expect(artistKey(track('x', 'Marracash feat. Guè')), 'marracash');
      expect(artistKey(track('x', 'Dua Lipa - Topic')), 'dua lipa');
      expect(artistKey(track('x', 'DuaLipaVEVO')), 'dualipa');
      expect(artistKey(track('x', '')), '');
    });

    test('non-Latin names are kept', () {
      expect(artistKey(track('x', 'ヨルシカ')), 'ヨルシカ');
      expect(songKey(track('夜に駆ける', 'YOASOBI')), '夜に駆ける|yoasobi');
    });
  });

  group('artistAffinity', () {
    test('no history, no affinity', () {
      expect(artistAffinity(const []), isEmpty);
    });

    test('plays add up per artist, across spellings', () {
      final affinity = artistAffinity([
        track('a', 'Madame'),
        track('b', 'MADAME - Topic'),
        track('c', 'Madame, Sfera Ebbasta'),
        track('d', 'Lazza'),
      ]);
      expect(affinity.keys.toSet(), {'madame', 'lazza'});
      expect(affinity['madame'], closeTo(1 + 1 / 1.1 + 1 / 1.2, 1e-9));
      expect(affinity['lazza'], closeTo(1 / 1.3, 1e-9));
    });

    test('a recent play weighs more than an old one', () {
      final history = [
        track('new', 'Recent'),
        for (var i = 0; i < 20; i++) track('filler $i', 'Filler $i'),
        track('old', 'Old'),
      ];
      final affinity = artistAffinity(history);
      expect(affinity['recent'], 1.0);
      expect(affinity['old'], closeTo(1 / 3.1, 1e-9));
    });

    test('many old plays outweigh one recent play', () {
      final affinity = artistAffinity([
        track('new', 'Once'),
        for (var i = 0; i < 10; i++) track('song $i', 'Often'),
      ]);
      expect(affinity['often']!, greaterThan(affinity['once']!));
    });

    test('songs without an artist are skipped', () {
      expect(artistAffinity([track('a', ''), track('b', '  ')]), isEmpty);
    });

    test('topArtistKeys orders by affinity and respects the limit', () {
      final history = [
        track('1', 'B'),
        track('2', 'A'),
        track('3', 'A'),
        track('4', 'C'),
      ];
      expect(RecommendationService.topArtistKeys(history), ['a', 'b', 'c']);
      expect(RecommendationService.topArtistKeys(history, limit: 1), ['a']);
    });
  });

  group('rank', () {
    test('nothing to rank gives nothing', () {
      expect(
        RecommendationService.rank(
            seed: seed, contextual: const [], personal: const [], history: const []),
        isEmpty,
      );
    });

    test('without history the sources keep their order, contextual first', () {
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('c1', 'A'), track('c2', 'B')],
        personal: [track('p1', 'C'), track('p2', 'D')],
        history: const [],
      );
      // 1.0, 0.75 for the contextual ones; 0.7, 0.5 for the personal ones.
      expect(titles(ranked), ['c1', 'c2', 'p1', 'p2']);
    });

    test('the seed is never recommended, in any catalog spelling', () {
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('Seed (Official Video)', 'Seed Artist - Topic'), track('other', 'A')],
        personal: [track('SEED', 'seed artist')],
        history: const [],
      );
      expect(titles(ranked), ['other']);
    });

    test('songs heard recently are left out', () {
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('heard', 'A'), track('fresh', 'B')],
        personal: [track('Heard (Remastered)', 'A - Topic')],
        history: [track('heard', 'A')],
      );
      expect(titles(ranked), ['fresh']);
    });

    test('songs heard before the recent window can come back', () {
      final history = [
        for (var i = 0; i < RecommendationService.recentWindow; i++) track('recent $i', 'R$i'),
        track('long ago', 'A'),
      ];
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('recent 29', 'R29'), track('long ago', 'A')],
        personal: const [],
        history: history,
      );
      expect(titles(ranked), ['long ago']);
    });

    test('a song is listed once even when the sources repeat it', () {
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('dup', 'A'), track('Dup (Live)', 'A'), track('one', 'B')],
        personal: [track('DUP', 'a'), track('two', 'C')],
        history: const [],
      );
      expect(titles(ranked)..sort(), ['dup', 'one', 'two']);
    });

    test('a song in both sources ranks above its neighbours', () {
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('c1', 'A'), track('c2', 'B'), track('both', 'C')],
        personal: [track('both', 'C')],
        history: const [],
      );
      // 2/3 from its position, 0.7 as personal: the higher plus 0.2.
      expect(titles(ranked), ['c1', 'both', 'c2']);
    });

    test('the user\'s favourite artists climb the list', () {
      final history = [
        for (var i = 0; i < 40; i++) track('played $i', 'Favourite'),
      ];
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [
          track('c1', 'Stranger 1'),
          track('c2', 'Stranger 2'),
          track('c3', 'Stranger 3'),
          track('by favourite', 'Favourite'),
        ],
        personal: const [],
        history: history,
      );
      // Position 0.625 plus the full taste bonus 0.5 beats the top spot.
      expect(titles(ranked).first, 'by favourite');
      expect(titles(ranked).skip(1), ['c1', 'c2', 'c3']);
    });

    test('taste is relative to the most played artist', () {
      final history = [
        for (var i = 0; i < 10; i++) track('m$i', 'Most'),
        track('l', 'Little'),
      ];
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [track('by little', 'Little'), track('by most', 'Most')],
        personal: const [],
        history: history,
      );
      expect(titles(ranked), ['by most', 'by little']);
    });

    test('equal scores keep the order the sources gave', () {
      // p0 scores 0.7 and c3 scores 1.0 - 0.5 * 3/5 = 0.7.
      final ranked = RecommendationService.rank(
        seed: seed,
        contextual: [for (var i = 0; i < 5; i++) track('c$i', 'C$i')],
        personal: [track('p0', 'P')],
        history: const [],
      );
      expect(titles(ranked), ['c0', 'c1', 'c2', 'c3', 'p0', 'c4']);
    });
  });
}
