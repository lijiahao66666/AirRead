import 'package:flutter/foundation.dart';

enum TranslationDisplayMode {
  translationOnly,
  bilingual,
}

@immutable
class TranslationConfig {
  /// Empty means auto-detect (if supported by engine).
  final String sourceLang;

  /// Required.
  final String targetLang;
  final TranslationDisplayMode displayMode;

  const TranslationConfig({
    required this.sourceLang,
    required this.targetLang,
    required this.displayMode,
  });

  TranslationConfig copyWith({
    String? sourceLang,
    String? targetLang,
    TranslationDisplayMode? displayMode,
  }) {
    return TranslationConfig(
      sourceLang: sourceLang ?? this.sourceLang,
      targetLang: targetLang ?? this.targetLang,
      displayMode: displayMode ?? this.displayMode,
    );
  }
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
