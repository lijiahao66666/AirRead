import 'dart:async';

import '../translation/engines/translation_engine.dart';
import 'local_llm_client.dart';

class LocalTranslationEngine extends TranslationEngine {
  final LocalLlmClient _client;

  LocalTranslationEngine({LocalLlmClient? client})
      : _client =
            client ?? LocalLlmClient(modelType: LocalLlmModelType.translation);

  @override
  String get id => 'local_hunyuan';

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
    return _chatStreamOnce(prompt).then(_postProcessModelOutput);
  }

  Future<String> _chatStreamOnce(String prompt) async {
    final stream = _client.chatStream(
      userText: prompt,
      maxNewTokens: 1024,
      maxInputTokens: 0,
      temperature: 0.7,
      topP: 0.6,
      topK: 20,
    );

    final buffer = StringBuffer();
    final completer = Completer<String>();
    late final StreamSubscription<String> sub;

    final timer = Timer(const Duration(seconds: 55), () async {
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
        buffer.write(chunk);
      },
      onError: (e, st) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(buffer.toString());
        }
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  String _buildPrompt({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) {
    final sLang = sourceLang.toLowerCase().trim();
    final tLang = targetLang.toLowerCase().trim();
    final isZh = sLang.contains('zh') ||
        sLang == 'cn' ||
        tLang.contains('zh') ||
        tLang == 'cn';

    final buffer = StringBuffer();

    // 1. Contextual Translation (using Chinese template as per docs usually implies Chinese instruction for context)
    // Note: If strictly non-ZH context, one might want English, but docs provided Contextual Template in Chinese.
    // We will stick to Chinese instruction for Contextual if isZh is true, otherwise maybe English?
    // However, the docs only show one Contextual Template (Chinese).
    // Let's assume if it involves Chinese, we use Chinese template.
    // If it's purely foreign (e.g. En->Fr) with context, we might lack a specific template,
    // but the Non-ZH template "Translate ... into ..." is robust.
    // Let's use Chinese Contextual Template if isZh is true.
    if (contextSources.isNotEmpty && isZh) {
      final langTo = _displayLang(targetLang, isSource: false);
      for (final ctx in contextSources) {
        buffer.writeln(_clip(_squashSpaces(ctx), 220));
      }
      buffer.writeln();
      buffer.writeln('参考上面的信息，把下面的文本翻译成$langTo，注意不需要翻译上文，也不要额外解释：');
      buffer.writeln(text);
      return buffer.toString().trim();
    }

    // 2. ZH <=> XX Translation (or Contextual fallback for ZH)
    if (isZh) {
      final langTo = _displayLang(targetLang, isSource: false);
      // If we have context but didn't use the specific template above (maybe just to be safe or if we want to merge logic)
      // actually let's just use the standard ZH template if context is empty or we handled it.
      // But wait, if contextSources is NOT empty, we should use context.
      // My logic above: if (contextSources.isNotEmpty && isZh).
      // So here isZh is true, but contextSources is empty.
      buffer.writeln('将以下文本翻译为$langTo，注意只需要输出翻译后的结果，不要额外解释：');
      buffer.writeln();
      buffer.writeln(text);
      return buffer.toString().trim();
    }

    // 3. XX <=> XX (Non-ZH) Translation
    // Use English template
    final langToEn = _displayLangEn(targetLang);

    // If context exists for Non-ZH, we append it at top but use English instruction?
    // The docs don't specify Non-ZH Contextual.
    // We'll append context if present, then use standard Non-ZH instruction.
    if (contextSources.isNotEmpty) {
      buffer.writeln('### Context');
      for (final ctx in contextSources) {
        buffer.writeln(_clip(_squashSpaces(ctx), 220));
      }
      buffer.writeln();
    }

    buffer.writeln(
        'Translate the following segment into $langToEn, without additional explanation.');
    buffer.writeln();
    buffer.writeln(text);
    return buffer.toString().trim();
  }

  String _postProcessModelOutput(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return '';

    String s = raw;

    final answerFromRaw = _extractAnswerTag(s);
    if (answerFromRaw != null && answerFromRaw.trim().isNotEmpty) {
      return _cleanupTranslation(answerFromRaw);
    }

    s = _stripThinkTags(s);
    final bracketTagged = _extractBracketTag(s);
    if (bracketTagged != null) {
      s = bracketTagged.trim();
    }

    final answer = _extractAnswerTag(s);
    if (answer != null && answer.trim().isNotEmpty) {
      return _cleanupTranslation(answer);
    }

    final extracted = _extractAfterMarker(
      s,
      markers: const ['译文：', '译文:', 'Translation:', 'translation:'],
    );
    if (extracted != null && extracted.trim().isNotEmpty) {
      return _cleanupTranslation(extracted);
    }

    return _cleanupTranslation(s);
  }

  String _cleanupTranslation(String input) {
    var s = input.trim();
    s = _stripThinkTags(s);
    s = s.replaceAll('<answer>', '').replaceAll('</answer>', '');
    s = s.replaceAll(RegExp(r'</?\[[^\]]+\]>'), '');
    s = s.trim();

    final extracted = _extractAfterMarker(
      s,
      markers: const ['译文：', '译文:', 'Translation:', 'translation:'],
    );
    if (extracted != null && extracted.trim().isNotEmpty) {
      s = extracted.trim();
    }

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
}
