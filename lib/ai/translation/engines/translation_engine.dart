abstract class TranslationEngine {
  String get id;

  /// Translate a single paragraph/text.
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  });

  /// Optional batch translation for speed.
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
  }) async {
    final out = <String>[];
    for (final t in texts) {
      out.add(await translate(
        text: t,
        sourceLang: sourceLang,
        targetLang: targetLang,
        contextSources: const [],
      ));
    }
    return out;
  }
}
