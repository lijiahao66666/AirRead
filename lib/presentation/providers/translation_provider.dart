import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/local_llm/local_llm_client.dart';
import '../../ai/local_llm/local_translation_engine.dart';
import '../../ai/hunyuan/hunyuan_translation_engine.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/translation/translation_cache.dart';
import '../../ai/translation/translation_service.dart';
import '../../ai/translation/translation_types.dart';
import 'ai_model_provider.dart';

class TranslationProvider extends ChangeNotifier {
  static const _kCfgFrom = 'tr_cfg_from';
  static const _kCfgTo = 'tr_cfg_to';
  static const _kCfgMode = 'tr_cfg_mode';
  static const _kAiTranslateEnabled = 'tr_ai_translate_enabled';
  static const _kAiReadAloudEnabled = 'tr_ai_read_aloud_enabled';
  static const _kTtsVoiceType = 'tr_tts_voice_type';
  static const _kTtsSpeed = 'tr_tts_speed';

  final TranslationCache _cache =
      TranslationCache(ttl: const Duration(days: 30));

  late TranslationService _service;
  AiModelProvider? _aiModel;
  VoidCallback? _aiModelListener;

  TranslationConfig _config = const TranslationConfig(
    sourceLang: '',
    targetLang: 'en',
    displayMode: TranslationDisplayMode.bilingual,
  );

  bool _aiTranslateEnabled = false;
  bool _aiReadAloudEnabled = false;
  bool _loaded = false;

  int _ttsVoiceType = 601003;
  double _ttsSpeed = 1.0;

  Timer? _notifyTimer;
  bool _notifyScheduled = false;

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
    }

    if (source == AiModelSource.local) {
      if (_aiReadAloudEnabled) {
        _aiReadAloudEnabled = false;
        changed = true;
      }
      final ready = _aiModel?.isLocalTranslationModelReady ?? false;
      if (!ready) {
        if (_aiTranslateEnabled) {
          _aiTranslateEnabled = false;
          changed = true;
        }
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
    final backend = switch (source) {
      AiModelSource.local => TranslationBackend.local,
      AiModelSource.online => TranslationBackend.online,
      AiModelSource.none => TranslationBackend.online,
    };

    _service = TranslationService(
      cache: _cache,
      engine: engine,
      backend: backend,
    );
  }

  bool get loaded => _loaded;

  TranslationConfig get config => _config;
  bool get applyToReader => _aiTranslateEnabled;
  bool get aiTranslateEnabled => _aiTranslateEnabled;
  bool get aiReadAloudEnabled => _aiReadAloudEnabled;
  int get ttsVoiceType => _ttsVoiceType;
  double get ttsSpeed => _ttsSpeed;

  @override
  void dispose() {
    _notifyTimer?.cancel();
    if (_aiModelListener != null) {
      _aiModel?.removeListener(_aiModelListener!);
    }
    super.dispose();
  }

  void _scheduleNotify([Duration delay = const Duration(milliseconds: 50)]) {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    _notifyTimer?.cancel();
    _notifyTimer = Timer(delay, () {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    final from = prefs.getString(_kCfgFrom);
    final to = prefs.getString(_kCfgTo);
    final mode = prefs.getString(_kCfgMode);

    _aiTranslateEnabled = prefs.getBool(_kAiTranslateEnabled) ?? false;
    _aiReadAloudEnabled = prefs.getBool(_kAiReadAloudEnabled) ?? false;
    _ttsVoiceType = prefs.getInt(_kTtsVoiceType) ?? _ttsVoiceType;
    _ttsSpeed = prefs.getDouble(_kTtsSpeed) ?? _ttsSpeed;

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

    if (!_loaded) {
      _loaded = true;
    }
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
    await prefs.setBool(_kAiTranslateEnabled, _aiTranslateEnabled);
    await prefs.setBool(_kAiReadAloudEnabled, _aiReadAloudEnabled);
    await prefs.setInt(_kTtsVoiceType, _ttsVoiceType);
    await prefs.setDouble(_kTtsSpeed, _ttsSpeed);
  }

  Future<void> setTtsVoiceType(int voiceType) async {
    if (_ttsVoiceType == voiceType) return;
    _ttsVoiceType = voiceType;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setTtsSpeed(double speed) async {
    if (_ttsSpeed == speed) return;
    _ttsSpeed = speed;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setSourceLang(String lang) async {
    _config = _config.copyWith(sourceLang: lang);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setTargetLang(String lang) async {
    if (lang.trim().isEmpty) return;
    _config = _config.copyWith(targetLang: lang);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setDisplayMode(TranslationDisplayMode mode) async {
    _config = _config.copyWith(displayMode: mode);
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setAiTranslateEnabled(bool value) async {
    if (value) {
      _validateEngineConfig();
    }
    _aiTranslateEnabled = value;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setAiReadAloudEnabled(bool value) async {
    _aiReadAloudEnabled = value;
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
  final Set<String> _failedKeys = {}; // 记录翻译失败的key

  bool isTranslationPending(String paragraphText) {
    final key =
        _service.buildCacheKey(config: _config, paragraphText: paragraphText);
    return _pendingKeys.contains(key);
  }

  bool isTranslationFailed(String paragraphText) {
    final key =
        _service.buildCacheKey(config: _config, paragraphText: paragraphText);
    return _failedKeys.contains(key);
  }

  void retryTranslation(String paragraphText) {
    final key =
        _service.buildCacheKey(config: _config, paragraphText: paragraphText);
    _failedKeys.remove(key); // 清除失败标记
    _pendingKeys.remove(key); // 清除pending标记

    // 重新请求翻译
    requestTranslationForParagraphs({0: paragraphText});
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

        Future<String> f;
        try {
          f = _service.translateParagraph(
              config: _config, paragraphText: entry.value);
        } catch (_) {
          _failedKeys.add(cacheKey);
          _pendingKeys.remove(cacheKey);
          _scheduleNotify();
          continue;
        }

        f.then((result) {
          _pendingKeys.remove(cacheKey);
          _failedKeys.remove(cacheKey); // 清除失败标记
          _scheduleNotify();
        }).catchError((e) {
          // 不缓存原文，只标记为失败
          _failedKeys.add(cacheKey);
          _pendingKeys.remove(cacheKey);
          _scheduleNotify();
        });
      }
      if (pendingChanged) {
        _scheduleNotify();
      }
    } catch (_) {}
  }

  /// Check if we have a cached translation for a given paragraph text
  String? getCachedTranslation(String text) {
    final normalized = _service.normalizeParagraphText(text);
    final key =
        _service.buildCacheKey(config: _config, paragraphText: normalized);
    final cached = _cache.getSynchronous(key);
    if (cached == null) return null;
    return cached;
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
      if (model.isLocalModelInstallingByType(LocalLlmModelType.translation)) {
        throw TranslationConfigException('翻译模型安装中…');
      }
      if (model.isLocalModelDownloadingByType(LocalLlmModelType.translation)) {
        throw TranslationConfigException('翻译模型下载中…');
      }
      if (model.isLocalModelPausedByType(LocalLlmModelType.translation)) {
        throw TranslationConfigException('翻译模型下载已暂停');
      }
      if (!model.localModelExistsByType(LocalLlmModelType.translation)) {
        throw TranslationConfigException('翻译模型未下载');
      }
      if (!model.localRuntimeAvailable) {
        throw TranslationConfigException('本地推理后端未就绪');
      }
      if (!model.isLocalTranslationModelReady) {
        throw TranslationConfigException('翻译模型未就绪');
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
