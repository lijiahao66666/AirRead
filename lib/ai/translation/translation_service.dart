import 'dart:async';
import 'dart:collection';

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'engines/translation_engine.dart';

import 'glossary.dart';
import 'translation_cache.dart';
import 'translation_queue.dart';
import 'translation_types.dart';

typedef ChatOnceFn = Future<String> Function({required String userText});

enum TranslationBackend {
  local,
  online,
}

class TranslationService {
  final TranslationCache cache;
  final GlossaryManager glossary;
  final void Function(String message, Object? error, StackTrace? st)? logger;

  final TranslationTaskQueue _localQueue =
      TranslationTaskQueue(maxConcurrent: 1);
  final TranslationTaskQueue _onlineQueue =
      TranslationTaskQueue(maxConcurrent: 3);

  final Map<String, Future<String>> _inFlight = {};

  final TranslationEngine engine;
  final TranslationBackend backend;
  final ChatOnceFn? chatOnce;

  /// AI context cache: keep last 3 source paragraphs per (targetLang).

  final Map<String, ListQueue<String>> _aiContextSources = {};

  TranslationService({
    required this.cache,
    required this.glossary,
    this.logger,
    required this.engine,
    required this.backend,
    this.chatOnce,
  });

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
    final glossaryApplied = glossary.applyToSourceText(normalized);
    return cache.buildKey(
      engineId: engine.id,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      glossaryVersion: glossary.version,
      text: glossaryApplied.textWithPlaceholders,
    );
  }

  Future<String> translateParagraph({
    required TranslationConfig config,
    required String paragraphText,
  }) async {
    final normalized = normalizeParagraphText(paragraphText);
    final glossaryApplied = glossary.applyToSourceText(normalized);

    final cacheKey = cache.buildKey(
      engineId: engine.id,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      glossaryVersion: glossary.version,
      text: glossaryApplied.textWithPlaceholders,
    );

    final cached = await cache.get(cacheKey);
    if (cached != null) {
      return glossary.applyToTranslatedText(
          cached, glossaryApplied.placeholderToTarget);
    }

    final existing = _inFlight[cacheKey];
    if (existing != null) return existing;

    final future = _queue.submit(() async {
      final translated = await _withRetry(() async {
        final context = _getAiContext(config);
        final references = glossary.terms
            .map((t) => TranslationReference(
                type: 'glossary', text: t.source, translation: t.target))
            .toList();
        return engine.translate(
          text: glossaryApplied.textWithPlaceholders,
          sourceLang: config.sourceLang,
          targetLang: config.targetLang,
          contextSources: context,
          glossaryPlaceholders: glossaryApplied.placeholderToTarget,
          references: references,
        );
      });

      await cache.set(cacheKey, translated);
      final finalText = glossary.applyToTranslatedText(
          translated, glossaryApplied.placeholderToTarget);

      _onAiTranslated(
        config: config,
        sourceParagraph: normalized,
        translatedParagraph: finalText,
      );

      return finalText;
    });

    _inFlight[cacheKey] = future;
    return future.whenComplete(() {
      _inFlight.remove(cacheKey);
    });
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

    if (config.autoExtractGlossary && chatOnce != null) {
      _autoExtractGlossary(
        source: sourceParagraph,
        translation: translatedParagraph,
      );
    }
  }

  void _autoExtractGlossary({
    required String source,
    required String translation,
  }) async {
    final sourceText = _clip(_squashSpaces(source), 600);
    final translationText = _clip(_squashSpaces(translation), 600);
    final prompt = [
      '你是术语提取器。请从以下「原文」和「译文」中提取专有名词/术语，返回 JSON 数组。',
      '规则：仅输出 JSON；最多 3 项；每项包含 source 与 target；不要输出多余文字。',
      '',
      '原文：$sourceText',
      '译文：$translationText',
      '',
      'JSON：',
    ].join('\n');
    try {
      final result = await chatOnce!(userText: prompt);
      final jsonStart = result.indexOf('[');
      final jsonEnd = result.lastIndexOf(']');
      if (jsonStart != -1 && jsonEnd != -1) {
        final jsonStr = result.substring(jsonStart, jsonEnd + 1);
        final decoded = jsonDecode(jsonStr);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map &&
                item.containsKey('source') &&
                item.containsKey('target')) {
              final term = GlossaryTerm(
                source: item['source'].toString(),
                target: item['target'].toString(),
              );
              if (term.source.isNotEmpty && term.target.isNotEmpty) {
                glossary.addOrUpdate(term, overwrite: false);
              }
            }
          }
        }
      }
    } catch (e, st) {
      logger?.call('auto-glossary-extract failed', e, st);
    }
  }

  String _clip(String input, int maxChars) {
    final s = input.trim();
    if (s.length <= maxChars) return s;
    return s.substring(0, maxChars);
  }

  String _squashSpaces(String input) {
    return input.replaceAll(RegExp(r'\\s+'), ' ').trim();
  }

  Future<T> _withRetry<T>(Future<T> Function() task) async {
    const int maxRetries = 3;
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        return await task();
      } on TimeoutException catch (e, st) {
        logger?.call('translate timeout (attempt $attempt/$maxRetries)', e, st);
        debugPrint('translate timeout (attempt $attempt/$maxRetries): $e');
        if (attempt >= maxRetries) rethrow;
      } catch (e, st) {
        logger?.call('translate error (attempt $attempt/$maxRetries)', e, st);
        debugPrint('translate error (attempt $attempt/$maxRetries): $e');
        if (attempt >= maxRetries) rethrow;
      }
      await Future.delayed(Duration(milliseconds: 200 * attempt));
    }
  }
}
