import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/translation/engines/microsoft_translator_engine.dart';
import '../../ai/translation/engines/volc_llm_engine.dart';
import '../../ai/translation/glossary.dart';
import '../../ai/translation/translation_cache.dart';
import '../../ai/translation/translation_service.dart';
import '../../ai/translation/translation_types.dart';

class TranslationProvider extends ChangeNotifier {
  static const _kCfgEngine = 'tr_cfg_engine';
  static const _kCfgFrom = 'tr_cfg_from';
  static const _kCfgTo = 'tr_cfg_to';
  static const _kCfgMode = 'tr_cfg_mode';
  static const _kCfgApply = 'tr_cfg_apply';
  static const _kGlossary = 'tr_glossary_terms';

  final TranslationCache _cache = TranslationCache(ttl: const Duration(hours: 24));
  final GlossaryManager _glossary = GlossaryManager();

  late final TranslationService _service;

  TranslationConfig _config = const TranslationConfig(
    engineType: TranslationEngineType.machine,
    sourceLang: '',
    targetLang: 'en',
    displayMode: TranslationDisplayMode.translationOnly,
  );

  bool _applyToReader = false;
  bool _loaded = false;

  TranslationProvider() {
    final msKey = const String.fromEnvironment('MS_TRANSLATOR_KEY');
    final msRegion = const String.fromEnvironment('MS_TRANSLATOR_REGION');

    final volcBaseUrl = const String.fromEnvironment(
      'VOLC_LLM_BASE_URL',
      defaultValue: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    );
    final volcApiKey = const String.fromEnvironment('VOLC_LLM_API_KEY');
    final volcModel = const String.fromEnvironment(
      'VOLC_LLM_MODEL',
      defaultValue: 'doubao-pro-32k',
    );

    _service = TranslationService(
      cache: _cache,
      glossary: _glossary,
      machineEngine: MicrosoftTranslatorEngine(
        subscriptionKey: msKey,
        subscriptionRegion: msRegion,
      ),
      aiEngine: VolcLlmTranslatorEngine(
        baseUrl: volcBaseUrl,
        apiKey: volcApiKey,
        model: volcModel,
      ),
    );


    _loadFromPrefs();
  }

  bool get loaded => _loaded;

  TranslationConfig get config => _config;
  bool get applyToReader => _applyToReader;
  UnmodifiableListView<GlossaryTerm> get glossaryTerms => _glossary.terms;

  bool get isMicrosoftConfigured {
    final key = const String.fromEnvironment('MS_TRANSLATOR_KEY');
    final region = const String.fromEnvironment('MS_TRANSLATOR_REGION');
    return key.trim().isNotEmpty && region.trim().isNotEmpty;
  }

  bool get isVolcConfigured {
    final apiKey = const String.fromEnvironment('VOLC_LLM_API_KEY');
    return apiKey.trim().isNotEmpty;
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    final engine = prefs.getString(_kCfgEngine);
    final from = prefs.getString(_kCfgFrom);
    final to = prefs.getString(_kCfgTo);
    final mode = prefs.getString(_kCfgMode);
    final apply = prefs.getBool(_kCfgApply);

    TranslationEngineType engineType = _config.engineType;
    if (engine == 'ai') engineType = TranslationEngineType.ai;
    if (engine == 'machine') engineType = TranslationEngineType.machine;

    TranslationDisplayMode displayMode = _config.displayMode;
    if (mode == 'bilingual') displayMode = TranslationDisplayMode.bilingual;
    if (mode == 'translationOnly') {
      displayMode = TranslationDisplayMode.translationOnly;
    }

    _config = _config.copyWith(
      engineType: engineType,
      sourceLang: from ?? _config.sourceLang,
      targetLang: (to ?? _config.targetLang).trim().isEmpty ? _config.targetLang : to,
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
    await prefs.setString(
      _kCfgEngine,
      _config.engineType == TranslationEngineType.ai ? 'ai' : 'machine',
    );
    await prefs.setString(_kCfgFrom, _config.sourceLang);
    await prefs.setString(_kCfgTo, _config.targetLang);
    await prefs.setString(
      _kCfgMode,
      _config.displayMode == TranslationDisplayMode.bilingual ? 'bilingual' : 'translationOnly',
    );
    await prefs.setBool(_kCfgApply, _applyToReader);
    await prefs.setString(
      _kGlossary,
      jsonEncode(_glossary.terms.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> setEngineType(TranslationEngineType type) async {
    _config = _config.copyWith(engineType: type);
    notifyListeners();
    await _savePrefs();
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

  Future<Map<int, String>> translateParagraphsByIndex(Map<int, String> paragraphsByIndex) async {
    _validateEngineConfig();
    return _service.translateParagraphs(
      config: _config,
      paragraphsByIndex: paragraphsByIndex,
    );
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

    if (_config.engineType == TranslationEngineType.machine && !isMicrosoftConfigured) {
      throw TranslationConfigException(
        '未配置微软翻译密钥。请在启动参数中传入 MS_TRANSLATOR_KEY 与 MS_TRANSLATOR_REGION。',
      );
    }

    if (_config.engineType == TranslationEngineType.ai && !isVolcConfigured) {
      throw TranslationConfigException(
        '未配置火山大模型密钥。请在启动参数中传入 VOLC_LLM_API_KEY。',
      );
    }
  }
}

class TranslationConfigException implements Exception {
  final String message;
  TranslationConfigException(this.message);
  @override
  String toString() => message;
}
