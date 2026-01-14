import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'translation_engine.dart';

class LibreTranslateEngine implements TranslationEngine {
  static const List<String> _defaultBaseUrls = [
    'https://translate.terraprint.co/',
    'https://libretranslate.com/',
  ];

  final http.Client _client;
  final List<Uri> _baseUrls;
  final String apiKey;
  final Duration timeout;

  Uri? _preferredBaseUrl;

  LibreTranslateEngine({
    http.Client? client,
    String? baseUrl,
    String apiKey = '',
    this.timeout = const Duration(seconds: 3),
  })  : _client = client ?? http.Client(),
        apiKey = apiKey,
        _baseUrls = [
          if (baseUrl != null && baseUrl.trim().isNotEmpty) _normalizeBaseUrl(baseUrl),
          ..._defaultBaseUrls.map(_normalizeBaseUrl),
        ];

  static Uri _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    final withSlash = trimmed.endsWith('/') ? trimmed : '$trimmed/';
    return Uri.parse(withSlash);
  }

  @override
  String get id => 'libretranslate';

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
    if (texts.isEmpty) return const [];
    final out = List<String>.filled(texts.length, '');

    final futures = <Future<void>>[];
    for (int i = 0; i < texts.length; i++) {
      futures.add(() async {
        out[i] = await _translateOne(
          text: texts[i],
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
      }());
    }
    await Future.wait(futures);
    return out;
  }

  Future<String> _translateOne({
    required String text,
    required String sourceLang,
    required String targetLang,
  }) async {
    final List<Uri> candidates = [
      if (_preferredBaseUrl != null) _preferredBaseUrl!,
      ..._baseUrls.where((e) => e != _preferredBaseUrl),
    ];

    final errors = <String>[];
    for (final base in candidates) {
      try {
        final translated = await _translateViaBaseUrl(
          baseUrl: base,
          text: text,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
        _preferredBaseUrl = base;
        return translated;
      } catch (e) {
        errors.add('${base.toString()} ${e.toString()}');
      }
    }

    throw HttpException('LibreTranslate translate failed: ${errors.join(' | ')}');
  }

  Future<String> _translateViaBaseUrl({
    required Uri baseUrl,
    required String text,
    required String sourceLang,
    required String targetLang,
  }) async {
    final uri = baseUrl.resolve('translate');
    final String src = sourceLang.trim().isEmpty ? 'auto' : sourceLang.trim();
    final String dst = targetLang.trim();
    if (dst.isEmpty) throw HttpException('targetLang is empty');

    final body = <String, dynamic>{
      'q': text,
      'source': src,
      'target': dst,
      'format': 'text',
    };
    if (apiKey.trim().isNotEmpty) {
      body['api_key'] = apiKey.trim();
    }

    final resp = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json; charset=UTF-8',
            'Accept': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode} ${_trimForLog(resp.body)}');
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      throw HttpException('invalid response');
    }
    final translated = decoded['translatedText']?.toString();
    if (translated == null) {
      throw HttpException('missing translatedText');
    }
    return translated;
  }

  static String _trimForLog(String raw) {
    final s = raw.replaceAll('\n', ' ').trim();
    final limit = min(160, s.length);
    return s.substring(0, limit);
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => message;
}

