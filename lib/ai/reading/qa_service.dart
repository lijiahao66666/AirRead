import 'dart:async';

import '../hunyuan/hunyuan_text_client.dart';
import '../local_llm/local_llm_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import '../../presentation/providers/ai_model_provider.dart';
import 'reading_context_service.dart';

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
  required QAContentScope contentScope,
  String? history,
}) {
  String prompt;

  switch (qaType) {
    case QAType.summary:
      final content = contextService.getContentByScope(contentScope).trim();
      prompt = '请总结以下内容，用清晰的要点列出：\n\n'
          '${content.isEmpty ? '（当前阅读内容为空）' : content}\n\n'
          '请从以下方面进行总结：\n'
          '1. 核心情节发展\n'
          '2. 关键人物及其行为动机\n'
          '3. 重要的伏笔和线索\n'
          '4. 情感氛围和主题思想\n\n'
          '请用简洁、条理清晰的方式输出。';
      break;
    case QAType.keyPoints:
      final content = contextService.getContentByScope(contentScope).trim();
      prompt = '请从以下内容中提取关键要点，控制在5条以内：\n\n'
          '${content.isEmpty ? '（当前阅读内容为空）' : content}\n\n'
          '关键要点应包括：\n'
          '- 核心事件\n'
          '- 人物关系变化\n'
          '- 重要细节和伏笔\n'
          '- 情节转折点\n\n'
          '每条要点请用一句话概括。';
      break;
    case QAType.general:
      prompt = contextService.generateQAPrompt(
        question,
        contentScope,
        history: history,
      );
      break;
  }

  return prompt;
}

String buildLocalQaPrompt({
  required ReadingContextService contextService,
  required String question,
  required QAType qaType,
  required QAContentScope contentScope,
  String? history,
}) {
  final historyText = (history ?? '').trim();
  final content = contextService.getContentByScope(contentScope);

  switch (qaType) {
    case QAType.summary:
      return [
        '你是阅读助手。请对以下内容做简要总结，避免重复表述：',
        _tailText(
            _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1600),
        '',
        '要求：列出提纲（不超过6条），然后给出总结（260字以内）。',
      ].join('\n');
    case QAType.keyPoints:
      return [
        '你是阅读助手。请从以下内容提取关键要点，避免重复表述：',
        _tailText(
            _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1600),
        '',
        '要求：筛选关键要点（不超过5条），每条一句话，覆盖事件、人物变化、伏笔线索。',
      ].join('\n');
    case QAType.general:
      final parts = <String>[
        '你是阅读助手。请根据「当前阅读内容」回答「用户问题」。',
        '规则：参考内容与历史对话；不确定就说“文中未提及/需要更多上下文”；避免重复输出相同句子。',
        '',
        '【当前阅读内容】',
        _tailText(
            _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1200),
      ];
      if (historyText.isNotEmpty) {
        parts.addAll([
          '',
          '【历史问答】',
          _tailText(_squashSpaces(historyText), 400),
        ]);
      }
      parts.addAll([
        '',
        '【用户问题】',
        _clipText(_squashSpaces(question), 200),
        '',
        '请直接给出回答：',
      ]);
      return parts.join('\n').trim();
  }
}

class QAService {
  final ReadingContextService contextService;
  final TencentCredentials credentials;
  final QAContentScope contentScope;
  static const int _localQaMaxNewTokens = 1024;
  static const int _localQaMaxInputTokens = 4096;
  static const int _localQaHardMaxNewTokens = 1536;
  static const int _localQaHardMaxInputTokens = 6144;
  static const int _localQaContextReserveTokens = 512;

  QAService({
    required this.contextService,
    required this.credentials,
    this.contentScope = QAContentScope.slidingWindow,
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
      contentScope: contentScope,
      history: history,
    );

    final stream = client.chatStream(
      userText: prompt,
      model: 'hunyuan-2.0-thinking-20251109',
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
    final client = LocalLlmClient(modelType: LocalLlmModelType.qa);
    final prompt = buildLocalQaPrompt(
      contextService: contextService,
      question: question,
      qaType: qaType,
      contentScope: contentScope,
      history: history,
    );

    final maxCtx = await client.getMaxContextTokens();
    final caps = _computeLocalCaps(maxCtx);

    await for (final delta in client.chatStream(
      userText: prompt,
      maxNewTokens: caps.maxNewTokens,
      maxInputTokens: caps.maxInputTokens,
      temperature: 0.6,
      topP: 0.95,
      topK: 20,
      minP: 0,
      presencePenalty: 1.5,
      enableThinking: true,
    )) {
      if (delta.isEmpty) continue;
      yield QAStreamChunk(content: delta);
    }
  }

  _LocalCaps _computeLocalCaps(int? maxContextTokens) {
    var maxInput = _localQaMaxInputTokens;
    var maxNew = _localQaMaxNewTokens;

    if (maxInput > _localQaHardMaxInputTokens) {
      maxInput = _localQaHardMaxInputTokens;
    }
    if (maxNew > _localQaHardMaxNewTokens) {
      maxNew = _localQaHardMaxNewTokens;
    }

    if (maxContextTokens != null && maxContextTokens > 0) {
      final usable = maxContextTokens - _localQaContextReserveTokens;
      if (usable > 0) {
        if (maxNew > usable ~/ 3) {
          maxNew = usable ~/ 3;
        }
        if (maxNew < 192) maxNew = 192;

        final canUseForInput = usable - maxNew;
        if (canUseForInput > 0) {
          if (maxInput > canUseForInput) {
            maxInput = canUseForInput;
          }
        } else {
          maxInput = 512;
          if (maxInput > usable) {
            maxInput = usable;
          }
          maxNew = usable - maxInput;
          if (maxNew < 64) maxNew = 64;
        }
      } else {
        maxInput = 256;
        maxNew = 64;
      }
    } else {
      const usable = 4096 - _localQaContextReserveTokens;
      if (usable > 0) {
        if (maxNew > usable ~/ 3) maxNew = usable ~/ 3;
        if (maxNew < 192) maxNew = 192;
        final canUseForInput = usable - maxNew;
        if (canUseForInput > 0 && maxInput > canUseForInput) {
          maxInput = canUseForInput;
        }
      }
    }

    if (maxInput > _localQaHardMaxInputTokens) {
      maxInput = _localQaHardMaxInputTokens;
    }
    if (maxNew > _localQaHardMaxNewTokens) maxNew = _localQaHardMaxNewTokens;
    if (maxNew < 64) maxNew = 64;
    if (maxInput < 256) maxInput = 256;

    return _LocalCaps(maxInputTokens: maxInput, maxNewTokens: maxNew);
  }
}

String _clipText(String input, int maxChars) {
  final s = input.trim();
  if (s.length <= maxChars) return s;
  return s.substring(0, maxChars);
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
