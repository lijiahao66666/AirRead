import 'dart:async';

import '../hunyuan/hunyuan_text_client.dart';
import '../local_llm/llm_client.dart';
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
          '要求：仅基于内容总结，不要编造。\n'
          '输出：先列提纲（不超过6条），再给出总结（260字以内）。';
      break;
    case QAType.keyPoints:
      final content = contextService.getContentByScope(contentScope).trim();
      prompt = '请从以下内容中提取关键要点，控制在5条以内：\n\n'
          '${content.isEmpty ? '（当前阅读内容为空）' : content}\n\n'
          '要求：仅基于内容提取，不要编造；覆盖事件、人物变化、伏笔线索。\n'
          '输出：不超过5条，每条一句话。';
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

  // MiniCPM4 模型使用特定的 chat template
  // Format: <|im_start|>system\n...<|im_end|>\n<|im_start|>user\n...<|im_end|>\n<|im_start|>assistant\n
  String userPrompt;
  switch (qaType) {
    case QAType.summary:
      userPrompt = [
        '请总结以下内容：',
        _tailText(
            _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1600),
      ].join('\n');
      break;
    case QAType.keyPoints:
      userPrompt = [
        '请提取以下内容的要点：',
        _tailText(
            _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1600),
      ].join('\n');
      break;
    case QAType.general:
      final parts = <String>[
        '基于以下内容回答问题：',
        _tailText(
            _squashSpaces(content.isEmpty ? '（当前阅读内容为空）' : content), 1200),
        '',
        '问题：$question',
      ];
      userPrompt = parts.join('\n').trim();
      break;
  }

  // 构建 MiniCPM 格式的 prompt
  final buffer = StringBuffer();
  buffer.writeln('<|im_start|>system');
  buffer.writeln('你是一个 helpful 的助手，请根据用户的问题提供简洁准确的回答。');
  buffer.writeln('<|im_end|>');
  buffer.writeln('<|im_start|>user');
  buffer.writeln(userPrompt);
  buffer.writeln('<|im_end|>');
  buffer.writeln('<|im_start|>assistant');

  return buffer.toString();
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
      model: 'hunyuan-a13b',
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
    final initialized = await client.initialize(model: 'minicpm4-0.5b-mnn');

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
      contentScope: contentScope,
      history: history,
    );

    // MNN 使用固定的上下文大小
    const maxCtx = 2048;
    final caps = _computeLocalCaps(maxCtx);

    await for (final delta in client.generateStream(
      prompt: prompt,
      maxTokens: caps.maxNewTokens,
      temperature: 0.6,
    )) {
      if (delta.isEmpty) continue;
      yield QAStreamChunk(content: delta);
    }

    await client.dispose();
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
