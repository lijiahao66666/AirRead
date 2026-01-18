import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

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
        return const Duration(seconds: 60);
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
        if (out.trim().isEmpty) {
          throw StateError('empty translation');
        }
        return out.trim();
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
