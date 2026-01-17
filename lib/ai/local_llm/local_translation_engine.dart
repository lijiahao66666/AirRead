import '../translation/engines/translation_engine.dart';
import '../translation/translation_types.dart';
import 'local_llm_client.dart';

class LocalTranslationEngine extends TranslationEngine {
  final LocalLlmClient _client;

  LocalTranslationEngine({LocalLlmClient? client})
      : _client = client ?? LocalLlmClient();

  @override
  String get id => 'local_hunyuan';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
    required List<TranslationReference> references,
  }) {
    final prompt = _buildPrompt(
      text: '/no_think $text',
      sourceLang: sourceLang,
      targetLang: targetLang,
      contextSources: contextSources,
      glossaryPlaceholders: glossaryPlaceholders,
      references: references,
    );
    return _client.chatOnce(userText: prompt).then(_postProcessModelOutput);
  }

  String _buildPrompt({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
    required Map<String, String> glossaryPlaceholders,
    required List<TranslationReference> references,
  }) {
    final langFrom = sourceLang.trim().isEmpty ? '自动' : sourceLang.trim();
    final langTo = targetLang.trim();

    final glossaryHint = glossaryPlaceholders.isEmpty
        ? ''
        : glossaryPlaceholders.entries
            .take(12)
            .map((e) => '${e.key} -> ${e.value}')
            .join('\n');

    final ctx = contextSources.isEmpty
        ? ''
        : contextSources.reversed
            .take(2)
            .map((e) => '- ${_clip(_squashSpaces(e), 220)}')
            .join('\n');

    final refs = references.isEmpty
        ? ''
        : references
            .take(2)
            .map((e) =>
                '源文：${_clip(_squashSpaces(e.text), 120)}\n译文：${_clip(_squashSpaces(e.translation), 120)}')
            .join('\n\n');

    final buffer = StringBuffer()
      ..writeln('你是翻译引擎。')
      ..writeln('规则：只输出译文；不要解释；不要输出<think>或思考过程；保持占位符原样不变。');

    if (glossaryHint.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('占位符映射（占位符必须原样保留）：')
        ..writeln(glossaryHint);
    }

    if (ctx.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('上下文（可参考）：')
        ..writeln(ctx);
    }

    if (refs.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('参考译例（可参考风格）：')
        ..writeln(refs);
    }

    buffer
      ..writeln()
      ..writeln('源语言：$langFrom')
      ..writeln('目标语言：$langTo')
      ..writeln('原文：')
      ..writeln(_clip(_squashSpaces(text), 900))
      ..writeln()
      ..writeln('译文：');

    return buffer.toString().trim();
  }

  String _postProcessModelOutput(String input) {
    var s = input.trim();

    final lastCloseThink = s.lastIndexOf('</think>');
    if (lastCloseThink >= 0) {
      s = s.substring(lastCloseThink + '</think>'.length).trim();
    }

    s = s.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', multiLine: true),
      '',
    );
    s = s.replaceAll(
      RegExp(r'<think>[\s\S]*', multiLine: true),
      '',
    );
    s = s.replaceAll('</think>', '');
    s = s.trim();

    final bracketTagged = _extractBracketTag(s);
    if (bracketTagged != null) {
      s = bracketTagged.trim();
    }

    final answer = _extractAnswerTag(s);
    if (answer != null) return answer.trim();

    s = s.replaceAll('<answer>', '').replaceAll('</answer>', '');
    s = s.replaceAll(RegExp(r'</?\[[^\]]+\]>'), '');
    s = s.trim();
    return s;
  }

  String? _extractAnswerTag(String input) {
    final open = '<answer>';
    final close = '</answer>';
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
    return input.replaceAll(RegExp(r'\\s+'), ' ').trim();
  }
}
