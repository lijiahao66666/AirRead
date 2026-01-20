import 'dart:async';

import '../../ai/reading/qa_service.dart';
import '../../ai/reading/reading_context_service.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import 'ai_model_provider.dart';

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
  int _nextStreamId = 1;

  QaStreamState? stateFor(String bookId) => _stateByBookId[bookId];

  Future<int> start({
    required String bookId,
    required String question,
    required QAType qaType,
    required AiModelProvider aiModel,
    required ReadingContextService contextService,
    String history = '',
  }) async {
    await cancel(bookId);

    final streamId = _nextStreamId++;
    final isLocalModel = aiModel.source == AiModelSource.local;

    if (aiModel.source == AiModelSource.none) {
      _stateByBookId[bookId] = QaStreamState(
        streamId: streamId,
        bookId: bookId,
        question: question,
        qaType: qaType,
        isLocalModel: isLocalModel,
        isStreaming: false,
        answer: '',
        think: '',
        error: '请先选择本地模型或在线大模型',
      );
      notifyListeners();
      return streamId;
    }

    if (aiModel.source == AiModelSource.online &&
        !aiModel.onlineEntitlementActive) {
      _stateByBookId[bookId] = QaStreamState(
        streamId: streamId,
        bookId: bookId,
        question: question,
        qaType: qaType,
        isLocalModel: false,
        isStreaming: false,
        answer: '',
        think: '',
        error: '在线大模型需要购买时长后使用',
      );
      notifyListeners();
      return streamId;
    }

    if (isLocalModel) {
      _localRawByBookId[bookId] = '';
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

    final qaService = QAService(
      contextService: contextService,
      credentials: getEmbeddedPublicHunyuanCredentials(),
      contentScope: aiModel.qaContentScope,
    );

    final stream = qaService.askQuestion(
      question: question,
      isLocalModel: isLocalModel,
      qaType: qaType,
      history: history,
    );

    _subByBookId[bookId] = stream.listen(
      (chunk) {
        final cur = _stateByBookId[bookId];
        if (cur == null || cur.streamId != streamId) return;

        if (isLocalModel) {
          final raw = _sanitizeLocalDelta(chunk.content);
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

  String _sanitizeLocalDelta(String input) {
    if (input.isEmpty) return '';
    final buffer = StringBuffer();
    for (final r in input.runes) {
      if (r == 0x09 || r == 0x0A || r == 0x0D) {
        buffer.writeCharCode(r);
        continue;
      }
      if (r < 0x20 || r == 0x7F) continue;
      buffer.writeCharCode(r);
    }
    return buffer.toString();
  }

  String _stripModelTokens(String input) {
    var s = input;
    s = s.replaceAll(RegExp(r'<\|[^>]*\|>'), '');
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
    s = s.trim();
    return s;
  }

  String _formatError(Object e) {
    final s = e.toString();
    if (s.startsWith('Exception: ')) return s.substring('Exception: '.length);
    return s;
  }
}
