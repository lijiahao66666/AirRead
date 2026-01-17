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
  static const int _localQaMaxNewTokens = 1024;
  static const int _localQaMaxInputTokens = 3072;

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
      enableSearch: true, // 启用联网搜索
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
    final client = LocalLlmClient();
    final prompt = _buildLocalPrompt(
      question: question,
      qaType: qaType,
      history: history,
    );

    final parser = _ThinkTagStreamParser();
    await for (final delta in client.chatStream(
      userText: prompt,
      maxNewTokens: _localQaMaxNewTokens,
      maxInputTokens: _localQaMaxInputTokens,
    )) {
      for (final chunk in parser.consume(delta)) {
        yield chunk;
      }
    }

    for (final chunk in parser.finish()) {
      yield chunk;
    }
  }

  String _buildLocalPrompt({
    required String question,
    required QAType qaType,
    String? history,
  }) {
    final historyText = (history ?? '').trim();
    final content = contextService.getContentByScope(contentScope);
    const thinkRule =
        '请先在 <think>...</think> 中输出思考过程（尽量精简，控制在120字以内），然后在 <answer>...</answer> 中输出最终回答。';

    switch (qaType) {
      case QAType.summary:
        final chapter = contextService.getCurrentChapterContent();
        return [
          thinkRule,
          '',
          '你是阅读助手。请对以下内容做简要总结：',
          _tail(_squashSpaces(chapter), 2400),
          '',
          '要求：用不超过6条要点概括，尽量引用原文信息，不要编造；最终回答控制在260字以内。',
        ].join('\n');
      case QAType.keyPoints:
        final chapter = contextService.getCurrentChapterContent();
        return [
          thinkRule,
          '',
          '你是阅读助手。请从以下内容提取关键要点：',
          _tail(_squashSpaces(chapter), 2400),
          '',
          '要求：不超过5条；每条一句话；覆盖事件、人物变化、伏笔线索；最终回答控制在240字以内。',
        ].join('\n');
      case QAType.general:
        final parts = <String>[
          thinkRule,
          '',
          '你是阅读助手。请根据「当前阅读内容」回答「用户问题」。',
          '规则：只依据内容与历史对话；不确定就说“文中未提及/需要更多上下文”。',
          '要求：最终回答控制在600字以内，语句完整结束。',
          '',
          '【当前阅读内容】',
          _tail(_squashSpaces(content), 1800),
        ];
        if (historyText.isNotEmpty) {
          parts.addAll([
            '',
            '【历史问答】',
            _tail(_squashSpaces(historyText), 600),
          ]);
        }
        parts.addAll([
          '',
          '【用户问题】',
          _clip(_squashSpaces(question), 200),
          '',
          '请直接给出回答：',
        ]);
        return parts.join('\n').trim();
      case QAType.explain:
        return [
          thinkRule,
          '',
          '你是阅读助手。请解释「选中内容」在「上下文」中的意思。',
          '',
          '【选中内容】',
          _clip(_squashSpaces(question), 400),
          '',
          '【上下文】',
          _tail(_squashSpaces(content), 1500),
          '',
          '要求：先解释字面意思，再说明与情节的关系。控制在8句以内；最终回答控制在520字以内。',
        ].join('\n').trim();
    }
  }

  String _clip(String input, int maxChars) {
    final s = input.trim();
    if (s.length <= maxChars) return s;
    return s.substring(0, maxChars);
  }

  String _tail(String input, int maxChars) {
    final s = input.trim();
    if (s.length <= maxChars) return s;
    return s.substring(s.length - maxChars);
  }

  String _squashSpaces(String input) {
    return input.replaceAll(RegExp(r'\\s+'), ' ').trim();
  }
}

class _ThinkTagStreamParser {
  static const _open = '<think>';
  static const _close = '</think>';
  static const _answerOpen = '<answer>';
  static const _answerClose = '</answer>';
  static final RegExp _bracketTag = RegExp(r'</?\[[^\]]+\]>');

  final StringBuffer _buffer = StringBuffer();
  bool _inThink = false;
  bool _inAnswer = false;
  bool _sawAnswerTag = false;

  static String _clean(String input) {
    if (input.isEmpty) return input;
    return input.replaceAll(_bracketTag, '');
  }

  Iterable<QAStreamChunk> consume(String delta) sync* {
    if (delta.isEmpty) return;
    _buffer.write(delta);
    yield* _drain(force: false);
  }

  Iterable<QAStreamChunk> finish() sync* {
    yield* _drain(force: true);
  }

  Iterable<QAStreamChunk> _drain({required bool force}) sync* {
    var text = _buffer.toString();
    _buffer.clear();

    while (text.isNotEmpty) {
      if (_inThink) {
        final idx = text.indexOf(_close);
        if (idx >= 0) {
          final part = _clean(text.substring(0, idx));
          if (part.isNotEmpty) {
            yield QAStreamChunk(
              content: '',
              reasoningContent: part,
              isReasoning: true,
            );
          }
          text = text.substring(idx + _close.length);
          _inThink = false;
          continue;
        }

        const keep = _close.length - 1;
        if (!force && text.length > keep) {
          final emit = _clean(text.substring(0, text.length - keep));
          if (emit.isNotEmpty) {
            yield QAStreamChunk(
              content: '',
              reasoningContent: emit,
              isReasoning: true,
            );
          }
          text = text.substring(text.length - keep);
        }
        break;
      } else {
        if (_inAnswer) {
          final closeIdx = text.indexOf(_answerClose);
          if (closeIdx >= 0) {
            final part = _clean(text.substring(0, closeIdx));
            if (part.isNotEmpty) {
              yield QAStreamChunk(content: part);
            }
            text = text.substring(closeIdx + _answerClose.length);
            _inAnswer = false;
            continue;
          }

          const keep = _answerClose.length - 1;
          if (!force && text.length > keep) {
            final emit = _clean(text.substring(0, text.length - keep));
            if (emit.isNotEmpty) {
              yield QAStreamChunk(content: emit);
            }
            text = text.substring(text.length - keep);
          }
          break;
        }

        final answerIdx = text.indexOf(_answerOpen);
        if (answerIdx >= 0) {
          text = text.substring(answerIdx + _answerOpen.length);
          _inAnswer = true;
          _sawAnswerTag = true;
          continue;
        }

        final idx = text.indexOf(_open);
        if (idx >= 0) {
          final part = _clean(text.substring(0, idx));
          if (part.isNotEmpty && !_sawAnswerTag) {
            yield QAStreamChunk(content: part);
          }
          text = text.substring(idx + _open.length);
          _inThink = true;
          continue;
        }

        const keep = _open.length - 1;
        if (!force && text.length > keep) {
          final emit = _clean(text.substring(0, text.length - keep));
          if (emit.isNotEmpty && !_sawAnswerTag) {
            yield QAStreamChunk(content: emit);
          }
          text = text.substring(text.length - keep);
        }
        break;
      }
    }

    if (force && text.isNotEmpty) {
      if (_inThink) {
        text = _clean(text);
        yield QAStreamChunk(
          content: '',
          reasoningContent: text,
          isReasoning: true,
        );
      } else {
        if (!_sawAnswerTag || _inAnswer) {
          final out = _clean(text);
          if (out.isNotEmpty) {
            yield QAStreamChunk(content: out);
          }
        }
      }
      text = '';
    }

    if (text.isNotEmpty) {
      _buffer.write(text);
    }
  }
}
