import 'package:flutter_test/flutter_test.dart';

import 'package:airread/ai/translation/engines/translation_engine.dart';
import 'package:airread/ai/translation/glossary.dart';
import 'package:airread/ai/translation/translation_cache.dart';
import 'package:airread/ai/translation/translation_service.dart';
import 'package:airread/ai/translation/translation_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeEngine implements TranslationEngine {
  @override
  final String id;

  List<List<String>> seenContexts = [];

  _FakeEngine(this.id);

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
  }) async {
    seenContexts.add(contextSources);
    return '[$id:$targetLang]$text';
  }
}

void main() {
  test('AI engine receives last 3 source paragraphs as context', () async {
    SharedPreferences.setMockInitialValues({});

    final cache = TranslationCache(ttl: const Duration(hours: 24));
    final glossary = GlossaryManager();

    final machine = _FakeEngine('machine');
    final ai = _FakeEngine('ai');

    final svc = TranslationService(
      cache: cache,
      glossary: glossary,
      machineEngine: machine,
      aiEngine: ai,
    );

    final cfg = const TranslationConfig(
      engineType: TranslationEngineType.ai,
      sourceLang: 'zh-Hans',
      targetLang: 'en',
      displayMode: TranslationDisplayMode.translationOnly,
    );

    await svc.translateParagraph(config: cfg, paragraphText: 'P1');
    await svc.translateParagraph(config: cfg, paragraphText: 'P2');
    await svc.translateParagraph(config: cfg, paragraphText: 'P3');
    await svc.translateParagraph(config: cfg, paragraphText: 'P4');

    // For P4, context should include last 3 source paragraphs: P1,P2,P3 (in order)
    final lastCtx = ai.seenContexts.last;
    expect(lastCtx.length, 3);
    expect(lastCtx[0], 'P1');
    expect(lastCtx[1], 'P2');
    expect(lastCtx[2], 'P3');
  });
}
