import 'package:flutter_test/flutter_test.dart';

import 'package:airread/ai/translation/glossary.dart';

void main() {
  test('glossary applies placeholders and restores targets', () {
    final g = GlossaryManager();
    g.addOrUpdate(const GlossaryTerm(source: 'AirRead', target: '空气读'));
    g.addOrUpdate(const GlossaryTerm(source: 'GPT', target: '通用模型'));

    final applied = g.applyToSourceText('AirRead uses GPT. AirRead!');
    expect(applied.textWithPlaceholders.contains('AirRead'), isFalse);
    expect(applied.textWithPlaceholders.contains('{{AR_TERM_'), isTrue);

    final translatedWithPlaceholders = applied.textWithPlaceholders;
    final restored = g.applyToTranslatedText(translatedWithPlaceholders, applied.placeholderToTarget);

    expect(restored.contains('空气读'), isTrue);
    expect(restored.contains('通用模型'), isTrue);
  });
}
