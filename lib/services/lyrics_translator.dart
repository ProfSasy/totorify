import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';
import 'app_settings.dart';

/// The translation of a song's lines, and how the lines written in another
/// alphabet are pronounced in Latin letters.
@immutable
class LyricsAnnotations {
  const LyricsAnnotations({this.translations = const [], this.romanized = const []});

  /// One per line, empty where there is nothing to show.
  final List<String> translations;
  final List<String> romanized;

  static const empty = LyricsAnnotations();
}

/// Translates lyrics and spells them in Latin letters with Google
/// Translate's public endpoint (the one of the browser extensions), as the
/// translator of YumaPlayer does. Lines are sent a few dozen at a time.
class LyricsTranslator {
  LyricsTranslator._();
  static final LyricsTranslator instance = LyricsTranslator._();

  static const int _maxCharsPerBatch = 3000;
  final http.Client _client = http.Client();
  final Map<String, LyricsAnnotations> _cache = {};

  /// The languages offered for the translation, by code.
  static const Map<String, String> languages = {
    'it': 'Italiano',
    'en': 'Inglese',
    'es': 'Spagnolo',
    'fr': 'Francese',
    'de': 'Tedesco',
    'pt': 'Portoghese',
    'ja': 'Giapponese',
    'ko': 'Coreano',
    'zh-CN': 'Cinese',
    'ru': 'Russo',
    'ar': 'Arabo',
  };

  /// Whether [text] is written in an alphabet other than the Latin one, so
  /// that spelling it in Latin letters helps.
  static bool needsRomanization(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x0370 && rune <= 0x03FF) return true; // Greek
      if (rune >= 0x0400 && rune <= 0x04FF) return true; // Cyrillic
      if (rune >= 0x0590 && rune <= 0x06FF) return true; // Hebrew, Arabic
      if (rune >= 0x0900 && rune <= 0x0DFF) return true; // Indian scripts
      if (rune >= 0x0E00 && rune <= 0x0E7F) return true; // Thai
      if (rune >= 0x3040 && rune <= 0x30FF) return true; // Kana
      if (rune >= 0x3400 && rune <= 0x9FFF) return true; // Han
      if (rune >= 0xAC00 && rune <= 0xD7AF) return true; // Hangul
      if (rune >= 0x1100 && rune <= 0x11FF) return true; // Hangul jamo
    }
    return false;
  }

  /// Translation into [target] (when [translate]) and the Latin spelling
  /// (when [romanize]) of [lines]. Lines already in [target] get no
  /// translation.
  Future<LyricsAnnotations> annotate(
    List<String> lines, {
    required String target,
    required bool translate,
    required bool romanize,
  }) async {
    if (lines.isEmpty || (!translate && !romanize)) return LyricsAnnotations.empty;
    final wantsRomanization = romanize && lines.any(needsRomanization);
    if (!translate && !wantsRomanization) return LyricsAnnotations.empty;

    final key = '${lines.join('\n').hashCode}|$target|$translate|$wantsRomanization';
    final cached = _cache[key];
    if (cached != null) return cached;

    // With a model of the user's, it translates (and spells) instead.
    if (AppSettings.instance.aiTranslation.value && AiService.instance.configured.value) {
      try {
        final annotations = await _withAi(lines, target, translate, wantsRomanization);
        _cache[key] = annotations;
        return annotations;
      } catch (e) {
        debugPrint('LyricsTranslator: IA non riuscita, uso Google ($e)');
      }
    }

    final translations = List<String>.filled(lines.length, '');
    final romanized = List<String>.filled(lines.length, '');
    // Batches of whole lines, under the size a request takes.
    var start = 0;
    while (start < lines.length) {
      var end = start;
      var chars = 0;
      while (end < lines.length &&
          (end == start || chars + lines[end].length < _maxCharsPerBatch)) {
        chars += lines[end].length + 1;
        end++;
      }
      final batch = lines.sublist(start, end);
      final result = await _request(batch, target: target, romanize: wantsRomanization);
      for (var i = 0; i < batch.length; i++) {
        if (translate && i < result.translations.length) {
          final translated = result.translations[i].trim();
          // The same line back means it was already in that language.
          if (translated.toLowerCase() != batch[i].trim().toLowerCase()) {
            translations[start + i] = translated;
          }
        }
        if (wantsRomanization && i < result.romanized.length && needsRomanization(batch[i])) {
          romanized[start + i] = result.romanized[i].trim();
        }
      }
      start = end;
    }
    final annotations = LyricsAnnotations(translations: translations, romanized: romanized);
    _cache[key] = annotations;
    if (_cache.length > 30) _cache.remove(_cache.keys.first);
    return annotations;
  }

  Future<LyricsAnnotations> _withAi(
    List<String> lines,
    String target,
    bool translate,
    bool romanize,
  ) async {
    final language = languages[target] ?? target;
    final numbered = [for (var i = 0; i < lines.length; i++) '$i: ${lines[i]}'].join('\n');
    final answer = await AiService.instance.complete(
      'Ecco le righe di una canzone, numerate:\n$numbered\n\n'
      'Rispondi solo con un oggetto JSON con due liste di ${lines.length} stringhe, una per riga '
      'e nello stesso ordine: "t" con la traduzione in $language '
      '(stringa vuota se la riga è già in $language o se non va tradotta)'
      '${romanize ? ', "r" con la pronuncia in lettere latine delle righe scritte in un altro '
          'alfabeto (stringa vuota per le altre)' : ''}.',
      system: 'Traduci testi di canzoni in modo naturale e fedele al senso, riga per riga.',
      maxTokens: 8000,
    );
    final data = AiService.extractJson(answer);
    if (data is! Map) throw FormatException('risposta non in JSON');
    List<String> list(Object? raw) {
      if (raw is! List || raw.length != lines.length) return List<String>.filled(lines.length, '');
      return [for (final item in raw) '${item ?? ''}'.trim()];
    }

    return LyricsAnnotations(
      translations: translate ? list(data['t']) : const [],
      romanized: romanize ? list(data['r']) : const [],
    );
  }

  Future<({List<String> translations, List<String> romanized})> _request(
    List<String> lines, {
    required String target,
    required bool romanize,
  }) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': target,
      'dt': ['t', if (romanize) 'rm'],
      'q': lines.join('\n'),
    });
    final response = await _client.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    return parse(utf8.decode(response.bodyBytes), lines.length);
  }

  /// Reads an answer of the endpoint: its sentences put back together and
  /// split again by line. Public for the tests.
  static ({List<String> translations, List<String> romanized}) parse(String body, int lineCount) {
    final data = jsonDecode(body);
    if (data is! List || data.isEmpty || data[0] is! List) {
      return (translations: const <String>[], romanized: const <String>[]);
    }
    final translated = StringBuffer();
    final romanized = StringBuffer();
    for (final part in data[0] as List) {
      if (part is! List) continue;
      if (part.isNotEmpty && part[0] is String) {
        translated.write(part[0]);
      } else if (part.length > 3 && part[3] is String) {
        // The spelling of the source, in its own entry at the end.
        romanized.write(part[3]);
      }
    }
    List<String> lines(String text) {
      final split = text.split('\n');
      return split.length >= lineCount ? split.sublist(0, lineCount) : const <String>[];
    }

    return (translations: lines(translated.toString()), romanized: lines(romanized.toString()));
  }
}
