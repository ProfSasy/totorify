class LyricLine {
  final Duration time;
  final String text;

  const LyricLine({
    required this.time,
    required this.text,
  });

  @override
  String toString() => '${time.inMilliseconds}ms: $text';
}

class Lyrics {
  final String plainLyrics;
  final List<LyricLine> syncedLyrics;
  final bool isSynced;

  const Lyrics({
    this.plainLyrics = '',
    this.syncedLyrics = const [],
    this.isSynced = false,
  });

  static Lyrics empty = const Lyrics();

  bool get isNotEmpty => syncedLyrics.isNotEmpty || plainLyrics.isNotEmpty;
  bool get isEmpty => !isNotEmpty;

  /// Compact form for storage: synced lines as [milliseconds, text] pairs.
  Map<String, dynamic> toMap() => {
        'plain': plainLyrics,
        'synced': [
          for (final line in syncedLyrics) [line.time.inMilliseconds, line.text],
        ],
      };

  factory Lyrics.fromMap(Map<String, dynamic> map) {
    final synced = <LyricLine>[
      for (final raw in map['synced'] as List<dynamic>? ?? const [])
        if (raw is List && raw.length == 2 && raw[0] is int && raw[1] is String)
          LyricLine(time: Duration(milliseconds: raw[0] as int), text: raw[1] as String),
    ];
    return Lyrics(
      plainLyrics: map['plain'] as String? ?? '',
      syncedLyrics: synced,
      isSynced: synced.isNotEmpty,
    );
  }

  factory Lyrics.fromLrc(String lrcText, {String? plainFallback}) {
    if (lrcText.trim().isEmpty) {
      return Lyrics(
        plainLyrics: plainFallback ?? '',
        syncedLyrics: const [],
        isSynced: false,
      );
    }

    final lines = lrcText.split('\n');
    final regExp = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\](.*)');
    final parsed = <LyricLine>[];
    final plainLines = <String>[];

    for (final rawLine in lines) {
      final match = regExp.firstMatch(rawLine.trim());
      if (match != null) {
        final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
        final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
        final millisStr = match.group(3) ?? '0';
        final millis = int.tryParse(millisStr.padRight(3, '0').substring(0, 3)) ?? 0;
        final text = (match.group(4) ?? '').trim();

        final timestamp = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: millis,
        );

        if (text.isNotEmpty) {
          parsed.add(LyricLine(time: timestamp, text: text));
          plainLines.add(text);
        }
      } else {
        final cleaned = rawLine.replaceAll(RegExp(r'\[.*?\]'), '').trim();
        if (cleaned.isNotEmpty) {
          plainLines.add(cleaned);
        }
      }
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));

    return Lyrics(
      plainLyrics: plainLines.isNotEmpty
          ? plainLines.join('\n')
          : (plainFallback ?? ''),
      syncedLyrics: parsed,
      isSynced: parsed.isNotEmpty,
    );
  }
}
