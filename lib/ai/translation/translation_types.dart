import 'package:flutter/foundation.dart';

enum TranslationEngineType {
  machine,
  ai,
}

enum TranslationDisplayMode {
  translationOnly,
  bilingual,
}

@immutable
class TranslationConfig {
  final TranslationEngineType engineType;
  /// Empty means auto-detect (if supported by engine).
  final String sourceLang;
  /// Required.
  final String targetLang;
  final TranslationDisplayMode displayMode;

  const TranslationConfig({
    required this.engineType,
    required this.sourceLang,
    required this.targetLang,
    required this.displayMode,
  });

  TranslationConfig copyWith({
    TranslationEngineType? engineType,
    String? sourceLang,
    String? targetLang,
    TranslationDisplayMode? displayMode,
  }) {
    return TranslationConfig(
      engineType: engineType ?? this.engineType,
      sourceLang: sourceLang ?? this.sourceLang,
      targetLang: targetLang ?? this.targetLang,
      displayMode: displayMode ?? this.displayMode,
    );
  }
}

@immutable
class TranslationRequest {
  final String engineId;
  final String sourceLang;
  final String targetLang;
  final String text;
  final int glossaryVersion;

  const TranslationRequest({
    required this.engineId,
    required this.sourceLang,
    required this.targetLang,
    required this.text,
    required this.glossaryVersion,
  });
}

@immutable
class TranslationResult {
  final String text;
  final bool fromCache;

  const TranslationResult({
    required this.text,
    required this.fromCache,
  });
}
