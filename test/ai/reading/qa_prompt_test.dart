import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:airread/ai/reading/qa_service.dart';

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
      history: '',
    );
    expect(p1.contains('你是阅读助手。请仅基于【当前阅读内容】与【历史问答】作答。'), true);
    expect(p1.contains('1) 优先在内容中定位答案并直接回答。'), true);
  });

  test('buildLocalQaPrompt outputs simple instructions', () {
    final ctx = _ctx('第二章内容');

    final p1 = buildLocalQaPrompt(
      contextService: ctx,
      question: '问：这段在说什么？',
      qaType: QAType.general,
      history: '',
    );
    expect(p1.contains('/think'), false);
    expect(p1.contains('你是阅读助手'), true);
    expect(p1.contains('【当前阅读内容】'), true);
  });
}
