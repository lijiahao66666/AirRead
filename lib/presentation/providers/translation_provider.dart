import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/hunyuan/hunyuan_translation_engine.dart';
import '../../ai/tencentcloud/tencent_credentials.dart';
import '../../ai/translation/glossary.dart';
import '../../ai/translation/translation_cache.dart';
import '../../ai/translation/translation_service.dart';
import '../../ai/translation/translation_types.dart';
import 'tencent_hunyuan_config_provider.dart';

class TranslationProvider extends ChangeNotifier {
  static const _kCfgEngine = 'tr_cfg_engine';
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
  TencentHunyuanConfigProvider? _hunyuanConfig;

  TranslationConfig _config = const TranslationConfig(
    engineType: TranslationEngineType.ai,
    sourceLang: '',
    targetLang: 'en',
    displayMode: TranslationDisplayMode.translationOnly,
  );

  bool _applyToReader = false;
  bool _aiTranslateEnabled = false;
  bool _aiReadAloudEnabled = false;
  bool _aiImageTextEnabled = false;
  bool _loaded = false;

  TranslationProvider({TencentHunyuanConfigProvider? hunyuanConfig}) {
    _hunyuanConfig = hunyuanConfig;
    _rebuildService();
    _loadFromPrefs();
  }

  void updateHunyuanConfig(TencentHunyuanConfigProvider config) {
    _hunyuanConfig = config;
    _rebuildService();
  }

  void _rebuildService() {
    final creds = _hunyuanConfig?.effectiveCredentials ??
        const TencentCredentials(appId: '', secretId: '', secretKey: '');

    final engine = HunyuanTranslationEngine(credentials: creds);

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

  bool get isHunyuanConfigured => _hunyuanConfig?.hasUsableCredentials ?? false;

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    final from = prefs.getString(_kCfgFrom);
    final to = prefs.getString(_kCfgTo);
    final mode = prefs.getString(_kCfgMode);
    final apply = prefs.getBool(_kCfgApply);

    _aiTranslateEnabled = prefs.getBool(_kAiTranslateEnabled) ?? false;
    _aiReadAloudEnabled = prefs.getBool(_kAiReadAloudEnabled) ?? false;
    _aiImageTextEnabled = prefs.getBool(_kAiImageTextEnabled) ?? false;

    TranslationEngineType engineType = TranslationEngineType.ai;

    TranslationDisplayMode displayMode = _config.displayMode;
    if (mode == 'bilingual') displayMode = TranslationDisplayMode.bilingual;
    if (mode == 'translationOnly') {
      displayMode = TranslationDisplayMode.translationOnly;
    }

    _config = _config.copyWith(
      engineType: engineType,
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
    await prefs.setString(
      _kCfgEngine,
      'ai',
    );
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

  Future<void> setEngineType(TranslationEngineType type) async {
    _config = _config.copyWith(engineType: TranslationEngineType.ai);
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
    if (!isHunyuanConfigured) {
      throw TranslationConfigException('未配置大模型凭证。请在“大模型设置”中配置。');
    }
  }
}

class TranslationConfigException implements Exception {
  final String message;
  TranslationConfigException(this.message);
  @override
  String toString() => message;
}
