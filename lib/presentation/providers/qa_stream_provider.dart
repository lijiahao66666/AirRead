import 'dart:async';
import 'dart:io';

import '../../ai/reading/qa_service.dart';
// import '../../ai/reading/reading_context_service.dart';
import '../../ai/config/auth_service.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/tencentcloud/tencent_cloud_exception.dart';
import 'ai_model_provider.dart';
import '../models/ai_chat_model_choice.dart';
import '../../ai/hunyuan/hunyuan_text_client.dart';
import '../../ai/local_llm/model_manager.dart';

import 'package:flutter/foundation.dart';

class QaStreamState {
  final int streamId;
  final String bookId;
  final String question;
  final QAType qaType;
  final bool isLocalModel;
  final bool isStreaming;
  final String answer;
  final String think;
  final String error;

  const QaStreamState({
    required this.streamId,
    required this.bookId,
    required this.question,
    required this.qaType,
    required this.isLocalModel,
    required this.isStreaming,
    required this.answer,
    required this.think,
    required this.error,
  });

  bool get hasError => error.trim().isNotEmpty;
}

class QaStreamProvider extends ChangeNotifier {
  final Map<String, QaStreamState> _stateByBookId = {};
  final Map<String, StreamSubscription<QAStreamChunk>> _subByBookId = {};
  final Map<String, String> _localRawByBookId = {};
  final Map<String, String> _localModelIdByBookId = {};
  int _nextStreamId = 1;

  QaStreamState? stateFor(String bookId) => _stateByBookId[bookId];

  Future<void> _consumeDebugPoints(AiModelProvider aiModel, int cost) async {
    if (!kDebugMode) return;
    if (cost <= 0) return;
    final override = aiModel.debugPointsOverride;
    if (override == null) return;
    final next = override - cost;
    await aiModel.setDebugPointsOverride(next);
  }

  Future<int> start({
    required String bookId,
    required String question,
    required QAType qaType,
    required AiModelProvider aiModel,
    required ReadingContextService contextService,
    required AiChatModelChoice modelChoice,
    required bool thinkingEnabled,
    String history = '',
  }) async {
    await cancel(bookId);

    final streamId = _nextStreamId++;
    final isLocalModel = modelChoice.isLocal;
    final localModelId = switch (modelChoice) {
      AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
      AiChatModelChoice.localMiniCpm05b => ModelManager.minicpm4_0_5b,
      AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
      _ => ModelManager.hunyuan_1_8b,
    };

    if (modelChoice.isOnline &&
        usingPersonalTencentKeys() &&
        !getEmbeddedPublicHunyuanCredentials().isUsable) {
      _stateByBookId[bookId] = QaStreamState(
        streamId: streamId,
        bookId: bookId,
        question: question,
        qaType: qaType,
        isLocalModel: false,
        isStreaming: false,
        answer: '',
        think: '',
        error: '已开启使用个人密钥，但未正确设置个人密钥',
      );
      notifyListeners();
      return streamId;
    }

    // TODO: SMS配好后取消注释，强制登录
    // if (modelChoice.isOnline &&
    //     !usingPersonalTencentKeys() &&
    //     !AuthService.isLoggedIn) {
    //   _stateByBookId[bookId] = QaStreamState(
    //     streamId: streamId,
    //     bookId: bookId,
    //     question: question,
    //     qaType: qaType,
    //     isLocalModel: false,
    //     isStreaming: false,
    //     answer: '',
    //     think: '',
    //     error: '请先登录后使用在线问答',
    //   );
    //   notifyListeners();
    //   return streamId;
    // }

    if (modelChoice.isOnline &&
        !usingPersonalTencentKeys() &&
        aiModel.pointsBalance <= 0) {
      _stateByBookId[bookId] = QaStreamState(
        streamId: streamId,
        bookId: bookId,
        question: question,
        qaType: qaType,
        isLocalModel: false,
        isStreaming: false,
        answer: '',
        think: '',
        error: '问答需要购买积分后使用',
      );
      notifyListeners();
      return streamId;
    }

    if (modelChoice.isOnline && !usingPersonalTencentKeys()) {
      final cost = question.trim().length;
      unawaited(_consumeDebugPoints(aiModel, cost));
    }

    if (isLocalModel) {
      _localRawByBookId[bookId] = '';
      _localModelIdByBookId[bookId] = localModelId;
    }

    _stateByBookId[bookId] = QaStreamState(
      streamId: streamId,
      bookId: bookId,
      question: question,
      qaType: qaType,
      isLocalModel: isLocalModel,
      isStreaming: true,
      answer: '',
      think: '',
      error: '',
    );
    notifyListeners();

    Stream<QAStreamChunk> stream;
    if (isLocalModel) {
      final thinkingSupported =
          modelChoice != AiChatModelChoice.localMiniCpm05b;
      final effectiveThinkingEnabled =
          thinkingSupported ? thinkingEnabled : false;
      final basePrompt = buildLocalQaPrompt(
        contextService: contextService,
        question: question,
        qaType: qaType,
        history: history,
      );
      final prompt = effectiveThinkingEnabled
          ? basePrompt
          : (thinkingSupported ? '/no_think\n$basePrompt' : basePrompt);
      stream = aiModel
          .generateStream(
            prompt: prompt,
            maxTokens: 1024,
            modelId: localModelId,
          )
          .map((e) => QAStreamChunk(content: e));
    } else {
      final prompt = buildOnlineQaPrompt(
        contextService: contextService,
        question: question,
        qaType: qaType,
        history: history,
      );
      final client =
          HunyuanTextClient(credentials: getEmbeddedPublicHunyuanCredentials());
      stream = client
          .chatStream(
            userText: prompt,
            model: 'hunyuan-a13b',
            enableThinking: thinkingEnabled ? null : false,
          )
          .map(
            (c) => QAStreamChunk(
              content: c.content,
              reasoningContent: c.reasoningContent,
              isReasoning: c.isReasoning,
              isComplete: c.isComplete,
            ),
          );
    }

    _subByBookId[bookId] = stream.listen(
      (chunk) {
        final cur = _stateByBookId[bookId];
        if (cur == null || cur.streamId != streamId) return;

        if (isLocalModel) {
          final raw = _sanitizeLocalDelta(
            chunk.content,
            localModelId: _localModelIdByBookId[bookId],
          );
          if (raw.isNotEmpty) {
            var acc = (_localRawByBookId[bookId] ?? '') + raw;
            if (acc.length > 30000) {
              acc = acc.substring(acc.length - 30000);
            }
            _localRawByBookId[bookId] = acc;
          }

          final rawAll = _localRawByBookId[bookId] ?? '';
          final think = _extractThink(rawAll);
          final answer = _extractAnswer(rawAll);
          _stateByBookId[bookId] = QaStreamState(
            streamId: cur.streamId,
            bookId: cur.bookId,
            question: cur.question,
            qaType: cur.qaType,
            isLocalModel: cur.isLocalModel,
            isStreaming: true,
            answer: answer,
            think: think,
            error: '',
          );
          notifyListeners();
          return;
        }

        final nextThink = (chunk.reasoningContent ?? '').isEmpty
            ? cur.think
            : (cur.think + (chunk.reasoningContent ?? ''));
        final nextAnswer =
            chunk.content.isEmpty ? cur.answer : (cur.answer + chunk.content);
        _stateByBookId[bookId] = QaStreamState(
          streamId: cur.streamId,
          bookId: cur.bookId,
          question: cur.question,
          qaType: cur.qaType,
          isLocalModel: cur.isLocalModel,
          isStreaming: true,
          answer: nextAnswer,
          think: nextThink,
          error: '',
        );
        notifyListeners();
      },
      onError: (e) {
        final cur = _stateByBookId[bookId];
        if (cur == null || cur.streamId != streamId) return;
        _stateByBookId[bookId] = QaStreamState(
          streamId: cur.streamId,
          bookId: cur.bookId,
          question: cur.question,
          qaType: cur.qaType,
          isLocalModel: cur.isLocalModel,
          isStreaming: false,
          answer: cur.answer,
          think: cur.think,
          error: _formatError(e),
        );
        notifyListeners();
      },
      onDone: () {
        final cur = _stateByBookId[bookId];
        if (cur == null || cur.streamId != streamId) return;
        if (cur.isLocalModel) {
          final rawAll = _localRawByBookId[bookId] ?? '';
          var think = _extractThink(rawAll);
          var answer = _extractAnswer(rawAll);
          if (answer.trim().isEmpty && think.trim().isNotEmpty) {
            answer = think;
            think = '';
          }
          _localModelIdByBookId.remove(bookId);
          _stateByBookId[bookId] = QaStreamState(
            streamId: cur.streamId,
            bookId: cur.bookId,
            question: cur.question,
            qaType: cur.qaType,
            isLocalModel: cur.isLocalModel,
            isStreaming: false,
            answer: answer,
            think: think,
            error: '',
          );
          notifyListeners();
          return;
        }
        _stateByBookId[bookId] = QaStreamState(
          streamId: cur.streamId,
          bookId: cur.bookId,
          question: cur.question,
          qaType: cur.qaType,
          isLocalModel: cur.isLocalModel,
          isStreaming: false,
          answer: cur.answer,
          think: cur.think,
          error: '',
        );
        notifyListeners();
      },
      cancelOnError: true,
    );

    return streamId;
  }

  Future<void> cancel(String bookId) async {
    final sub = _subByBookId.remove(bookId);
    if (sub != null) {
      await sub.cancel().catchError((_) {});
    }
    _localRawByBookId.remove(bookId);
    _localModelIdByBookId.remove(bookId);
    final cur = _stateByBookId[bookId];
    if (cur != null && cur.isStreaming) {
      _stateByBookId[bookId] = QaStreamState(
        streamId: cur.streamId,
        bookId: cur.bookId,
        question: cur.question,
        qaType: cur.qaType,
        isLocalModel: cur.isLocalModel,
        isStreaming: false,
        answer: cur.answer,
        think: cur.think,
        error: cur.error,
      );
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final sub in _subByBookId.values) {
      sub.cancel().catchError((_) {});
    }
    _subByBookId.clear();
    super.dispose();
  }

  String _sanitizeLocalDelta(
    String input, {
    String? localModelId,
  }) {
    if (input.isEmpty) return '';
    final tightenForMiniCpmIos =
        Platform.isIOS && localModelId == ModelManager.minicpm4_0_5b;
    final buffer = StringBuffer();
    for (final r in input.runes) {
      if (r == 0x09 || r == 0x0A || r == 0x0D) {
        buffer.writeCharCode(r);
        continue;
      }
      if (r < 0x20 || r == 0x7F) continue;
      if (tightenForMiniCpmIos) {
        if ((r >= 0x0300 && r <= 0x036F) ||
            r == 0x200B ||
            r == 0x200C ||
            r == 0x200D ||
            r == 0x200E ||
            r == 0x200F ||
            (r >= 0x202A && r <= 0x202E) ||
            (r >= 0x2066 && r <= 0x2069) ||
            r == 0xFEFF) {
          continue;
        }
      }
      buffer.writeCharCode(r);
    }
    return buffer.toString();
  }

  String _stripModelTokens(String input) {
    var s = input;
    s = s.replaceAll(RegExp(r'<\|[^>]*\|>'), '');
    s = s.replaceAll(RegExp(r'(^|\n)\s*/no_think\s*(?=\n|$)'), '\n');
    return s;
  }

  String _extractThink(String raw) {
    final s = _stripModelTokens(raw);
    if (s.trim().isEmpty) return '';
    final matches = RegExp(r'<think>([\s\S]*?)</think>').allMatches(s);
    final out = <String>[];
    for (final m in matches) {
      final g = m.group(1) ?? '';
      final t = g.trim();
      if (t.isNotEmpty) out.add(t);
    }

    const open = '<think>';
    const close = '</think>';
    final lastOpen = s.lastIndexOf(open);
    if (lastOpen >= 0) {
      final after = lastOpen + open.length;
      final end = s.indexOf(close, after);
      if (end < 0 && after <= s.length) {
        var chunk = s.substring(after);
        final answerOpen = chunk.indexOf('<answer>');
        if (answerOpen >= 0) {
          chunk = chunk.substring(0, answerOpen);
        }
        final t = chunk.trim();
        if (t.isNotEmpty) out.add(t);
      }
    }

    return out.join('\n').trim();
  }

  String _extractAnswer(String raw) {
    var s = _stripModelTokens(raw).trim();
    if (s.isEmpty) return '';

    const thinkOpen = '<think>';
    const thinkClose = '</think>';
    final lastThinkOpen = s.lastIndexOf(thinkOpen);
    final lastThinkClose = s.lastIndexOf(thinkClose);
    if (lastThinkOpen >= 0 && lastThinkOpen > lastThinkClose) {
      final ansOpen = s.lastIndexOf('<answer>');
      if (ansOpen >= 0 && ansOpen > lastThinkOpen) {
        final after = ansOpen + '<answer>'.length;
        return _cleanupAnswer(s.substring(after));
      }
      return '';
    }

    const open = '<answer>';
    const close = '</answer>';
    final lastOpen = s.lastIndexOf(open);
    if (lastOpen >= 0) {
      final after = lastOpen + open.length;
      final end = s.indexOf(close, after);
      final ans = end >= 0 ? s.substring(after, end) : s.substring(after);
      return _cleanupAnswer(ans);
    }

    final lastThinkClose2 = s.lastIndexOf(thinkClose);
    if (lastThinkClose2 >= 0) {
      final after = lastThinkClose2 + thinkClose.length;
      return _cleanupAnswer(s.substring(after));
    }

    s = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>', multiLine: true), '');
    final danglingThink = s.indexOf('<think>');
    if (danglingThink >= 0) {
      s = s.substring(0, danglingThink);
    }
    return _cleanupAnswer(s);
  }

  String _cleanupAnswer(String input) {
    var s = input;
    s = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>', multiLine: true), '');
    s = s.replaceAll('<think>', '').replaceAll('</think>', '');
    s = s.replaceAll('<answer>', '').replaceAll('</answer>', '');
    s = s.replaceAll(RegExp(r'</?\[[^\]]+\]>'), '');
    s = s.replaceAll(RegExp(r'(^|\n)\s*/no_think\s*(?=\n|$)'), '\n');
    s = s.trim();
    return s;
  }

  String _formatError(Object e) {
    if (e is TencentCloudException) {
      if (e.code == 'PointsInsufficient') return '积分不足，请购买积分后再试';
      if (e.code == 'HttpError') {
        final m = e.message;
        if (m.contains('HTTP 402') ||
            m.contains('PointsInsufficient') ||
            m.contains('积分不足')) {
          return '积分不足，请购买积分后再试';
        }
        if (m.contains('HTTP 401') || m.contains('HTTP 403')) {
          return '鉴权失败，请检查积分状态或个人密钥是否正确';
        }
        if (m.contains('HTTP 429')) {
          return '请求过于频繁，请稍后重试';
        }
        return '在线服务异常，请稍后重试';
      }
      if (e.message.contains('积分不足') ||
          e.message.contains('PointsInsufficient')) {
        return '积分不足，请购买积分后再试';
      }
      return e.toString();
    }

    final s = e.toString();
    if (s.contains('PointsInsufficient') ||
        s.contains('HTTP 402') ||
        s.contains('积分不足')) {
      return '积分不足，请购买积分后再试';
    }
    if (s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('XMLHttpRequest error')) {
      return '网络连接失败，请检查网络后重试';
    }
    if (s.startsWith('Exception: ')) return s.substring('Exception: '.length);
    return s;
  }
}
