import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_engine.dart';

import '../translation_types.dart';

/// Volcengine LLM translator.

/// Default implementation targets Ark (OpenAI-compatible) endpoint.
class VolcLlmTranslatorEngine extends TranslationEngine {

  final http.Client _client;
  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;

  VolcLlmTranslatorEngine({
    http.Client? client,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 2),
  }) : _client = client ?? http.Client();

  @override
  String get id => 'volc_llm';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
    required List<TranslationReference> references,
  }) async {
    final uri = Uri.parse(baseUrl);

    final glossaryHint = glossaryPlaceholders.isEmpty
        ? '无'
        : glossaryPlaceholders.entries
            .map((e) => '${e.key} -> ${e.value}')
            .join('\n');

    final referencesHint = references.isEmpty
        ? '无'
        : references
            .map((e) => '源文：${e.text}\n译文：${e.translation}')
            .join('\n\n');

    final ctx = contextSources.isEmpty
        ? '无'
        : contextSources.map((e) => '- $e').join('\n');

    final prompt = '''你是一名专业文学翻译。
要求：
1) 只输出译文，不要解释。
2) 必须保持术语一致性：以下占位符必须原样保留在译文中，且最终会被替换为固定术语：\n$glossaryHint
3) 保持上下文连贯：参考最近的原文上下文。\n上下文：\n$ctx
4) 参考以下翻译实例，保持风格和用词一致：\n$referencesHint

待翻译文本（源语言：${sourceLang.isEmpty ? '自动' : sourceLang}，目标语言：$targetLang）：\n$text''';


    final payload = {
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': '你是严格的翻译引擎。',
        },
        {
          'role': 'user',
          'content': prompt,
        }
      ],
      'temperature': 0.2,
    };

    final resp = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('Volc LLM translate failed: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    // OpenAI-style
    final choices = (decoded is Map) ? decoded['choices'] : null;
    if (choices is List && choices.isNotEmpty) {
      final msg = (choices.first as Map)['message'];
      final content = (msg is Map) ? msg['content']?.toString() : null;
      if (content != null) return content.trim();
    }

    throw HttpException('Volc LLM translate invalid response');
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => message;
}
