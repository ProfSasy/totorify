/// One word (or syllable) of a line sung word by word: when it starts and
/// ends. [text] keeps the space that follows it, so that the words of a
/// line put together give the line back.
class LyricWord {
  final Duration start;
  final Duration end;
  final String text;

  const LyricWord({required this.start, required this.end, required this.text});

  List<Object> toList() => [start.inMilliseconds, end.inMilliseconds, text];

  static LyricWord? fromList(Object? raw) {
    if (raw is! List || raw.length != 3 || raw[0] is! int || raw[1] is! int || raw[2] is! String) {
      return null;
    }
    return LyricWord(
      start: Duration(milliseconds: raw[0] as int),
      end: Duration(milliseconds: raw[1] as int),
      text: raw[2] as String,
    );
  }
}

class LyricLine {
  final Duration time;
  final String text;

  /// The words with their timing, for lyrics sung word by word; empty for
  /// lyrics timed line by line.
  final List<LyricWord> words;

  const LyricLine({required this.time, required this.text, this.words = const []});

  LyricLine shifted(Duration by) => LyricLine(
    time: time + by,
    text: text,
    words: [
      for (final word in words)
        LyricWord(start: word.start + by, end: word.end + by, text: word.text),
    ],
  );

  @override
  String toString() => '${time.inMilliseconds}ms: $text';
}

class Lyrics {
  final String plainLyrics;
  final List<LyricLine> syncedLyrics;
  final bool isSynced;

  /// Where they come from ("LRCLIB", "BetterLyrics"…), or "Modificato"
  /// when the user wrote them.
  final String source;

  const Lyrics({
    this.plainLyrics = '',
    this.syncedLyrics = const [],
    this.isSynced = false,
    this.source = '',
  });

  static Lyrics empty = const Lyrics();

  bool get isNotEmpty => syncedLyrics.isNotEmpty || plainLyrics.isNotEmpty;
  bool get isEmpty => !isNotEmpty;

  /// True when at least a line is timed word by word (karaoke).
  bool get isWordSynced => syncedLyrics.any((line) => line.words.isNotEmpty);

  /// The lines to show, one per row: the timed ones, or the plain text.
  List<String> get lines => isSynced
      ? [for (final line in syncedLyrics) line.text]
      : plainLyrics
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList();

  Lyrics withSource(String source) => Lyrics(
    plainLyrics: plainLyrics,
    syncedLyrics: syncedLyrics,
    isSynced: isSynced,
    source: source,
  );

  /// The same lyrics, every line [by] later (earlier when negative).
  Lyrics shifted(Duration by) => by == Duration.zero
      ? this
      : Lyrics(
          plainLyrics: plainLyrics,
          syncedLyrics: [for (final line in syncedLyrics) line.shifted(by)],
          isSynced: isSynced,
          source: source,
        );

  /// As LRC text, for editing: timed lines as `[mm:ss.cc] text`.
  String toLrc() {
    if (!isSynced) return plainLyrics;
    String stamp(Duration d) {
      final minutes = d.inMinutes.toString().padLeft(2, '0');
      final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
      final hundredths = ((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
      return '[$minutes:$seconds.$hundredths]';
    }

    return [for (final line in syncedLyrics) '${stamp(line.time)} ${line.text}'].join('\n');
  }

  /// Compact form for storage: synced lines as [milliseconds, text] pairs,
  /// with their words when they have them.
  Map<String, dynamic> toMap() => {
    'plain': plainLyrics,
    'synced': [
      for (final line in syncedLyrics)
        [
          line.time.inMilliseconds,
          line.text,
          if (line.words.isNotEmpty) [for (final word in line.words) word.toList()],
        ],
    ],
    if (source.isNotEmpty) 'source': source,
  };

  factory Lyrics.fromMap(Map<String, dynamic> map) {
    final synced = <LyricLine>[];
    for (final raw in map['synced'] as List<dynamic>? ?? const []) {
      if (raw is! List || raw.length < 2 || raw[0] is! int || raw[1] is! String) continue;
      final words = <LyricWord>[
        if (raw.length > 2 && raw[2] is List)
          for (final word in raw[2] as List) ?LyricWord.fromList(word),
      ];
      synced.add(
        LyricLine(
          time: Duration(milliseconds: raw[0] as int),
          text: raw[1] as String,
          words: words,
        ),
      );
    }
    return Lyrics(
      plainLyrics: map['plain'] as String? ?? '',
      syncedLyrics: synced,
      isSynced: synced.isNotEmpty,
      source: map['source'] as String? ?? '',
    );
  }

  /// Parses LRC text, also the "enhanced" kind with the time of each word
  /// (`[00:12.30]<00:12.30>Word <00:12.80>another`).
  factory Lyrics.fromLrc(String lrcText, {String? plainFallback, String source = ''}) {
    if (lrcText.trim().isEmpty) {
      return Lyrics(plainLyrics: plainFallback ?? '', source: source);
    }

    final lines = lrcText.split('\n');
    final lineRegExp = RegExp(r'^((?:\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]\s*)+)(.*)$');
    final stampRegExp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final wordRegExp = RegExp(r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>');
    final parsed = <LyricLine>[];
    final plainLines = <String>[];

    Duration toDuration(Match m) {
      final minutes = int.tryParse(m.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(m.group(2) ?? '0') ?? 0;
      final fraction = m.group(3) ?? '0';
      final millis = int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
      return Duration(minutes: minutes, seconds: seconds, milliseconds: millis);
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      final match = lineRegExp.firstMatch(line);
      if (match == null) {
        final cleaned = line.replaceAll(RegExp(r'\[.*?\]'), '').trim();
        if (cleaned.isNotEmpty) plainLines.add(cleaned);
        continue;
      }
      final content = match.group(2) ?? '';
      // Words, when the line carries their times.
      final stamps = wordRegExp.allMatches(content).toList();
      final words = <LyricWord>[];
      for (var i = 0; i < stamps.length; i++) {
        final start = stamps[i].end;
        final end = i + 1 < stamps.length ? stamps[i + 1].start : content.length;
        final text = content.substring(start, end);
        if (text.trim().isEmpty) continue;
        final from = toDuration(stamps[i]);
        final to = i + 1 < stamps.length
            ? toDuration(stamps[i + 1])
            : from + const Duration(milliseconds: 600);
        words.add(LyricWord(start: from, end: to, text: text));
      }
      final text = content.replaceAll(wordRegExp, '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      // A line can carry several times: it is sung at each of them.
      for (final stamp in stampRegExp.allMatches(match.group(1)!)) {
        parsed.add(LyricLine(time: toDuration(stamp), text: text, words: words));
      }
      plainLines.add(text);
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));

    return Lyrics(
      plainLyrics: plainLines.isNotEmpty ? plainLines.join('\n') : (plainFallback ?? ''),
      syncedLyrics: parsed,
      isSynced: parsed.isNotEmpty,
      source: source,
    );
  }

  /// Parses TTML (the format of Apple Music's lyrics, given by BetterLyrics
  /// and the other karaoke sources): a `<p>` per line, a timed `<span>` per
  /// word. Backing vocals (`x-bg`) are left out. Null when nothing is timed.
  static Lyrics? fromTtml(String ttml, {String source = ''}) {
    if (!ttml.contains('<tt') && !ttml.contains('<p')) return null;
    final paragraphRegExp = RegExp(r'<p\b([^>]*)>(.*?)</p>', dotAll: true);
    final tokenRegExp = RegExp(r'<(/?)span\b([^>]*)>|<[^>]+>|([^<]+)');
    final lines = <LyricLine>[];

    for (final paragraph in paragraphRegExp.allMatches(ttml)) {
      final attributes = paragraph.group(1)!;
      final begin = _ttmlTime(_attribute(attributes, 'begin'));
      if (begin == null) continue;

      final words = <LyricWord>[];
      final text = StringBuffer();
      // Each open span: its timing, and whether it is backing vocals.
      final spans = <({Duration? begin, Duration? end, bool background})>[];
      for (final token in tokenRegExp.allMatches(paragraph.group(2)!)) {
        final plain = token.group(3);
        if (plain != null) {
          if (spans.any((span) => span.background)) continue;
          final value = _unescape(plain);
          final timed = spans.isEmpty ? null : spans.last;
          if (timed?.begin != null && value.trim().isNotEmpty) {
            words.add(
              LyricWord(
                start: timed!.begin!,
                end: timed.end ?? timed.begin! + const Duration(milliseconds: 600),
                text: value,
              ),
            );
          } else if (words.isNotEmpty && value.trim().isEmpty) {
            // The space between two words belongs to the first.
            final last = words.removeLast();
            words.add(LyricWord(start: last.start, end: last.end, text: '${last.text} '));
          }
          text.write(value);
          continue;
        }
        if (token.group(0)!.startsWith('<span') || token.group(0)!.startsWith('</span')) {
          if (token.group(1) == '/') {
            if (spans.isNotEmpty) spans.removeLast();
          } else {
            final spanAttributes = token.group(2) ?? '';
            spans.add((
              begin: _ttmlTime(_attribute(spanAttributes, 'begin')),
              end: _ttmlTime(_attribute(spanAttributes, 'end')),
              background: spanAttributes.contains('x-bg'),
            ));
          }
        }
      }
      final line = text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      lines.add(LyricLine(time: begin, text: line, words: words));
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(
      plainLyrics: lines.map((line) => line.text).join('\n'),
      syncedLyrics: lines,
      isSynced: true,
      source: source,
    );
  }

  static String? _attribute(String attributes, String name) =>
      RegExp('\\b$name\\s*=\\s*"([^"]*)"').firstMatch(attributes)?.group(1);

  /// "12.345", "1:02.5", "00:01:02.500", "12.3s" or "1234ms" as a duration.
  static Duration? _ttmlTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    var value = raw.trim();
    if (value.endsWith('ms')) {
      final ms = double.tryParse(value.substring(0, value.length - 2));
      return ms == null ? null : Duration(milliseconds: ms.round());
    }
    if (value.endsWith('s')) value = value.substring(0, value.length - 1);
    final parts = value.split(':');
    var seconds = 0.0;
    for (final part in parts) {
      final number = double.tryParse(part);
      if (number == null) return null;
      seconds = seconds * 60 + number;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static String _unescape(String text) => text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");

  /// Lyrics in any of the formats the sources give: TTML, LRC (also word by
  /// word) or plain text.
  static Lyrics parseAny(String raw, {String source = ''}) {
    final text = raw.replaceAll('﻿', '').trim();
    if (text.isEmpty) return Lyrics.empty;
    if (text.startsWith('<')) {
      return fromTtml(text, source: source) ?? Lyrics.empty;
    }
    final lrc = Lyrics.fromLrc(text, source: source);
    if (lrc.isNotEmpty) return lrc;
    return Lyrics(plainLyrics: text, source: source);
  }
}
