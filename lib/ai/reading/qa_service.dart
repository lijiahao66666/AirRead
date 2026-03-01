import 'dart:async';
import 'dart:ui'; // for TextRange

import '../hunyuan/hunyuan_text_client.dart';
import '../local_llm/llm_client.dart';
import '../tencentcloud/tencent_credentials.dart';

class ReadingContextService {
  final Map<int, String> chapterContentCache;
  final int currentChapterIndex;
  final int currentPageInChapter;
  final Map<int, List<TextRange>> chapterPageRanges;

  ReadingContextService({
    required this.chapterContentCache,
    required this.currentChapterIndex,
    required this.currentPageInChapter,
    required this.chapterPageRanges,
  });

  String getCurrentChapterContent() {
    final chapterContent = chapterContentCache[currentChapterIndex] ?? '';
    if (chapterContent.isEmpty) return '';

    // 简单清理 XML 标签等
    final cleaned = _cleanContent(chapterContent);
    return cleaned;
  }

  String _cleanContent(String content) {
    // 简单移除 HTML/XML 标签
    return content.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }
}

// QA类型枚举
enum QAType {
  general,
  summary,
  keyPoints,
}

/// QA流式输出块
class QAStreamChunk {
  final String content;
  final String? reasoningContent;
  final bool isReasoning;
  final bool isComplete;

  QAStreamChunk({
    required this.content,
    this.reasoningContent,
    this.isReasoning = false,
    this.isComplete = false,
  });
}

String buildOnlineQaPrompt({
  required ReadingContextService contextService,
  required String question,
  required QAType qaType,
  String? history,
}) {
  String prompt;

  switch (qaType) {
    case QAType.summary:
      final content = contextService.getCurrentChapterContent().trim();
      prompt = '请总结以下内容，用清晰的要点列出：\n\n'
          '${content.isEmpty ? '（当前阅读内容为空）' : content}\n\n'
          '要求：仅基于内容总结，不要编造。\n'
          '输出：先列提纲（不超过6条），再给出总结（150字以内）。';
      break;
    case QAType.keyPoints:
      final content = contextService.getCurrentChapterContent().trim();
      prompt = '请从以下内容中提取关键要点，控制在5条以内：\n\n'
          '${content.isEmpty ? '（当前阅读内容为空）' : content}\n\n'
          '要求：仅基于内容提取，不要编造；覆盖事件、人物变化、伏笔线索。\n'
          '输出：不超过5条，每条一句话。';
      break;
    case QAType.general:
      prompt = _buildGeneralQaPrompt(
        question,
        contextService,
        history: history,
      );
      break;
  }

  return prompt;
}

String _buildGeneralQaPrompt(
  String userQuestion,
  ReadingContextService contextService, {
  String? history,
}) {
  final content = contextService.getCurrentChapterContent().trim();
  final historyText = (history ?? '').trim();

  final buffer = StringBuffer()
    ..writeln('你是阅读助手。请仅基于【当前阅读内容】与【历史问答】作答。')
    ..writeln('要求：')
    ..writeln('1) 优先在内容中定位答案并直接回答。')
    ..writeln('2) 必要时引用原文短句作为依据（可简短摘录）。')
    ..writeln('3) 不要编造；只有确实找不到再说“文中未提及/需要更多上下文”。')
    ..writeln('4) 【历史问答】可能包含错误或过时信息：仅用于理解代词指代、上下文与用户偏好；一旦与【当前阅读内容】冲突，以【当前阅读内容】为准，并忽略历史中的矛盾结论。')
    ..writeln()
    ..writeln('【当前阅读内容】')
    ..writeln(content.isEmpty ? '（当前阅读内容为空）' : content)
    ..writeln();

  if (historyText.isNotEmpty) {
    buffer
      ..writeln('【历史问答（最近对话）】')
      ..writeln(historyText)
      ..writeln();
  }

  buffer
    ..writeln('【用户问题】')
    ..writeln(userQuestion)
    ..writeln()
    ..writeln('请给出清晰、准确的回答。');

  return buffer.toString().trim();
}

String buildLocalQaPrompt({
  required ReadingContextService contextService,
  required String question,
  required QAType qaType,
  String? history,
}) {
  String userPrompt;
  switch (qaType) {
    case QAType.summary:
      final content = contextService.getCurrentChapterContent();
      final cleanedContent = _tailText(
          _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1600);
      userPrompt = '请总结以下内容，用清晰的要点列出：\n\n'
          '$cleanedContent\n\n'
          '要求：仅基于内容总结，不要编造。\n'
          '输出：先列提纲（不超过6条），再给出总结（150字以内）。';
      break;
    case QAType.keyPoints:
      final content = contextService.getCurrentChapterContent();
      final cleanedContent = _tailText(
          _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1600);
      userPrompt = '请从以下内容中提取关键要点，控制在5条以内：\n\n'
          '$cleanedContent\n\n'
          '要求：仅基于内容提取，不要编造；覆盖事件、人物变化、伏笔线索。\n'
          '输出：不超过5条，每条一句话。';
      break;
    case QAType.general:
      userPrompt = _buildGeneralQaPromptLocal(
        question,
        contextService,
        history: history,
      );
      break;
  }
  return 'You are a helpful assistant.\nUse the language requested by the user. If unspecified, reply in the same language as the user.\n$userPrompt';

  // 关键修正：确保换行符是 \n 而不是 \r\n，且不要有多余的空格干扰 Native 的检测
  // return '<|im_start|>system\nYou are a helpful assistant.\nUse the language requested by the user. If unspecified, reply in the same language as the user.\n<|im_end|>\n<|im_start|>user\n$userPrompt<|im_end|>\n<|im_start|>assistant\n';
}

String _buildGeneralQaPromptLocal(
  String userQuestion,
  ReadingContextService contextService, {
  String? history,
}) {
  final contentText = _squashSpaces(contextService.getCurrentChapterContent());
  final historyText = _squashSpaces((history ?? '').trim());

  final clippedHistory = historyText.isEmpty ? '' : _tailText(historyText, 900);
  const totalBudget = 3000;
  final reservedForMeta = 400;
  final available = (totalBudget - reservedForMeta - clippedHistory.length)
      .clamp(800, 2400);
  final clippedContent = _tailText(
    contentText.isEmpty ? '（当前阅读内容为空）' : contentText,
    available,
  );

  final buffer = StringBuffer()
    ..writeln('你是阅读助手。请仅基于【当前阅读内容】与【历史问答】作答。')
    ..writeln('要求：')
    ..writeln('1) 优先在内容中定位答案并直接回答。')
    ..writeln('2) 必要时引用原文短句作为依据（可简短摘录）。')
    ..writeln('3) 不要编造；只有确实找不到再说“文中未提及/需要更多上下文”。')
    ..writeln('4) 【历史问答】可能包含错误或过时信息：仅用于理解代词指代、上下文与用户偏好；一旦与【当前阅读内容】冲突，以【当前阅读内容】为准，并忽略历史中的矛盾结论。')
    ..writeln()
    ..writeln('【当前阅读内容（已截断）】')
    ..writeln(clippedContent)
    ..writeln();

  if (clippedHistory.isNotEmpty) {
    buffer
      ..writeln('【历史问答（已截断）】')
      ..writeln(clippedHistory)
      ..writeln();
  }

  buffer
    ..writeln('【用户问题】')
    ..writeln(userQuestion)
    ..writeln()
    ..writeln('请给出清晰、准确的回答。');

  return buffer.toString().trim();
}

class QAService {
  final ReadingContextService contextService;
  final TencentCredentials credentials;
  final String localModelId;
  static const int _localQaHardMaxNewTokens = 1024;
  static const int _localQaHardMaxInputTokens = 4096;
  static const int _localQaContextReserveTokens = 512;

  QAService({
    required this.contextService,
    required this.credentials,
    this.localModelId = 'hunyuan-1.8b-mnn',
  });

  Stream<QAStreamChunk> askQuestion({
    required String question,
    required bool isLocalModel,
    QAType qaType = QAType.general,
    String? history,
  }) async* {
    if (isLocalModel) {
      yield* _askLocalModel(
        question,
        qaType,
        history: history,
      );
    } else {
      yield* _askOnlineModel(
        question,
        qaType,
        history: history,
      );
    }
  }

  Stream<QAStreamChunk> _askOnlineModel(
    String question,
    QAType qaType, {
    String? history,
  }) async* {
    final client = HunyuanTextClient(credentials: credentials);
    final prompt = buildOnlineQaPrompt(
      contextService: contextService,
      question: question,
      qaType: qaType,
      history: history,
    );

    final stream = client.chatStream(
      userText: prompt,
      model: HunyuanTextClient.instructModel,
    );

    await for (final chunk in stream) {
      yield QAStreamChunk(
        content: chunk.content,
        reasoningContent: chunk.reasoningContent,
        isReasoning: chunk.isReasoning,
        isComplete: chunk.isComplete,
      );
    }
  }

  Stream<QAStreamChunk> _askLocalModel(
    String question,
    QAType qaType, {
    String? history,
  }) async* {
    // 使用适合平台的本地 LLM 客户端
    final client = createLocalLlmClient();
    final initialized = await client.initialize(model: localModelId);

    if (!initialized) {
      yield QAStreamChunk(
        content: '本地模型初始化失败，请检查模型文件是否正确放置。',
        isComplete: true,
      );
      return;
    }

    final prompt = buildLocalQaPrompt(
      contextService: contextService,
      question: question,
      qaType: qaType,
      history: history,
    );

    // MNN 使用固定的上下文大小
    const maxCtx = 4096;
    final caps = _computeLocalCaps(maxCtx);

    await for (final delta in client.generateStream(
      prompt: prompt,
      maxTokens: caps.maxNewTokens,
    )) {
      if (delta.isEmpty) continue;
      yield QAStreamChunk(content: delta);
    }

    await client.dispose();
  }

  _LocalCaps _computeLocalCaps(int? maxContextTokens) {
    final contextSize = maxContextTokens ?? 4096;
    final usable = contextSize - _localQaContextReserveTokens;

    // 分配策略：调整为 1/2 给输出，以支持长文本生成 (如插图分析)
    // 之前是 1/3，对于 4096 窗口，输出约 1194，现在提升到约 1792
    int maxNew = (usable ~/ 2).clamp(256, _localQaHardMaxNewTokens);
    int maxInput = (usable - maxNew).clamp(256, _localQaHardMaxInputTokens);

    return _LocalCaps(maxInputTokens: maxInput, maxNewTokens: maxNew);
  }
}

String _tailText(String input, int maxChars) {
  final s = input.trim();
  if (s.length <= maxChars) return s;
  return s.substring(s.length - maxChars);
}

String _squashSpaces(String input) {
  return input.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _LocalCaps {
  final int maxInputTokens;
  final int maxNewTokens;
  _LocalCaps({required this.maxInputTokens, required this.maxNewTokens});
}
