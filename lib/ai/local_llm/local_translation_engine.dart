import '../translation/engines/translation_engine.dart';
import '../translation/translation_types.dart';
import 'local_llm_client.dart';

class LocalTranslationEngine extends TranslationEngine {
  final LocalLlmClient _client;

  LocalTranslationEngine({LocalLlmClient? client})
      : _client = client ?? LocalLlmClient();

  @override
  String get id => 'local_hunyuan';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
    required List<TranslationReference> references,
  }) {
    return _client.translate(

      text: text,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
  }
}
