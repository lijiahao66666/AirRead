import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_engine.dart';

class MicrosoftTranslatorEngine implements TranslationEngine {
  static const String defaultEndpoint = 'https://api.cognitive.microsofttranslator.com';

  final http.Client _client;
  final String endpoint;
  final String subscriptionKey;
  final String subscriptionRegion;
  final Duration timeout;

  MicrosoftTranslatorEngine({
    http.Client? client,
    this.endpoint = defaultEndpoint,
    required this.subscriptionKey,
    required this.subscriptionRegion,
    this.timeout = const Duration(milliseconds: 500),
  }) : _client = client ?? http.Client();

  @override
  String get id => 'microsoft';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
  }) async {
    final results = await translateBatch(
      texts: [text],
      sourceLang: sourceLang,
      targetLang: targetLang,
      glossaryPlaceholders: glossaryPlaceholders,
    );
    return results.first;
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
    required Map<String, String> glossaryPlaceholders,
  }) async {
    final uri = Uri.parse('$endpoint/translate').replace(queryParameters: {
      'api-version': '3.0',
      if (targetLang.trim().isNotEmpty) 'to': targetLang.trim(),
      if (sourceLang.trim().isNotEmpty) 'from': sourceLang.trim(),
    });

    final body = jsonEncode(texts.map((t) => {'Text': t}).toList());

    final resp = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json; charset=UTF-8',
            'Ocp-Apim-Subscription-Key': subscriptionKey,
            'Ocp-Apim-Subscription-Region': subscriptionRegion,
          },
          body: body,
        )
        .timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('Microsoft translate failed: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! List) {
      throw HttpException('Microsoft translate invalid response');
    }

    final out = <String>[];
    for (final item in decoded) {
      final translations = (item as Map)['translations'];
      if (translations is List && translations.isNotEmpty) {
        final text = (translations.first as Map)['text']?.toString() ?? '';
        out.add(text);
      } else {
        out.add('');
      }
    }

    return out;
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => message;
}
