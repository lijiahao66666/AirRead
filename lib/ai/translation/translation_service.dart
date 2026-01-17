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

class TranslationService {
  final TranslationCache cache;
  final GlossaryManager glossary;
  final void Function(String message, Object? error, StackTrace? st)? logger;

  final TranslationTaskQueue _machineQueue =
      TranslationTaskQueue(maxConcurrent: 3); // 保守设置，避免触发限流
  final TranslationTaskQueue _aiQueue = TranslationTaskQueue(maxConcurrent: 4);

  final Map<String, Future<String>> _inFlight = {};

  final TranslationEngine machineEngine;
  final TranslationEngine aiEngine;
  final ChatOnceFn? chatOnce;

  /// AI context cache: keep last 3 source paragraphs per (targetLang).

  final Map<String, ListQueue<String>> _aiContextSources = {};

  TranslationService({
    required this.cache,
    required this.glossary,
    this.logger,
    required this.machineEngine,
    required this.aiEngine,
    this.chatOnce,
  });

  TranslationEngine _engineFor(TranslationEngineType type) {
    switch (type) {
      case TranslationEngineType.machine:
        return machineEngine;
      case TranslationEngineType.ai:
        return aiEngine;
    }
  }

  TranslationTaskQueue _queueFor(TranslationEngineType type) {
    switch (type) {
      case TranslationEngineType.machine:
        return _machineQueue;
      case TranslationEngineType.ai:
        return _aiQueue;
    }
  }

  String normalizeParagraphText(String text) {
    return text.trim();
  }

  String buildCacheKey({
    required TranslationConfig config,
    required String paragraphText,
  }) {
    final engine = _engineFor(config.engineType);
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
    final engine = _engineFor(config.engineType);
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

    final future = _queueFor(config.engineType).submit(() async {
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
    // Machine translation: try batch for better speed.
    if (config.engineType == TranslationEngineType.machine) {
      final engine = _engineFor(config.engineType);
      final ordered = paragraphsByIndex.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));

      final applied =
          ordered.map((e) => glossary.applyToSourceText(e.value)).toList();

      final keys = <String>[];
      final toTranslateTexts = <String>[];
      final toTranslateIdxs = <int>[];
      for (int i = 0; i < ordered.length; i++) {
        final cacheKey = cache.buildKey(
          engineId: engine.id,
          sourceLang: config.sourceLang,
          targetLang: config.targetLang,
          glossaryVersion: glossary.version,
          text: applied[i].textWithPlaceholders,
        );
        keys.add(cacheKey);
        final cached = await cache.get(cacheKey);
        if (cached == null) {
          toTranslateTexts.add(applied[i].textWithPlaceholders);
          toTranslateIdxs.add(i);
        }
      }

      if (toTranslateTexts.isNotEmpty) {
        final references = glossary.terms
            .map((t) => TranslationReference(
                  type: 'glossary',
                  text: t.source,
                  translation: t.target,
                ))
            .toList();

        final results = await _queueFor(config.engineType).submit(() async {
          final list = await _withRetry(() async {
            return engine.translateBatch(
              texts: toTranslateTexts,
              sourceLang: config.sourceLang,
              targetLang: config.targetLang,
              glossaryPlaceholders: const {},
              references: references,
            );
          });
          return list;
        });

        for (int j = 0; j < results.length; j++) {
          final originalIdx = toTranslateIdxs[j];
          await cache.set(keys[originalIdx], results[j]);
        }
      }

      final Map<int, String> out = {};
      for (int i = 0; i < ordered.length; i++) {
        final raw = await cache.get(keys[i]);
        final translated = raw ?? '';
        out[ordered[i].key] = glossary.applyToTranslatedText(
            translated, applied[i].placeholderToTarget);
      }
      return out;
    }

    // AI translation: per-paragraph with context.
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
      translateParagraph(config: config, paragraphText: p).catchError((_) {});
    }
  }

  List<String> _getAiContext(TranslationConfig config) {
    if (config.engineType != TranslationEngineType.ai) return const [];
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
    if (config.engineType == TranslationEngineType.ai) {
      final key = 'to:${config.targetLang}|from:${config.sourceLang}';
      final q = _aiContextSources.putIfAbsent(key, () => ListQueue());
      q.addLast(sourceParagraph);
      while (q.length > 3) {
        q.removeFirst();
      }
    }

    if (config.autoExtractGlossary &&
        config.engineType == TranslationEngineType.ai &&
        chatOnce != null) {
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
