import 'dart:convert';
import 'package:http/http.dart' as http;
import 'translation_engine.dart';

class GoogleTranslatorEngine implements TranslationEngine {
  final http.Client _client;
  final Duration timeout;

  GoogleTranslatorEngine({
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client();

  @override
  String get id => 'google_free';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
  }) async {
    if (text.trim().isEmpty) return '';

    // Use the free Google Translate API (gtx)
    // Note: This is for testing/personal use. Production apps should use the Cloud API.
    final uri = Uri.parse('https://translate.googleapis.com/translate_a/single').replace(queryParameters: {
      'client': 'gtx',
      'sl': sourceLang.isEmpty ? 'auto' : sourceLang,
      'tl': targetLang.isEmpty ? 'zh' : targetLang, // Default to Chinese if empty
      'dt': 't',
      'q': text,
    });

    try {
      final resp = await _client.get(uri).timeout(timeout);

      if (resp.statusCode != 200) {
        throw Exception('Google translate failed: ${resp.statusCode}');
      }

      final decoded = jsonDecode(resp.body);
      if (decoded is List && decoded.isNotEmpty) {
        final sentences = decoded[0];
        if (sentences is List) {
          final buffer = StringBuffer();
          for (final s in sentences) {
            if (s is List && s.isNotEmpty) {
              buffer.write(s[0].toString());
            }
          }
          return buffer.toString();
        }
      }
      return text; // Fallback to original
    } catch (e) {
      // Fallback or rethrow
      return text;
    }
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
    required Map<String, String> glossaryPlaceholders,
  }) async {
    // The free API doesn't support batching well in a single call efficiently without complex parsing.
    // We'll do sequential calls for now (or parallel).
    // Given it's for testing, parallel is fine.
    final futures = texts.map((t) => translate(
      text: t,
      sourceLang: sourceLang,
      targetLang: targetLang,
      contextSources: [],
      glossaryPlaceholders: glossaryPlaceholders,
    ));
    return Future.wait(futures);
  }
}
