import 'package:flutter/foundation.dart';

enum TranslationDisplayMode {
  translationOnly,
  bilingual,
}

enum TranslationEngineType {
  machine,
  ai,
}

@immutable
class TranslationConfig {
  /// Empty means auto-detect (if supported by engine).
  final String sourceLang;
  /// Required.
  final String targetLang;
  final TranslationDisplayMode displayMode;
  final TranslationEngineType engineType;
  final bool autoExtractGlossary;

  const TranslationConfig({
    required this.sourceLang,
    required this.targetLang,
    required this.displayMode,
    this.engineType = TranslationEngineType.machine,
    this.autoExtractGlossary = true,
  });

  TranslationConfig copyWith({
    String? sourceLang,
    String? targetLang,
    TranslationDisplayMode? displayMode,
    TranslationEngineType? engineType,
    bool? autoExtractGlossary,
  }) {
    return TranslationConfig(
      sourceLang: sourceLang ?? this.sourceLang,
      targetLang: targetLang ?? this.targetLang,
      displayMode: displayMode ?? this.displayMode,
      engineType: engineType ?? this.engineType,
      autoExtractGlossary: autoExtractGlossary ?? this.autoExtractGlossary,
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

@immutable
class TranslationReference {
  final String type;
  final String text;
  final String translation;

  const TranslationReference({
    required this.type,
    required this.text,
    required this.translation,
  });
}

