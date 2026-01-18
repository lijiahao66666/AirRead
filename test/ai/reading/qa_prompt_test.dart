import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:airread/ai/reading/qa_service.dart';
import 'package:airread/ai/reading/reading_context_service.dart';
import 'package:airread/presentation/providers/ai_model_provider.dart';

ReadingContextService _ctx(String chapterText) {
  return ReadingContextService(
    chapterContentCache: {0: chapterText},
    currentChapterIndex: 0,
    currentPageInChapter: 0,
    chapterPageRanges: {
      0: [
        TextRange(start: 0, end: chapterText.length),
      ],
    },
  );
}

void main() {
  test('buildOnlineQaPrompt uses reading context prompt', () {
    final ctx = _ctx('第一章内容');

    final p1 = buildOnlineQaPrompt(
      contextService: ctx,
      question: '问：发生了什么？',
      qaType: QAType.general,
      contentScope: QAContentScope.currentPage,
      history: '',
    );
    expect(p1.contains('你是用户的阅读助手。请结合当前阅读内容与历史问答上下文作答。'), true);
    expect(p1.contains('1) 参考当前阅读内容。'), true);
  });

  test('buildLocalQaPrompt outputs simple instructions', () {
    final ctx = _ctx('第二章内容');

    final p1 = buildLocalQaPrompt(
      contextService: ctx,
      question: '问：这段在说什么？',
      qaType: QAType.general,
      contentScope: QAContentScope.currentPage,
      history: '',
    );
    // Should not enforce tags in the prompt
    expect(p1.contains('<think>'), false);
    expect(p1.contains('<answer>'), false);
    expect(p1.contains('你是阅读助手'), true);
    expect(p1.contains('【当前阅读内容】'), true);
  });
}
