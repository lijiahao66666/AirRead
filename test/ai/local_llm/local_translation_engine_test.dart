import 'package:airread/ai/local_llm/local_llm_client.dart';
import 'package:airread/ai/local_llm/local_translation_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalLlmClient extends LocalLlmClient {
  final String response;

  String? lastUserText;
  int? lastMaxInputTokens;
  int? lastMaxNewTokens;

  _FakeLocalLlmClient({required this.response})
      : super(modelType: LocalLlmModelType.translation);

  @override
  Future<int?> getMaxContextTokens() async => 4096;

  @override
  Stream<String> chatStream({
    required String userText,
    int maxNewTokens = 1024,
    int maxInputTokens = 0,
    double? temperature,
    double? topP,
    int? topK,
    double? minP,
    double? presencePenalty,
    double? repetitionPenalty,
    bool? enableThinking,
  }) {
    lastUserText = userText;
    lastMaxInputTokens = maxInputTokens;
    lastMaxNewTokens = maxNewTokens;
    return Stream<String>.fromIterable([response]);
  }
}

void main() {
  test(
      'local translation uses non-zero maxInputTokens and cleans special tokens',
      () async {
    final fake = _FakeLocalLlmClient(
      response: '<|im_end|>Hello\u0120world\u010afoo\u2581bar',
    );
    final engine = LocalTranslationEngine(client: fake);

    final out = await engine.translate(
      text: '版权信息',
      sourceLang: 'zh',
      targetLang: 'en',
      contextSources: const [],
    );

    expect(fake.lastUserText, contains('版权信息'));
    expect(fake.lastMaxInputTokens, isNotNull);
    expect(fake.lastMaxInputTokens!, greaterThan(0));
    expect(out, 'Hello world\nfoo bar');
  });
}
