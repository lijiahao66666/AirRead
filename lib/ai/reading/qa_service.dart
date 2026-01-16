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
  explain,
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



class QAService {
  final ReadingContextService contextService;
  final TencentCredentials credentials;
  final QAContentScope contentScope;

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
      yield* _askLocalModel(question, qaType, history: history);
    } else {
      yield* _askOnlineModel(question, qaType, history: history);
    }
  }

  Stream<QAStreamChunk> _askOnlineModel(
    String question,
    QAType qaType, {
    String? history,
  }) async* {
    final client = HunyuanTextClient(credentials: credentials);
    String prompt;

    switch (qaType) {
      case QAType.summary:
        prompt = contextService.generateSummaryPrompt();
        break;
      case QAType.keyPoints:
        prompt = contextService.generateKeyPointsPrompt();
        break;
      case QAType.general:
        prompt = contextService.generateQAPrompt(
          question,
          contentScope,
          history: history,
        );
        break;
      case QAType.explain:
        prompt = contextService.generateExplainPrompt(question, contentScope);
        break;
    }


    // 所有在线模型调用都启用联网搜索增强
    final stream = client.chatStream(
      userText: prompt,
      enableSearch: true,  // 启用联网搜索
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
    // 本地模型暂时不支持流式输出，模拟流式
    final client = LocalLlmClient();
    String prompt;

    switch (qaType) {
      case QAType.summary:
        prompt = contextService.generateSummaryPrompt();
        break;
      case QAType.keyPoints:
        prompt = contextService.generateKeyPointsPrompt();
        break;
      case QAType.general:
        prompt = contextService.generateQAPrompt(
          question,
          contentScope,
          history: history,
        );
        break;
      case QAType.explain:
        prompt = contextService.generateExplainPrompt(question, contentScope);
        break;
    }


    final response = await client.chatOnce(userText: prompt);
    
    // 模拟流式输出，按句子分割
    final sentences = response.split(RegExp(r'[。！？]'));
    for (final sentence in sentences) {
      if (sentence.trim().isNotEmpty) {
        yield QAStreamChunk(
          content: sentence.trim() + '。',
          isReasoning: false,
          isComplete: false,
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}
