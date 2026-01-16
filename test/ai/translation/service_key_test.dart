import 'package:flutter_test/flutter_test.dart';

import 'package:airread/ai/translation/engines/translation_engine.dart';
import 'package:airread/ai/translation/glossary.dart';
import 'package:airread/ai/translation/translation_cache.dart';
import 'package:airread/ai/translation/translation_service.dart';
import 'package:airread/ai/translation/translation_types.dart';

class _FakeEngine extends TranslationEngine {
  @override
  String get id => 'fake_engine';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
  }) async {
    return 'ok';
  }
}

void main() {
  test('buildCacheKey normalizes leading spaces and applies glossary', () {
    final cache = TranslationCache(ttl: const Duration(hours: 1));
    final glossary = GlossaryManager();
    glossary.addOrUpdate(const GlossaryTerm(source: 'AirRead', target: '空气读'));

    final service = TranslationService(
      cache: cache,
      glossary: glossary,
      machineEngine: _FakeEngine(),
      aiEngine: _FakeEngine(),
    );

    const cfg = TranslationConfig(
      sourceLang: '',
      targetLang: 'en',
      displayMode: TranslationDisplayMode.bilingual,
    );

    final k1 = service.buildCacheKey(
      config: cfg,
      paragraphText: '\u3000  AirRead is great',
    );
    final k2 = service.buildCacheKey(
      config: cfg,
      paragraphText: 'AirRead is great',
    );
    expect(k1, k2);
  });

  test('buildCacheKey changes when glossary version changes', () {
    final cache = TranslationCache(ttl: const Duration(hours: 1));
    final glossary = GlossaryManager();

    final service = TranslationService(
      cache: cache,
      glossary: glossary,
      machineEngine: _FakeEngine(),
      aiEngine: _FakeEngine(),
    );

    const cfg = TranslationConfig(
      sourceLang: '',
      targetLang: 'en',
      displayMode: TranslationDisplayMode.bilingual,
    );

    final k1 = service.buildCacheKey(
      config: cfg,
      paragraphText: 'AirRead',
    );

    glossary.addOrUpdate(const GlossaryTerm(source: 'AirRead', target: '空气读'));

    final k2 = service.buildCacheKey(
      config: cfg,
      paragraphText: 'AirRead',
    );

    expect(k1 == k2, isFalse);
  });
}
