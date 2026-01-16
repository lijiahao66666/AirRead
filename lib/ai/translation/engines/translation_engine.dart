import '../translation_types.dart';

abstract class TranslationEngine {

  String get id;

  /// Translate a single paragraph/text.
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
    required List<TranslationReference> references,
  });


  /// Optional batch translation for speed.
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
    required Map<String, String> glossaryPlaceholders,
    required List<TranslationReference> references,
  }) async {
    final out = <String>[];
    for (final t in texts) {
      out.add(await translate(
        text: t,
        sourceLang: sourceLang,
        targetLang: targetLang,
        contextSources: const [],
        glossaryPlaceholders: glossaryPlaceholders,
        references: references,
      ));
    }
    return out;
  }

}
