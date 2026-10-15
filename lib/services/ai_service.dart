import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'app_settings.dart';

/// The services of artificial intelligence the user can connect, with a
/// key of their own.
enum AiProvider {
  anthropic('Claude (Anthropic)', 'claude-opus-5-5'),
  openai('OpenAI o compatibile (OpenRouter…)', 'gpt-4o-mini'),
  gemini('Gemini (Google)', 'gemini-2.5-flash');

  const AiProvider(this.label, this.defaultModel);

  final String label;
  final String defaultModel;
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Asks a model for text, with the key the user gave (kept in the
/// device's keychain, never in a backup). Used to translate lyrics and to
/// make mixes from what the user listens to, as YumaPlayer does.
class AiService {
  AiService._();
  static final AiService instance = AiService._();

  static const String _keyName = 'ai_api_key';
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final http.Client _client = http.Client();
  String? _key;

  /// Whether a key is set, so that the features that need it show.
  final ValueNotifier<bool> configured = ValueNotifier<bool>(false);

  AiProvider get provider => AiProvider.values.firstWhere(
    (p) => p.name == AppSettings.instance.aiProvider.value,
    orElse: () => AiProvider.anthropic,
  );

  String get model {
    final custom = AppSettings.instance.aiModel.value.trim();
    return custom.isEmpty ? provider.defaultModel : custom;
  }

  Future<void> init() async {
    try {
      _key = await _secure.read(key: _keyName);
    } catch (e) {
      debugPrint('AiService.init: $e');
    }
    configured.value = (_key ?? '').isNotEmpty;
  }

  Future<void> setKey(String? key) async {
    final clean = key?.trim() ?? '';
    _key = clean.isEmpty ? null : clean;
    try {
      if (_key == null) {
        await _secure.delete(key: _keyName);
      } else {
        await _secure.write(key: _keyName, value: _key);
      }
    } catch (e) {
      debugPrint('AiService.setKey: $e');
    }
    configured.value = _key != null;
  }

  /// The model's answer to [prompt], under the instructions in [system].
  Future<String> complete(String prompt, {String? system, int maxTokens = 4000}) async {
    final key = _key;
    if (key == null) throw AiException('Configura prima l\'intelligenza artificiale');
    return switch (provider) {
      AiProvider.anthropic => _anthropic(key, prompt, system, maxTokens),
      AiProvider.openai => _openai(key, prompt, system, maxTokens),
      AiProvider.gemini => _gemini(key, prompt, system, maxTokens),
    };
  }

  Future<String> _anthropic(String key, String prompt, String? system, int maxTokens) async {
    final response = await _client
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': model,
            'max_tokens': maxTokens,
            // Short, simple tasks: little thinking is needed.
            'output_config': {'effort': 'low'},
            'system': ?system,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));
    final data = _decode(response);
    if (data['stop_reason'] == 'refusal') throw AiException('Il modello ha rifiutato la richiesta');
    final blocks = data['content'] as List? ?? const [];
    return [
      for (final block in blocks)
        if (block is Map && block['type'] == 'text') '${block['text']}',
    ].join();
  }

  Future<String> _openai(String key, String prompt, String? system, int maxTokens) async {
    var base = AppSettings.instance.aiEndpoint.value.trim();
    if (base.isEmpty) base = 'https://api.openai.com/v1';
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final response = await _client
        .post(
          Uri.parse('$base/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $key'},
          body: jsonEncode({
            'model': model,
            'max_tokens': maxTokens,
            'messages': [
              if (system != null) {'role': 'system', 'content': system},
              {'role': 'user', 'content': prompt},
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));
    final data = _decode(response);
    final choices = data['choices'] as List? ?? const [];
    if (choices.isEmpty) throw AiException('Risposta vuota');
    return '${(choices.first as Map)['message']?['content'] ?? ''}';
  }

  Future<String> _gemini(String key, String prompt, String? system, int maxTokens) async {
    final response = await _client
        .post(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
          ),
          headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
          body: jsonEncode({
            if (system != null)
              'systemInstruction': {
                'parts': [
                  {'text': system},
                ],
              },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
            'generationConfig': {'maxOutputTokens': maxTokens},
          }),
        )
        .timeout(const Duration(seconds: 90));
    final data = _decode(response);
    final candidates = data['candidates'] as List? ?? const [];
    if (candidates.isEmpty) throw AiException('Risposta vuota');
    final parts = (candidates.first as Map)['content']?['parts'] as List? ?? const [];
    return [
      for (final part in parts)
        if (part is Map) '${part['text'] ?? ''}',
    ].join();
  }

  Map<String, dynamic> _decode(http.Response response) {
    Object? data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {}
    if (response.statusCode != 200 || data is! Map) {
      final error = data is Map ? data['error'] : null;
      final message = error is Map ? error['message'] : error;
      throw AiException('Errore ${response.statusCode}${message == null ? '' : ': $message'}');
    }
    return Map<String, dynamic>.from(data);
  }

  /// The first JSON value in [text] (models sometimes wrap it in prose or
  /// in a code fence).
  static Object? extractJson(String text) {
    final start = text.indexOf(RegExp(r'[\[{]'));
    if (start == -1) return null;
    final open = text[start];
    final close = open == '[' ? ']' : '}';
    final end = text.lastIndexOf(close);
    if (end <= start) return null;
    try {
      return jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }
}
