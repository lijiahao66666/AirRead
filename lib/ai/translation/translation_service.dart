import 'dart:async';
import 'dart:collection';

import 'engines/translation_engine.dart';

import 'translation_cache.dart';
import 'translation_queue.dart';
import 'translation_types.dart';

enum TranslationBackend {
  local,
  online,
}

class TranslationService {
  final TranslationCache cache;
  final void Function(String message, Object? error, StackTrace? st)? logger;

  final TranslationTaskQueue _localQueue =
      TranslationTaskQueue(maxConcurrent: 1);
  final TranslationTaskQueue _onlineQueue =
      TranslationTaskQueue(maxConcurrent: 3);

  final Map<String, Future<String>> _inFlight = {};

  final TranslationEngine engine;
  final TranslationBackend backend;

  /// AI context cache: keep last 3 source paragraphs per (targetLang).

  final Map<String, ListQueue<String>> _aiContextSources = {};

  TranslationService({
    required this.cache,
    this.logger,
    required this.engine,
    required this.backend,
  });

  Duration get _translateTimeout {
    switch (backend) {
      case TranslationBackend.local:
        return const Duration(seconds: 70);
      case TranslationBackend.online:
        return const Duration(seconds: 45);
    }
  }

  TranslationTaskQueue get _queue {
    switch (backend) {
      case TranslationBackend.local:
        return _localQueue;
      case TranslationBackend.online:
        return _onlineQueue;
    }
  }

  String normalizeParagraphText(String text) {
    return text.trim();
  }

  String buildCacheKey({
    required TranslationConfig config,
    required String paragraphText,
  }) {
    final normalized = normalizeParagraphText(paragraphText);
    return cache.buildKey(
      engineId: engine.id,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      text: normalized,
    );
  }

  Future<String> translateParagraph({
    required TranslationConfig config,
    required String paragraphText,
  }) async {
    final normalized = normalizeParagraphText(paragraphText);
    if (!_shouldTranslateSource(normalized)) {
      return paragraphText;
    }

    final cacheKey = cache.buildKey(
      engineId: engine.id,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      text: normalized,
    );

    final cached = await cache.get(cacheKey);
    if (cached != null) {
      return cached;
    }

    final existing = _inFlight[cacheKey];
    if (existing != null) return existing;

    final future = _queue.submit(() async {
      final translated = await _withRetry(() async {
        final context = _getAiContext(config);
        final out = await engine
            .translate(
              text: normalized,
              sourceLang: config.sourceLang,
              targetLang: config.targetLang,
              contextSources: context,
            )
            .timeout(_translateTimeout);
        final cleaned = out.trim();
        if (cleaned.isEmpty) {
          throw StateError('empty translation');
        }
        if (_looksLikeBadTranslation(cleaned, normalized, config)) {
          throw StateError('bad translation');
        }
        return cleaned;
      });

      await cache.set(cacheKey, translated);

      _onAiTranslated(
        config: config,
        sourceParagraph: normalized,
        translatedParagraph: translated,
      );

      return translated;
    });

    _inFlight[cacheKey] = future;
    return future.whenComplete(() {
      _inFlight.remove(cacheKey);
    });
  }

  bool _shouldTranslateSource(String text) {
    final s = text.trim();
    if (s.isEmpty) return false;
    for (final r in s.runes) {
      if (r >= 0x30 && r <= 0x39) return true;
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) return true;
      if (r >= 0x00C0 && r <= 0x024F) return true;
      if (r >= 0x0370 && r <= 0x03FF) return true;
      if (r >= 0x0400 && r <= 0x04FF) return true;
      if (r >= 0x3040 && r <= 0x30FF) return true;
      if (r >= 0xAC00 && r <= 0xD7AF) return true;
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3400 && r <= 0x4DBF) ||
          (r >= 0xF900 && r <= 0xFAFF)) {
        return true;
      }
    }
    return false;
  }

  Future<Map<int, String>> translateParagraphs({
    required TranslationConfig config,
    required Map<int, String> paragraphsByIndex,
  }) async {
    final futures = <Future<void>>[];
    final Map<int, String> out = {};

    for (final e in paragraphsByIndex.entries) {
      futures.add(() async {
        final t =
            await translateParagraph(config: config, paragraphText: e.value);
        out[e.key] = t;
      }());
    }

    await Future.wait(futures);
    return out;
  }

  Future<void> prefetch({
    required TranslationConfig config,
    required List<String> nextParagraphs,
  }) async {
    // Fire-and-forget: queue handles concurrency, errors are ignored.
    for (final p in nextParagraphs) {
      // ignore: unawaited_futures
      translateParagraph(config: config, paragraphText: p)
          .catchError((_) => '');
    }
  }

  List<String> _getAiContext(TranslationConfig config) {
    final key = 'to:${config.targetLang}|from:${config.sourceLang}';
    final q = _aiContextSources[key];
    if (q == null) return const [];
    return q.toList(growable: false);
  }

  void _onAiTranslated({
    required TranslationConfig config,
    required String sourceParagraph,
    required String translatedParagraph,
  }) {
    final key = 'to:${config.targetLang}|from:${config.sourceLang}';
    final q = _aiContextSources.putIfAbsent(key, () => ListQueue());
    q.addLast(sourceParagraph);
    while (q.length > 3) {
      q.removeFirst();
    }
  }

  Future<T> _withRetry<T>(Future<T> Function() task) async {
    final int maxRetries = backend == TranslationBackend.local ? 2 : 3;
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        return await task();
      } on TimeoutException catch (e, st) {
        logger?.call('translate timeout (attempt $attempt/$maxRetries)', e, st);
        if (attempt >= maxRetries) rethrow;
      } catch (e, st) {
        logger?.call('translate error (attempt $attempt/$maxRetries)', e, st);
        if (attempt >= maxRetries) rethrow;
      }
      await Future.delayed(Duration(milliseconds: 200 * attempt));
    }
  }

  bool _looksLikeBadTranslation(
    String translated,
    String source,
    TranslationConfig config,
  ) {
    final t = translated.trim().toLowerCase();
    if (t.isEmpty) return true;
    if (t.contains("i can't seem to get anything meaningful") ||
        t.contains("i cant seem to get anything meaningful") ||
        t.contains('random characters') ||
        t.contains('no coherent meaning') ||
        t.contains('could you please provide') && t.contains('more context')) {
      return true;
    }

    final s = source.trim();
    if (s.isNotEmpty && translated.trim() == s) {
      if (s.length <= 8) return false;
      int alpha = 0;
      int cjk = 0;
      for (final r in s.runes) {
        if ((r >= 0x4E00 && r <= 0x9FFF) ||
            (r >= 0x3400 && r <= 0x4DBF) ||
            (r >= 0xF900 && r <= 0xFAFF)) {
          cjk++;
          continue;
        }
        if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
          alpha++;
          continue;
        }
      }
      if (alpha < 4 && cjk < 4) return false;
      return true;
    }

    final stats = _scriptStats(translated);
    final target = config.targetLang.toLowerCase().trim();
    final wantEn = target == 'en' ||
        target.startsWith('en-') ||
        target.contains('english');
    final wantZh = target == 'zh' ||
        target.startsWith('zh-') ||
        target == 'cn' ||
        target.contains('chinese');

    if (wantEn && stats.cjkRatio > 0.22 && stats.latinRatio < 0.18) {
      return true;
    }
    if (wantZh && stats.cjkRatio < 0.12 && stats.latinRatio > 0.22) {
      return true;
    }

    int weird = 0;
    int total = 0;
    for (final r in translated.runes) {
      total++;
      if (r == 0xFFFD) {
        weird++;
        continue;
      }
      if (r < 0x20 && r != 0x0A && r != 0x09 && r != 0x0D) {
        weird++;
        continue;
      }
    }
    if (total > 0 && weird / total > 0.02) return true;
    return false;
  }

  _ScriptStats _scriptStats(String s) {
    int total = 0;
    int cjk = 0;
    int latin = 0;
    for (final r in s.runes) {
      total++;
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3400 && r <= 0x4DBF) ||
          (r >= 0xF900 && r <= 0xFAFF)) {
        cjk++;
        continue;
      }
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        latin++;
        continue;
      }
    }
    final t = total <= 0 ? 1 : total;
    return _ScriptStats(
      cjkRatio: cjk / t,
      latinRatio: latin / t,
    );
  }
}

class _ScriptStats {
  final double cjkRatio;
  final double latinRatio;

  const _ScriptStats({
    required this.cjkRatio,
    required this.latinRatio,
  });
}
