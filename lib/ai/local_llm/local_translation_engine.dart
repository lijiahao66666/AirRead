import 'dart:async';

import '../translation/engines/translation_engine.dart';
import 'local_llm_client.dart';

class LocalTranslationEngine extends TranslationEngine {
  final LocalLlmClient _client;

  LocalTranslationEngine({LocalLlmClient? client})
      : _client =
            client ?? LocalLlmClient(modelType: LocalLlmModelType.translation);

  static const int _mtHardMaxNewTokens = 512;
  static const int _mtHardMinNewTokens = 64;
  static const bool _debug =
      bool.fromEnvironment('AIRREAD_LOCAL_MT_DEBUG', defaultValue: false);

  @override
  String get id => 'local_hunyuan_mt_v3';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) {
    final prompt = _buildPrompt(
      text: text,
      sourceLang: sourceLang,
      targetLang: targetLang,
      contextSources: contextSources,
    );
    final maxNewTokens = _estimateMaxNewTokens(
      inputText: text,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
    return _chatStreamOnce(prompt, maxNewTokens: maxNewTokens).then(
      (raw) => _postProcessModelOutput(
        raw,
        sourceText: text,
        sourceLang: sourceLang,
        targetLang: targetLang,
      ),
    );
  }

  int _estimateMaxNewTokens({
    required String inputText,
    required String sourceLang,
    required String targetLang,
  }) {
    final s = inputText.trim();
    if (s.isEmpty) return 0;

    var tokens = (s.length / 2).ceil() + 32;
    if (sourceLang.toLowerCase().contains('zh') ||
        targetLang.toLowerCase().contains('zh')) {
      tokens = (s.length / 1.5).ceil() + 32;
    }
    if (tokens > _mtHardMaxNewTokens) tokens = _mtHardMaxNewTokens;
    if (tokens < _mtHardMinNewTokens) tokens = _mtHardMinNewTokens;
    return tokens;
  }

  Future<String> _chatStreamOnce(
    String prompt, {
    required int maxNewTokens,
  }) async {
    final caps = await _computeCaps(maxNewTokens: maxNewTokens);
    final stream = _client.chatStream(
      userText: prompt,
      maxNewTokens: caps.maxNewTokens,
      maxInputTokens: caps.maxInputTokens,
      temperature: 0.2,
      topP: 0.9,
      topK: 50,
      repetitionPenalty: 1.02,
      enableThinking: false,
    );

    final buffer = StringBuffer();
    final completer = Completer<String>();
    late final StreamSubscription<String> sub;

    bool gotAnyChunk = false;

    final firstChunkTimer = Timer(const Duration(seconds: 12), () async {
      try {
        await sub.cancel();
      } catch (_) {}
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('local translation first chunk timeout'),
        );
      }
    });

    final totalTimer = Timer(const Duration(seconds: 55), () async {
      try {
        await sub.cancel();
      } catch (_) {}
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('local translation stream timeout'),
        );
      }
    });

    sub = stream.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        if (!gotAnyChunk) {
          gotAnyChunk = true;
          firstChunkTimer.cancel();
        }
        buffer.write(chunk);
      },
      onError: (e, st) {
        firstChunkTimer.cancel();
        totalTimer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      },
      onDone: () {
        firstChunkTimer.cancel();
        totalTimer.cancel();
        if (!completer.isCompleted) {
          completer.complete(buffer.toString());
        }
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  Future<_LocalMtCaps> _computeCaps({required int maxNewTokens}) async {
    const reserve = 256;
    const defaultMaxContext = 4096;
    const hardMaxInputTokens = 3072;

    final ctx = (await _client.getMaxContextTokens()) ?? defaultMaxContext;
    final usable = ctx - reserve;

    var newTok = maxNewTokens <= 0 ? 256 : maxNewTokens;
    if (newTok > _mtHardMaxNewTokens) newTok = _mtHardMaxNewTokens;
    if (newTok < _mtHardMinNewTokens) newTok = _mtHardMinNewTokens;

    if (usable <= 0) {
      return _LocalMtCaps(
        maxInputTokens: 512,
        maxNewTokens: newTok,
      );
    }

    if (usable < 320) {
      final inputTok = (usable * 0.7).floor().clamp(64, usable);
      final newTok2 = (usable - inputTok).clamp(32, usable);
      return _LocalMtCaps(
        maxInputTokens: inputTok,
        maxNewTokens: newTok2,
      );
    }

    final maxNewByContext = usable ~/ 2;
    if (newTok > maxNewByContext) newTok = maxNewByContext;
    if (newTok < _mtHardMinNewTokens) newTok = _mtHardMinNewTokens;

    var inputTok = usable - newTok;
    if (inputTok > hardMaxInputTokens) inputTok = hardMaxInputTokens;
    if (inputTok < 256) inputTok = 256;
    if (inputTok + newTok > usable) {
      newTok = usable - inputTok;
      if (newTok < _mtHardMinNewTokens) {
        newTok = _mtHardMinNewTokens;
      }
    }

    return _LocalMtCaps(
      maxInputTokens: inputTok,
      maxNewTokens: newTok,
    );
  }

  String _buildPrompt({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) {
    final sLang = sourceLang.toLowerCase().trim();
    final src = text.trimRight();
    final bool srcLooksZh = RegExp(r'[\u4E00-\u9FFF]').hasMatch(src);
    final bool srcIsZh = sLang.contains('zh') || sLang == 'cn' || srcLooksZh;

    if (contextSources.isNotEmpty) {
      final langTo = _displayLang(targetLang, isSource: false);
      final ctx = contextSources
          .map((e) => _clip(_squashSpaces(e), 140))
          .where((e) => e.trim().isNotEmpty)
          .join('\n');
      return [
        ctx,
        '参考上面的信息，把下面的文本翻译成$langTo。只输出译文，并用<answer>...</answer>包裹，不要翻译上文，不要额外解释：',
        src,
      ].join('\n');
    }

    if (srcIsZh) {
      final langTo = _displayLang(targetLang, isSource: false);
      return [
        '将以下文本翻译为$langTo。只输出译文，并用<answer>...</answer>包裹，不要额外解释：',
        '',
        src,
      ].join('\n');
    }

    final langToEn = _displayLangEn(targetLang);
    return [
      'Translate the following segment into $langToEn. Respond with the translation only, enclosed in <answer>...</answer>, without additional explanation.',
      '',
      src,
    ].join('\n');
  }

  String _postProcessModelOutput(
    String input, {
    required String sourceText,
    required String sourceLang,
    required String targetLang,
  }) {
    final raw = input.trim();
    if (raw.isEmpty) return '';

    String s = _stripSpecialTokens(raw);

    if (_debug) {
      // ignore: avoid_print
      print('[LocalTranslationEngine] raw=${raw.length} cleaned=${s.length}');
    }

    final answerFromRaw = _extractAnswerTag(s);
    if (answerFromRaw != null && answerFromRaw.trim().isNotEmpty) {
      return _cleanupTranslation(
        answerFromRaw,
        sourceText: sourceText,
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
    }

    s = _stripThinkTags(s);
    final bracketTagged = _extractBracketTag(s);
    if (bracketTagged != null) {
      s = bracketTagged.trim();
    }

    final answer = _extractAnswerTag(s);
    if (answer != null && answer.trim().isNotEmpty) {
      return _cleanupTranslation(
        answer,
        sourceText: sourceText,
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
    }

    final extracted = _extractAfterMarker(
      s,
      markers: const ['译文：', '译文:', 'Translation:', 'translation:'],
    );
    if (extracted != null && extracted.trim().isNotEmpty) {
      return _cleanupTranslation(
        extracted,
        sourceText: sourceText,
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
    }

    s = _stripPromptEcho(s);
    return _cleanupTranslation(
      s,
      sourceText: sourceText,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
  }

  String _cleanupTranslation(
    String input, {
    required String sourceText,
    required String sourceLang,
    required String targetLang,
  }) {
    var s = _stripSpecialTokens(input.trim());
    s = _stripThinkTags(s);
    s = s.replaceAll('<answer>', '').replaceAll('</answer>', '');
    s = s.replaceAll(RegExp(r'</?\[[^\]]+\]>'), '');
    s = _stripPromptEcho(s);
    s = _stripSourceEcho(s, sourceText: sourceText);
    s = s.trim();

    final extracted = _extractAfterMarker(
      s,
      markers: const ['译文：', '译文:', 'Translation:', 'translation:'],
    );
    if (extracted != null && extracted.trim().isNotEmpty) {
      s = extracted.trim();
    }

    s = _pickBestCandidate(
      s,
      sourceText: sourceText,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );

    return s.trim();
  }

  String _stripPromptEcho(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    final markers = <String>[
      '将以下文本翻译为',
      '将以下文本翻译成',
      '把下面的文本翻译成',
      '把下面的文本翻译为',
      'Translate the following segment into',
      '参考上面的信息，把下面的文本翻译成',
    ];
    for (final m in markers) {
      final idx = s.lastIndexOf(m);
      if (idx >= 0) {
        final after = s.substring(idx);
        final sep = after.indexOf('\n\n');
        if (sep >= 0) {
          s = after.substring(sep + 2).trim();
        } else {
          final nl = after.indexOf('\n');
          if (nl >= 0) {
            s = after.substring(nl + 1).trim();
          }
        }
      }
    }
    return s.trim();
  }

  String _stripSourceEcho(String input, {required String sourceText}) {
    var s = input.trim();
    final src = sourceText.trim();
    if (s.isEmpty || src.isEmpty) return s;
    if (!s.contains(src)) return s;

    final removed = s.replaceAll(src, '').trim();
    if (removed.isEmpty) return s;
    if (_isMostlyPunctOrSpace(removed)) return s;
    if (removed.length < 6 && removed.length < (s.length * 0.4)) return s;
    return removed;
  }

  String _stripSpecialTokens(String input) {
    var s = input;
    s = s.replaceAll(RegExp(r'<\|[^>]+\|>'), '');
    s = s.replaceAll(RegExp(r'<0x[0-9A-Fa-f]{2}>'), '');
    s = s.replaceAll('\u0120', ' ');
    s = s.replaceAll('\u010a', '\n');
    s = s.replaceAll('\u2581', ' ');
    s = s.replaceAll('\u200B', '');
    s = s.replaceAll('\u2060', '');
    s = s.replaceAll('\uFEFF', '');
    s = s.replaceAll('\uFFFD', '');
    s = s.replaceAll('\u00A0', ' ');
    s = s.replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '');
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  String _stripThinkTags(String input) {
    var s = input;
    s = s.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', multiLine: true),
      '',
    );
    s = s.replaceAll('<think>', '').replaceAll('</think>', '');
    return s.trim();
  }

  String? _extractAfterMarker(String input, {required List<String> markers}) {
    var bestIdx = -1;
    var bestMarker = '';
    for (final m in markers) {
      final idx = input.lastIndexOf(m);
      if (idx > bestIdx) {
        bestIdx = idx;
        bestMarker = m;
      }
    }
    if (bestIdx < 0) return null;
    return input.substring(bestIdx + bestMarker.length).trim();
  }

  String? _extractAnswerTag(String input) {
    const open = '<answer>';
    const close = '</answer>';
    final start = input.indexOf(open);
    if (start < 0) return null;
    final afterOpen = start + open.length;
    final end = input.indexOf(close, afterOpen);
    if (end >= 0) {
      return input.substring(afterOpen, end);
    }
    return input.substring(afterOpen);
  }

  String? _extractBracketTag(String input) {
    final openStart = input.lastIndexOf('<[');
    if (openStart < 0) return null;
    final openEnd = input.indexOf(']>', openStart);
    if (openEnd < 0) return null;
    final tag = input.substring(openStart + 2, openEnd);
    final afterOpen = openEnd + 2;
    final close = '</[$tag]>';
    final closeIdx = input.indexOf(close, afterOpen);
    if (closeIdx >= 0) {
      return input.substring(afterOpen, closeIdx);
    }
    return input.substring(afterOpen);
  }

  String _clip(String input, int maxChars) {
    final s = input.trim();
    if (s.length <= maxChars) return s;
    return s.substring(0, maxChars);
  }

  String _squashSpaces(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _displayLang(String input, {required bool isSource}) {
    final s = input.trim();
    if (s.isEmpty) return isSource ? '自动' : '';

    final normalized = s.toLowerCase();
    final Map<String, String> map = {
      'auto': '自动',
      'zh': '中文',
      'zh-cn': '中文',
      'zh-hans': '中文',
      'zh-hant': '中文（繁体）',
      'zh-tw': '中文（繁体）',
      'en': '英语',
      'en-us': '英语',
      'en-gb': '英语',
      'ja': '日语',
      'jp': '日语',
      'ko': '韩语',
      'fr': '法语',
      'de': '德语',
      'es': '西班牙语',
      'it': '意大利语',
      'ru': '俄语',
      'pt': '葡萄牙语',
      'pt-br': '葡萄牙语（巴西）',
      'ar': '阿拉伯语',
      'hi': '印地语',
      'th': '泰语',
      'vi': '越南语',
      'id': '印尼语',
      'tr': '土耳其语',
    };

    return map[normalized] ?? s;
  }

  String _displayLangEn(String input) {
    final s = input.trim().toLowerCase();
    if (s.isEmpty) return 'English';

    final Map<String, String> map = {
      'auto': 'Auto',
      'zh': 'Chinese',
      'zh-cn': 'Chinese',
      'zh-hans': 'Chinese',
      'zh-hant': 'Traditional Chinese',
      'zh-tw': 'Traditional Chinese',
      'en': 'English',
      'en-us': 'English',
      'en-gb': 'English',
      'ja': 'Japanese',
      'jp': 'Japanese',
      'ko': 'Korean',
      'fr': 'French',
      'de': 'German',
      'es': 'Spanish',
      'it': 'Italian',
      'ru': 'Russian',
      'pt': 'Portuguese',
      'pt-br': 'Portuguese',
      'ar': 'Arabic',
      'hi': 'Hindi',
      'th': 'Thai',
      'vi': 'Vietnamese',
      'id': 'Indonesian',
      'tr': 'Turkish',
    };

    if (map.containsKey(s)) return map[s]!;

    for (final k in map.keys) {
      if (s.startsWith(k)) return map[k]!;
    }

    return s;
  }

  String _pickBestCandidate(
    String input, {
    required String sourceText,
    required String sourceLang,
    required String targetLang,
  }) {
    final src = sourceText.trim();
    final base = input.trim();
    if (base.isEmpty) return base;

    final baseStats = _scriptStats(base);

    final candidates = <String>[];
    void addCandidate(String? v) {
      final s = (v ?? '').trim();
      if (s.isEmpty) return;
      candidates.add(s);
    }

    addCandidate(base);
    addCandidate(_stripSourceEcho(base, sourceText: sourceText));

    for (final line in base.split('\n')) {
      addCandidate(line);
    }

    final afterMarkers = _extractAfterMarker(
      base,
      markers: const ['译文：', '译文:', 'Translation:', 'translation:'],
    );
    if (afterMarkers != null && afterMarkers.trim().isNotEmpty) {
      addCandidate(afterMarkers);
    }

    final dedup = <String>{};
    final cleanedCandidates = <String>[];
    for (final c in candidates) {
      if (!dedup.add(c)) continue;
      var s = c.trim();
      if (s.isEmpty) continue;
      s = _stripSpecialTokens(s);
      s = _stripThinkTags(s);
      s = s.replaceAll('<answer>', '').replaceAll('</answer>', '');
      s = s.replaceAll(RegExp(r'</?\[[^\]]+\]>'), '');
      s = _stripPromptEcho(s);
      s = _stripSourceEcho(s, sourceText: sourceText);
      s = s.trim();
      if (s.isEmpty) continue;
      cleanedCandidates.add(s);
    }
    if (cleanedCandidates.isEmpty) return base;

    final tl = targetLang.toLowerCase();
    final wantEn = tl == 'en' || tl.startsWith('en-') || tl.contains('english');
    final wantZh = tl == 'zh' ||
        tl.startsWith('zh-') ||
        tl == 'cn' ||
        tl.contains('chinese');

    final baseHasMultipleLines =
        base.split('\n').where((e) => e.trim().isNotEmpty).length >= 2;
    final baseLooksOk = wantEn
        ? (baseStats.latinRatio >= 0.18 &&
            baseStats.cjkRatio <= 0.28 &&
            baseStats.weirdRatio <= 0.01)
        : wantZh
            ? (baseStats.cjkRatio >= 0.12 &&
                baseStats.latinRatio <= 0.30 &&
                baseStats.weirdRatio <= 0.01)
            : baseStats.weirdRatio <= 0.01;

    double scoreOf(String s) {
      final stats = _scriptStats(s);
      final cjk = stats.cjkRatio;
      final latin = stats.latinRatio;
      final weird = stats.weirdRatio;
      var score = 0.0;
      score -= weird * 6.0;
      if (wantEn) {
        score += latin * 2.4;
        score -= cjk * 4.2;
      } else if (wantZh) {
        score += cjk * 2.2;
        score -= latin * 1.4;
      }
      score += (s.length.clamp(0, 200) / 200.0) * 0.35;
      if (src.isNotEmpty && s.trim() == src) score -= 2.0;
      if (src.isNotEmpty && s.contains(src) && s.length > src.length) {
        score -= 1.2;
      }
      if (baseLooksOk &&
          baseHasMultipleLines &&
          !s.contains('\n') &&
          base.startsWith(s) &&
          s.length < (base.length * 0.7)) {
        score -= 0.8;
      }
      if (s.length < 2) score -= 0.8;
      return score;
    }

    var best = cleanedCandidates.first;
    var bestScore = scoreOf(best);
    for (final c in cleanedCandidates.skip(1)) {
      final sc = scoreOf(c);
      if (sc > bestScore + 1e-6 ||
          ((sc - bestScore).abs() <= 1e-6 && c.length > best.length)) {
        best = c;
        bestScore = sc;
      }
    }

    if (_debug) {
      // ignore: avoid_print
      print(
          '[LocalTranslationEngine] candidates=${cleanedCandidates.length} bestScore=${bestScore.toStringAsFixed(3)} bestLen=${best.length}');
    }

    return best.trim();
  }

  _ScriptStats _scriptStats(String s) {
    int total = 0;
    int cjk = 0;
    int latin = 0;
    int weird = 0;
    for (final r in s.runes) {
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3400 && r <= 0x4DBF) ||
          (r >= 0xF900 && r <= 0xFAFF)) {
        total++;
        cjk++;
        continue;
      }
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        total++;
        latin++;
        continue;
      }
      if (r == 0x20 || r == 0x0A || r == 0x09 || r == 0x0D) {
        continue;
      }
      if (r == 0xFFFD) {
        weird++;
        continue;
      }
      if (r < 0x20 && r != 0x0A && r != 0x09 && r != 0x0D) {
        weird++;
        continue;
      }
      if (r == 0x0120 || r == 0x2581) {
        weird++;
        continue;
      }
    }
    final t = total <= 0 ? 1 : total;
    return _ScriptStats(
      cjkRatio: cjk / t,
      latinRatio: latin / t,
      weirdRatio: weird / t,
    );
  }

  bool _isMostlyPunctOrSpace(String s) {
    int nonSpace = 0;
    int punct = 0;
    for (final r in s.runes) {
      if (r == 0x20 || r == 0x0A || r == 0x09 || r == 0x0D) continue;
      nonSpace++;
      final isAlphaNum = (r >= 0x30 && r <= 0x39) ||
          (r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A) ||
          (r >= 0x4E00 && r <= 0x9FFF);
      if (!isAlphaNum) punct++;
    }
    if (nonSpace == 0) return true;
    return punct / nonSpace > 0.85;
  }
}

class _LocalMtCaps {
  final int maxInputTokens;
  final int maxNewTokens;

  const _LocalMtCaps({
    required this.maxInputTokens,
    required this.maxNewTokens,
  });
}

class _ScriptStats {
  final double cjkRatio;
  final double latinRatio;
  final double weirdRatio;

  const _ScriptStats({
    required this.cjkRatio,
    required this.latinRatio,
    required this.weirdRatio,
  });
}
