import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/hunyuan/hunyuan_translation_engine.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/tencentcloud/tmt_translation_engine.dart';
import '../../ai/translation/translation_cache.dart';
import '../../ai/translation/translation_service.dart';
import '../../ai/translation/translation_types.dart';
import 'ai_model_provider.dart';

enum TranslationMode {
  machine,
  bigModel,
}

enum ReadAloudEngine {
  local,
  online,
}

class TranslationProvider extends ChangeNotifier {
  static const _kCfgFrom = 'tr_cfg_from';
  static const _kCfgTo = 'tr_cfg_to';
  static const _kCfgMode = 'tr_cfg_mode';
  static const _kTranslationMode = 'tr_translation_mode';
  static const _kAiTranslateEnabled = 'tr_ai_translate_enabled';
  static const _kAiReadAloudEnabled = 'tr_ai_read_aloud_enabled';
  static const _kTtsVoiceType = 'tr_tts_voice_type';
  static const _kTtsSpeed = 'tr_tts_speed';
  static const _kReadAloudEngine = 'tr_read_aloud_engine';

  static const _kUserTencentKeysEnabled = 'user_tencent_keys_enabled';
  static const _kUserTencentSecretId = 'user_tencent_secret_id';
  static const _kUserTencentSecretKey = 'user_tencent_secret_key';

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

  TranslationMode _translationMode = TranslationMode.machine;
  ReadAloudEngine _readAloudEngine = ReadAloudEngine.local;

  bool _aiTranslateEnabled = false;
  bool _aiReadAloudEnabled = false;
  bool _loaded = false;

  int _ttsVoiceType = 601003;
  double _ttsSpeed = 1.0;
  bool _usingPersonalTencentKeys = false;

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
    final entitled = _aiModel?.onlineEntitlementActive ?? false;
    bool changed = false;

    if (_aiReadAloudEnabled &&
        _readAloudEngine == ReadAloudEngine.online &&
        !_usingPersonalTencentKeys &&
        !entitled) {
      _aiReadAloudEnabled = false;
      changed = true;
    }

    if (_aiTranslateEnabled &&
        _translationMode == TranslationMode.bigModel &&
        !_usingPersonalTencentKeys &&
        !entitled) {
      _aiTranslateEnabled = false;
      changed = true;
    }

    if (changed) {
      _savePrefs().then((_) {});
    }
  }

  void _rebuildService() {
    final creds = getEmbeddedPublicHunyuanCredentials();

    final engine = switch (_translationMode) {
      TranslationMode.machine => TmtTranslationEngine(credentials: creds),
      TranslationMode.bigModel => HunyuanTranslationEngine(credentials: creds),
    };

    _service = TranslationService(
      cache: _cache,
      engine: engine,
      backend: TranslationBackend.online,
    );
  }

  Future<void> reloadTencentCredentials() async {
    await _refreshPersonalKeyState();
    _rebuildService();
    notifyListeners();
  }

  bool get loaded => _loaded;

  TranslationConfig get config => _config;
  bool get applyToReader => _aiTranslateEnabled;
  bool get aiTranslateEnabled => _aiTranslateEnabled;
  bool get aiReadAloudEnabled => _aiReadAloudEnabled;
  TranslationMode get translationMode => _translationMode;
  ReadAloudEngine get readAloudEngine => _readAloudEngine;
  int get ttsVoiceType => _ttsVoiceType;
  double get ttsSpeed => _ttsSpeed;
  bool get usingPersonalTencentKeys => _usingPersonalTencentKeys;

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
    final trMode = prefs.getString(_kTranslationMode);

    _aiTranslateEnabled = prefs.getBool(_kAiTranslateEnabled) ?? false;
    _aiReadAloudEnabled = prefs.getBool(_kAiReadAloudEnabled) ?? false;
    _ttsVoiceType = prefs.getInt(_kTtsVoiceType) ?? _ttsVoiceType;
    _ttsSpeed = prefs.getDouble(_kTtsSpeed) ?? _ttsSpeed;
    _usingPersonalTencentKeys = _readUsingPersonalTencentKeys(prefs);

    final engine = prefs.getString(_kReadAloudEngine);
    if (engine == ReadAloudEngine.online.name) {
      _readAloudEngine = ReadAloudEngine.online;
    } else {
      _readAloudEngine = ReadAloudEngine.local;
    }

    if (trMode == TranslationMode.machine.name) {
      _translationMode = TranslationMode.machine;
    } else if (trMode == TranslationMode.bigModel.name) {
      _translationMode = TranslationMode.bigModel;
    }

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

    _rebuildService();
    _syncFeatureFlagsToModel();

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
    await prefs.setString(_kTranslationMode, _translationMode.name);
    await prefs.setBool(_kAiTranslateEnabled, _aiTranslateEnabled);
    await prefs.setBool(_kAiReadAloudEnabled, _aiReadAloudEnabled);
    await prefs.setInt(_kTtsVoiceType, _ttsVoiceType);
    await prefs.setDouble(_kTtsSpeed, _ttsSpeed);
    await prefs.setString(_kReadAloudEngine, _readAloudEngine.name);
  }

  bool _readUsingPersonalTencentKeys(SharedPreferences prefs) {
    final enabled = prefs.getBool(_kUserTencentKeysEnabled) ?? false;
    if (!enabled) return false;
    final secretId = (prefs.getString(_kUserTencentSecretId) ?? '').trim();
    final secretKey = (prefs.getString(_kUserTencentSecretKey) ?? '').trim();
    return secretId.isNotEmpty && secretKey.isNotEmpty;
  }

  Future<void> _refreshPersonalKeyState() async {
    final prefs = await SharedPreferences.getInstance();
    _usingPersonalTencentKeys = _readUsingPersonalTencentKeys(prefs);
  }

  Future<void> setTranslationMode(TranslationMode mode) async {
    if (_translationMode == mode) return;
    _translationMode = mode;
    _rebuildService();
    _syncFeatureFlagsToModel();
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setReadAloudEngine(ReadAloudEngine engine) async {
    if (_readAloudEngine == engine) return;
    _readAloudEngine = engine;
    _syncFeatureFlagsToModel();
    notifyListeners();
    await _savePrefs();
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
    if (value) {
      if (_readAloudEngine == ReadAloudEngine.online &&
          !_usingPersonalTencentKeys) {
        final entitled = _aiModel?.onlineEntitlementActive ?? false;
        if (!entitled) {
          throw TranslationConfigException('朗读需要购买时长后使用');
        }
      }
    }
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
    if (!getEmbeddedPublicHunyuanCredentials().isUsable) {
      throw TranslationConfigException('未配置翻译服务密钥');
    }
    if (_translationMode == TranslationMode.bigModel) {
      if (!_usingPersonalTencentKeys) {
        final ok = _aiModel?.onlineEntitlementActive ?? false;
        if (!ok) {
          throw TranslationConfigException('大模型翻译需购买时长后使用');
        }
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
