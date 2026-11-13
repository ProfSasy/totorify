import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/models/lyrics_model.dart';

Duration ms(int value) => Duration(milliseconds: value);

void main() {
  group('Lyrics.fromLrc', () {
    test('parses timed lines in order of time', () {
      final lyrics = Lyrics.fromLrc('[00:20.00]second\n[00:10.50]first');
      expect(lyrics.isSynced, isTrue);
      expect([for (final l in lyrics.syncedLyrics) l.text], ['first', 'second']);
      expect(lyrics.syncedLyrics.first.time, ms(10500));
    });

    test('reads one, two and three digit fractions and the colon form', () {
      final lyrics = Lyrics.fromLrc('[00:01.5]a\n[00:02.05]b\n[00:03.123]c\n[01:04:50]d');
      expect(
        [for (final l in lyrics.syncedLyrics) l.time],
        [ms(1500), ms(2050), ms(3123), ms(64500)],
      );
    });

    test('a line with several timestamps is sung at each of them', () {
      final lyrics = Lyrics.fromLrc('[00:10.00][00:30.00] [01:00.00]chorus\n[00:20.00]verse');
      expect(
        [for (final l in lyrics.syncedLyrics) '${l.time.inSeconds}:${l.text}'],
        ['10:chorus', '20:verse', '30:chorus', '60:chorus'],
      );
      // Once in the plain text.
      expect(lyrics.plainLyrics, 'chorus\nverse');
    });

    test('skips empty lines, timed lines without text and metadata tags', () {
      final lyrics = Lyrics.fromLrc(
        '[ar:Artist]\n[ti:Title]\n[offset:+500]\n\n[00:05.00]\n[00:10.00]  hello  \r\n   \n[00:12.00]world',
      );
      expect([for (final l in lyrics.syncedLyrics) l.text], ['hello', 'world']);
      expect(lyrics.plainLyrics, 'hello\nworld');
    });

    test('empty text gives the plain fallback, not synced', () {
      final lyrics = Lyrics.fromLrc('   ', plainFallback: 'plain words', source: 'LRCLIB');
      expect(lyrics.isSynced, isFalse);
      expect(lyrics.plainLyrics, 'plain words');
      expect(lyrics.source, 'LRCLIB');
    });

    test('text without timestamps is kept as plain lyrics', () {
      final lyrics = Lyrics.fromLrc('one\ntwo');
      expect(lyrics.isSynced, isFalse);
      expect(lyrics.syncedLyrics, isEmpty);
      expect(lyrics.lines, ['one', 'two']);
    });

    test('enhanced LRC gives the words with their times', () {
      final lyrics = Lyrics.fromLrc('[00:12.30]<00:12.30>Hello <00:12.80>big <00:13.40>world');
      final line = lyrics.syncedLyrics.single;
      expect(line.text, 'Hello big world');
      expect(lyrics.isWordSynced, isTrue);
      expect([for (final w in line.words) w.text], ['Hello ', 'big ', 'world']);
      expect([for (final w in line.words) w.start], [ms(12300), ms(12800), ms(13400)]);
      // A word ends where the next begins; the last one lasts 600 ms.
      expect([for (final w in line.words) w.end], [ms(12800), ms(13400), ms(14000)]);
      // The words put together give the line back.
      expect(line.words.map((w) => w.text).join(), line.text);
    });

    test('a closing word stamp ends the last word and is not a word', () {
      final lyrics = Lyrics.fromLrc('[00:01.00]<00:01.00>la <00:01.50>la<00:02.20>');
      final words = lyrics.syncedLyrics.single.words;
      expect(words, hasLength(2));
      expect(words.last.end, ms(2200));
    });

    test('lines timed line by line have no words', () {
      final lyrics = Lyrics.fromLrc('[00:01.00]plain line');
      expect(lyrics.isWordSynced, isFalse);
      expect(lyrics.syncedLyrics.single.words, isEmpty);
    });
  });

  group('offset and round trips', () {
    test('shifted moves every line and word, later or earlier', () {
      final lyrics = Lyrics.fromLrc('[00:10.00]<00:10.00>a <00:10.50>b\n[00:20.00]c');
      final later = lyrics.shifted(ms(500));
      expect([for (final l in later.syncedLyrics) l.time], [ms(10500), ms(20500)]);
      expect(later.syncedLyrics.first.words.first.start, ms(10500));
      expect(later.syncedLyrics.first.words.first.end, ms(11000));

      final earlier = lyrics.shifted(ms(-1000));
      expect(earlier.syncedLyrics.first.time, ms(9000));
      // The original is untouched.
      expect(lyrics.syncedLyrics.first.time, ms(10000));
    });

    test('a zero shift gives the same object back', () {
      final lyrics = Lyrics.fromLrc('[00:10.00]a');
      expect(identical(lyrics.shifted(Duration.zero), lyrics), isTrue);
    });

    test('toLrc output parses back to the same lines', () {
      final lyrics = Lyrics.fromLrc('[01:02.34]one\n[10:00.00]two');
      expect(lyrics.toLrc(), '[01:02.34] one\n[10:00.00] two');
      final again = Lyrics.fromLrc(lyrics.toLrc());
      expect([for (final l in again.syncedLyrics) l.toString()],
          [for (final l in lyrics.syncedLyrics) l.toString()]);
    });

    test('toMap and fromMap keep lines, words and source', () {
      final lyrics =
          Lyrics.fromLrc('[00:01.00]<00:01.00>a <00:01.50>b\n[00:05.00]c', source: 'LRCLIB');
      final again = Lyrics.fromMap(lyrics.toMap());
      expect(again.isSynced, isTrue);
      expect(again.source, 'LRCLIB');
      expect(again.plainLyrics, lyrics.plainLyrics);
      expect([for (final l in again.syncedLyrics) l.toString()],
          [for (final l in lyrics.syncedLyrics) l.toString()]);
      expect(again.syncedLyrics.first.words.map((w) => w.text), ['a ', 'b']);
      expect(again.syncedLyrics.last.words, isEmpty);
    });

    test('fromMap ignores malformed entries', () {
      final lyrics = Lyrics.fromMap({
        'plain': 'x',
        'synced': [
          [1000, 'ok'],
          ['bad', 'row'],
          [2000],
          'nope',
          [3000, 'words', [[3000, 3100, 'w'], 'broken', [1, 2]]],
        ],
      });
      expect([for (final l in lyrics.syncedLyrics) l.text], ['ok', 'words']);
      expect(lyrics.syncedLyrics.last.words, hasLength(1));
    });
  });

  group('Lyrics.fromTtml', () {
    const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
<body><div>
<p begin="00:00:12.000" end="00:00:14.000">
  <span begin="12.000" end="12.400">Hello</span> <span begin="12.400" end="13.000">world</span>
  <span ttm:role="x-bg"><span begin="13.000" end="13.500">(ooh)</span></span>
</p>
<p begin="5.5s" end="7s"><span begin="5.5s" end="6s">Tom</span><span begin="6s" end="6.5s">&amp;</span> <span begin="1:06.5" end="1:07">Jerry&apos;s</span></p>
<p begin="1500ms">line without words</p>
<p>no time at all</p>
</div></body></tt>''';

    test('a line per <p>, in order of time, with the plain text', () {
      final lyrics = Lyrics.fromTtml(ttml, source: 'BetterLyrics')!;
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.source, 'BetterLyrics');
      expect(
        [for (final l in lyrics.syncedLyrics) l.text],
        ['line without words', "Tom& Jerry's", 'Hello world'],
      );
      expect([for (final l in lyrics.syncedLyrics) l.time], [ms(1500), ms(5500), ms(12000)]);
      expect(lyrics.plainLyrics, "line without words\nTom& Jerry's\nHello world");
    });

    test('a timed <span> per word, the space going to the word before', () {
      final line = Lyrics.fromTtml(ttml)!.syncedLyrics.last;
      expect(line.words.first.text, 'Hello ');
      expect([for (final w in line.words) w.text.trim()], ['Hello', 'world']);
      expect(line.words.first.start, ms(12000));
      expect(line.words.first.end, ms(12400));
      expect(line.words.last.end, ms(13000));
    });

    test('the words put together give the line back, also in indented TTML', () {
      for (final line in Lyrics.fromTtml(ttml)!.syncedLyrics) {
        if (line.words.isEmpty) continue;
        expect(line.words.map((w) => w.text).join(), line.text);
      }
      expect([for (final w in Lyrics.fromTtml(ttml)!.syncedLyrics.last.words) w.text],
          ['Hello ', 'world']);
    });

    test('backing vocals (x-bg) are left out', () {
      final lyrics = Lyrics.fromTtml(ttml)!;
      expect(lyrics.plainLyrics, isNot(contains('ooh')));
      for (final line in lyrics.syncedLyrics) {
        expect(line.words.map((w) => w.text).join(), isNot(contains('ooh')));
      }
    });

    test('reads clock times with minutes and unescapes entities', () {
      final words = Lyrics.fromTtml(ttml)!.syncedLyrics[1].words;
      expect([for (final w in words) w.text], ['Tom', '& ', "Jerry's"]);
      expect(words.last.start, ms(66500));
      expect(words.last.end, ms(67000));
    });

    test('a line without spans is timed but has no words', () {
      final lyrics = Lyrics.fromTtml(ttml)!;
      expect(lyrics.syncedLyrics.first.words, isEmpty);
      expect(lyrics.isWordSynced, isTrue);
    });

    test('null when nothing is timed or it is not TTML', () {
      expect(Lyrics.fromTtml('<tt><body><p>no time</p></body></tt>'), isNull);
      expect(Lyrics.fromTtml('just words'), isNull);
      expect(Lyrics.fromTtml('<html><body></body></html>'), isNull);
    });
  });

  group('Lyrics.parseAny', () {
    test('plain text stays plain', () {
      final lyrics = Lyrics.parseAny('first line\nsecond line\n', source: 'Genius');
      expect(lyrics.isSynced, isFalse);
      expect(lyrics.lines, ['first line', 'second line']);
      expect(lyrics.source, 'Genius');
    });

    test('recognizes LRC', () {
      final lyrics = Lyrics.parseAny('﻿[00:01.00]hello\n[00:02.00]world');
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.syncedLyrics, hasLength(2));
      expect(lyrics.syncedLyrics.first.time, ms(1000));
    });

    test('recognizes TTML', () {
      final lyrics = Lyrics.parseAny('  <tt><body><p begin="1.0">hi</p></body></tt>');
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.syncedLyrics.single.text, 'hi');
    });

    test('empty input and markup without lyrics give empty lyrics', () {
      expect(Lyrics.parseAny('').isEmpty, isTrue);
      expect(Lyrics.parseAny(' \n ').isEmpty, isTrue);
      expect(Lyrics.parseAny('<html><body>404</body></html>').isEmpty, isTrue);
    });
  });
}
