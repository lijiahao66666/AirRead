import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/local_llm/local_translation_engine.dart';
import '../../ai/hunyuan/hunyuan_translation_engine.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/translation/glossary.dart';
import '../../ai/translation/translation_cache.dart';
import '../../ai/translation/translation_service.dart';
import '../../ai/translation/translation_types.dart';
import 'ai_model_provider.dart';

class TranslationProvider extends ChangeNotifier {
  static const _kCfgFrom = 'tr_cfg_from';
  static const _kCfgTo = 'tr_cfg_to';
  static const _kCfgMode = 'tr_cfg_mode';
  static const _kCfgApply = 'tr_cfg_apply';
  static const _kGlossary = 'tr_glossary_terms';
  static const _kAiTranslateEnabled = 'tr_ai_translate_enabled';
  static const _kAiReadAloudEnabled = 'tr_ai_read_aloud_enabled';
  static const _kAiImageTextEnabled = 'tr_ai_image_text_enabled';

  final TranslationCache _cache =
      TranslationCache(ttl: const Duration(hours: 24));
  final GlossaryManager _glossary = GlossaryManager();

  late TranslationService _service;
  AiModelProvider? _aiModel;
  VoidCallback? _aiModelListener;

  TranslationConfig _config = const TranslationConfig(
    sourceLang: '',
    targetLang: 'en',
    displayMode: TranslationDisplayMode.bilingual,
  );

  bool _applyToReader = false;
  bool _aiTranslateEnabled = false;
  bool _aiReadAloudEnabled = false;
  bool _aiImageTextEnabled = false;
  bool _loaded = false;

  TranslationProvider({
    AiModelProvider? aiModel,
  }) {
    if (aiModel != null) {
      updateAiModel(aiModel);
    } else {
      _rebuildService();
    }
    _loadFromPrefs();
  }

  void updateAiModel(AiModelProvider model) {
    if (identical(_aiModel, model)) return;
    if (_aiModelListener != null) {
      _aiModel?.removeListener(_aiModelListener!);
    }
    _aiModel = model;
    _aiModelListener = _onAiModelChanged;
    _aiModel?.addListener(_aiModelListener!);
    _rebuildService();
    _syncFeatureFlagsToModel();
    notifyListeners();
  }

  void _onAiModelChanged() {
    _rebuildService();
    _syncFeatureFlagsToModel();
    notifyListeners();
  }

  void _syncFeatureFlagsToModel() {
    final source = _aiModel?.source ?? AiModelSource.none;
    bool changed = false;

    if (source == AiModelSource.none) {
      if (_aiTranslateEnabled) {
        _aiTranslateEnabled = false;
        changed = true;
      }
      if (_aiReadAloudEnabled) {
        _aiReadAloudEnabled = false;
        changed = true;
      }
      if (_aiImageTextEnabled) {
        _aiImageTextEnabled = false;
        changed = true;
      }
      if (_applyToReader) {
        _applyToReader = false;
        changed = true;
      }
    }

    if (source == AiModelSource.local) {
      if (_aiReadAloudEnabled) {
        _aiReadAloudEnabled = false;
        changed = true;
      }
      if (_aiImageTextEnabled) {
        _aiImageTextEnabled = false;
        changed = true;
      }
    }

    if (changed) {
      _savePrefs().then((_) {});
    }
  }

  void _rebuildService() {
    final source = _aiModel?.source ?? AiModelSource.none;
    final creds = getEmbeddedPublicHunyuanCredentials();

    final engine = switch (source) {
      AiModelSource.local => LocalTranslationEngine(),
      AiModelSource.online => HunyuanTranslationEngine(credentials: creds),
      AiModelSource.none => HunyuanTranslationEngine(credentials: creds),
    };

    _service = TranslationService(
      cache: _cache,
      glossary: _glossary,
      machineEngine: engine,
      aiEngine: engine,
    );
  }

  bool get loaded => _loaded;

  TranslationConfig get config => _config;
  bool get applyToReader => _applyToReader;
  bool get aiTranslateEnabled => _aiTranslateEnabled;
  bool get aiReadAloudEnabled => _aiReadAloudEnabled;
  bool get aiImageTextEnabled => _aiImageTextEnabled;

  UnmodifiableListView<GlossaryTerm> get glossaryTerms => _glossary.terms;
  int get glossaryVersion => _glossary.version;

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    final from = prefs.getString(_kCfgFrom);
    final to = prefs.getString(_kCfgTo);
    final mode = prefs.getString(_kCfgMode);
    final apply = prefs.getBool(_kCfgApply);

    _aiTranslateEnabled = prefs.getBool(_kAiTranslateEnabled) ?? false;
    _aiReadAloudEnabled = prefs.getBool(_kAiReadAloudEnabled) ?? false;
    _aiImageTextEnabled = prefs.getBool(_kAiImageTextEnabled) ?? false;

    TranslationDisplayMode displayMode = _config.displayMode;
    if (mode == 'bilingual') displayMode = TranslationDisplayMode.bilingual;
    if (mode == 'translationOnly') {
      displayMode = TranslationDisplayMode.translationOnly;
    }

    _config = _config.copyWith(
      sourceLang: from ?? _config.sourceLang,
      targetLang:
          (to ?? _config.targetLang).trim().isEmpty ? _config.targetLang : to,
      displayMode: displayMode,
    );
    _applyToReader = apply ?? _applyToReader;

    final glossaryRaw = prefs.getString(_kGlossary);
    if (glossaryRaw != null && glossaryRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(glossaryRaw);
        if (decoded is List) {
          final terms = decoded
              .whereType<Map>()
              .map((m) => GlossaryTerm.fromJson(m.cast<String, dynamic>()))
              .toList();
          _glossary.replaceAll(terms);
        }
      } catch (_) {}
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCfgFrom, _config.sourceLang);
    await prefs.setString(_kCfgTo, _config.targetLang);
    await prefs.setString(
      _kCfgMode,
      _config.displayMode == TranslationDisplayMode.bilingual
          ? 'bilingual'
          : 'translationOnly',
    );
    await prefs.setBool(_kCfgApply, _applyToReader);
    await prefs.setString(
      _kGlossary,
      jsonEncode(_glossary.terms.map((e) => e.toJson()).toList()),
    );
    await prefs.setBool(_kAiTranslateEnabled, _aiTranslateEnabled);
    await prefs.setBool(_kAiReadAloudEnabled, _aiReadAloudEnabled);
    await prefs.setBool(_kAiImageTextEnabled, _aiImageTextEnabled);
  }

  Future<void> setSourceLang(String lang) async {
    _config = _config.copyWith(sourceLang: lang);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setTargetLang(String lang) async {
    _config = _config.copyWith(targetLang: lang);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setDisplayMode(TranslationDisplayMode mode) async {
    _config = _config.copyWith(displayMode: mode);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setApplyToReader(bool value) async {
    _applyToReader = value;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setAiTranslateEnabled(bool value) async {
    _aiTranslateEnabled = value;
    if (value && _aiImageTextEnabled) {
      _aiImageTextEnabled = false;
    }
    // Sync applyToReader
    _applyToReader = value;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setAiReadAloudEnabled(bool value) async {
    _aiReadAloudEnabled = value;
    if (value && _aiImageTextEnabled) {
      _aiImageTextEnabled = false;
    }
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setAiImageTextEnabled(bool value) async {
    _aiImageTextEnabled = value;
    if (value) {
      _aiTranslateEnabled = false;
      _aiReadAloudEnabled = false;
      _applyToReader = false;
    }
    notifyListeners();
    await _savePrefs();
  }

  Future<void> upsertGlossaryTerm(GlossaryTerm term) async {
    _glossary.addOrUpdate(term);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> removeGlossaryTerm(String source) async {
    _glossary.removeBySource(source);
    notifyListeners();
    await _savePrefs();
  }

  Future<Map<int, String>> translateParagraphsByIndex(
      Map<int, String> paragraphsByIndex) async {
    _validateEngineConfig();
    return _service.translateParagraphs(
      config: _config,
      paragraphsByIndex: paragraphsByIndex,
    );
  }

  /// Request translation for specific paragraphs.
  /// Results will be cached and listeners notified as they complete.
  final Set<String> _pendingKeys = {};

  bool isTranslationPending(String paragraphText) {
    final key =
        _service.buildCacheKey(config: _config, paragraphText: paragraphText);
    return _pendingKeys.contains(key);
  }

  void requestTranslationForParagraphs(Map<int, String> paragraphsByIndex) {
    if (paragraphsByIndex.isEmpty) return;
    try {
      _validateEngineConfig();
      bool pendingChanged = false;

      for (final entry in paragraphsByIndex.entries) {
        final cacheKey =
            _service.buildCacheKey(config: _config, paragraphText: entry.value);
        final existing = _cache.getSynchronous(cacheKey);
        if (existing != null) continue;
        if (_pendingKeys.add(cacheKey)) {
          pendingChanged = true;
        }

        _service
            .translateParagraph(config: _config, paragraphText: entry.value)
            .then((result) {
          _pendingKeys.remove(cacheKey);
          notifyListeners();
        }).catchError((e) {
          debugPrint('Translation failed for para ${entry.key}: $e');
          final fallback = _service.normalizeParagraphText(entry.value);
          _cache.set(cacheKey, fallback).then((_) {});
          _pendingKeys.remove(cacheKey);
          notifyListeners();
        });
      }
      if (pendingChanged) {
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Check if we have a cached translation for a given paragraph text
  String? getCachedTranslation(String text) {
    final normalized = _service.normalizeParagraphText(text);
    final applied = _glossary.applyToSourceText(normalized);
    final key =
        _service.buildCacheKey(config: _config, paragraphText: normalized);
    final cached = _cache.getSynchronous(key);
    if (cached == null) return null;
    return _glossary.applyToTranslatedText(cached, applied.placeholderToTarget);
  }

  Future<void> prefetchParagraphs(List<String> nextParagraphs) async {
    if (nextParagraphs.isEmpty) return;
    if (!_canPrefetch()) return;
    _service.prefetch(config: _config, nextParagraphs: nextParagraphs);
  }

  bool _canPrefetch() {
    try {
      _validateEngineConfig();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _validateEngineConfig() {
    if (_config.targetLang.trim().isEmpty) {
      throw TranslationConfigException('请选择目标语言');
    }
    final source = _aiModel?.source ?? AiModelSource.none;
    if (source == AiModelSource.none) {
      throw TranslationConfigException('请先在 AI伴读面板选择本地或在线大模型');
    }
    if (source == AiModelSource.online &&
        !getEmbeddedPublicHunyuanCredentials().isUsable) {
      throw TranslationConfigException('在线大模型暂不可用');
    }
    if (source == AiModelSource.local) {
      final model = _aiModel;
      if (model == null) {
        throw TranslationConfigException('本地模型未就绪');
      }
      if (model.localModelDownloading) {
        throw TranslationConfigException('本地模型下载中…');
      }
      if (!model.localModelExists) {
        throw TranslationConfigException('本地模型未下载');
      }
      if (!model.localRuntimeAvailable) {
        throw TranslationConfigException('本地推理后端未就绪');
      }
      if (!model.isLocalModelReady) {
        throw TranslationConfigException('本地模型未就绪');
      }
    }
  }
}

class TranslationConfigException implements Exception {
  final String message;
  TranslationConfigException(this.message);
  @override
  String toString() => message;
}
