import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/hunyuan/hunyuan_translation_engine.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/tencentcloud/tencent_api_client.dart';
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
  static const _kReadTranslationEnabled = 'tr_read_translation_enabled';

  static const _kUserTencentKeysEnabled = 'user_tencent_keys_enabled';

  static const MethodChannel _localTtsChannel =
      MethodChannel('airread/local_tts');

  final TranslationCache _cache =
      TranslationCache(ttl: const Duration(days: 30));

  late TranslationService _service;
  AiModelProvider? _aiModel;
  VoidCallback? _aiModelListener;
  void Function(String)? onError;

  TranslationConfig _config = const TranslationConfig(
    sourceLang: '',
    targetLang: 'en',
    displayMode: TranslationDisplayMode.bilingual,
  );

  TranslationMode _translationMode = TranslationMode.machine;
  ReadAloudEngine _readAloudEngine = ReadAloudEngine.local;

  static const Set<String> _bigModelLangs = {
    'zh',
    'zh-TR',
    'yue',
    'en',
    'fr',
    'pt',
    'es',
    'ja',
    'tr',
    'ru',
    'ar',
    'ko',
    'th',
    'it',
    'de',
    'vi',
    'ms',
    'id',
  };

  static const Set<String> _machineSourceLangs = {
    '',
    'zh',
    'zh-TW',
    'en',
    'ja',
    'ko',
    'fr',
    'es',
    'it',
    'de',
    'tr',
    'ru',
    'pt',
    'vi',
    'id',
    'th',
    'ms',
    'ar',
    'hi',
  };

  static const Map<String, List<String>> _machineTargetsBySource = {
    'zh': [
      'zh-TW',
      'en',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
    ],
    'zh-TW': [
      'zh',
      'en',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
    ],
    'en': [
      'zh',
      'zh-TW',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
      'hi',
    ],
    'ja': ['zh', 'zh-TW', 'en', 'ko'],
    'ko': ['zh', 'zh-TW', 'en', 'ja'],
    'fr': ['zh', 'zh-TW', 'en', 'es', 'it', 'de', 'tr', 'ru', 'pt'],
    'es': ['zh', 'zh-TW', 'en', 'fr', 'it', 'de', 'tr', 'ru', 'pt'],
    'it': ['zh', 'zh-TW', 'en', 'fr', 'es', 'de', 'tr', 'ru', 'pt'],
    'de': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'tr', 'ru', 'pt'],
    'tr': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'de', 'ru', 'pt'],
    'ru': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'de', 'tr', 'pt'],
    'pt': ['zh', 'zh-TW', 'en', 'fr', 'es', 'it', 'de', 'tr', 'ru'],
    'vi': ['zh', 'zh-TW', 'en'],
    'id': ['zh', 'zh-TW', 'en'],
    'th': ['zh', 'zh-TW', 'en'],
    'ms': ['zh', 'zh-TW', 'en'],
    'ar': ['zh', 'zh-TW', 'en'],
    'hi': ['en'],
    '': [
      'zh',
      'zh-TW',
      'en',
      'ja',
      'ko',
      'fr',
      'es',
      'it',
      'de',
      'tr',
      'ru',
      'pt',
      'vi',
      'id',
      'th',
      'ms',
      'ar',
      'hi',
    ],
  };

  bool _aiTranslateEnabled = false;
  bool _aiReadAloudEnabled = false;
  bool _readTranslationEnabled = false;
  bool _loaded = false;

  int _ttsVoiceType = 601003;
  double _ttsSpeed = 1.0;
  bool _usingPersonalTencentKeys = false;
  bool _localReadAloudAvailable = true;

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
    final personalUsable = getEmbeddedPublicHunyuanCredentials().isUsable;
    bool changed = false;

    if (_aiReadAloudEnabled &&
        _readAloudEngine == ReadAloudEngine.local &&
        !_localReadAloudAvailable) {
      _aiReadAloudEnabled = false;
      changed = true;
    }

    if (_aiReadAloudEnabled &&
        _readAloudEngine == ReadAloudEngine.online &&
        !_usingPersonalTencentKeys &&
        !entitled) {
      _aiReadAloudEnabled = false;
      changed = true;
    }

    if (_aiReadAloudEnabled &&
        _readAloudEngine == ReadAloudEngine.online &&
        _usingPersonalTencentKeys &&
        !personalUsable) {
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

    if (_aiTranslateEnabled && _usingPersonalTencentKeys && !personalUsable) {
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
  bool get readTranslationEnabled => _readTranslationEnabled;
  TranslationMode get translationMode => _translationMode;
  ReadAloudEngine get readAloudEngine => _readAloudEngine;
  int get ttsVoiceType => _ttsVoiceType;
  double get ttsSpeed => _ttsSpeed;
  bool get usingPersonalTencentKeys => _usingPersonalTencentKeys;
  bool get localReadAloudAvailable => _localReadAloudAvailable;

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

    final mode = prefs.getString(_kCfgMode);
    final trMode = prefs.getString(_kTranslationMode);

    _aiTranslateEnabled = prefs.getBool(_kAiTranslateEnabled) ?? false;
    _aiReadAloudEnabled = prefs.getBool(_kAiReadAloudEnabled) ?? false;
    _readTranslationEnabled = prefs.getBool(_kReadTranslationEnabled) ?? false;
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

    final from = prefs.getString(_kCfgFrom) ?? _config.sourceLang;
    final to = prefs.getString(_kCfgTo) ?? _config.targetLang;

    TranslationDisplayMode displayMode = _config.displayMode;
    if (mode == 'bilingual') displayMode = TranslationDisplayMode.bilingual;
    if (mode == 'translationOnly') {
      displayMode = TranslationDisplayMode.translationOnly;
    }

    _config = _sanitizeConfig(
      _config.copyWith(
        sourceLang: from,
        targetLang: to,
        displayMode: displayMode,
      ),
      _translationMode,
    );

    _rebuildService();
    _syncFeatureFlagsToModel();
    await _refreshLocalReadAloudAvailability();
    _syncFeatureFlagsToModel();

    if (!_loaded) {
      _loaded = true;
    }
    notifyListeners();
  }

  String _normalizeLangForMode(
    String lang,
    TranslationMode mode, {
    required bool isSource,
  }) {
    var v = lang.trim();
    if (v.toLowerCase() == 'auto') v = '';
    if (v.isEmpty) return isSource ? '' : v;
    if (v == 'zh-Hans') return 'zh';
    if (v == 'zh-Hant' || v == 'zh-TW' || v == 'zh-TR') {
      return mode == TranslationMode.bigModel ? 'zh-TR' : 'zh-TW';
    }
    return v;
  }

  TranslationConfig _sanitizeConfig(
    TranslationConfig cfg,
    TranslationMode mode,
  ) {
    final source = _normalizeLangForMode(
      cfg.sourceLang,
      mode,
      isSource: true,
    );
    var target = _normalizeLangForMode(
      cfg.targetLang,
      mode,
      isSource: false,
    );

    if (mode == TranslationMode.bigModel) {
      final s = source.isEmpty || _bigModelLangs.contains(source) ? source : '';
      if (target.isEmpty || !_bigModelLangs.contains(target)) {
        target = 'en';
      }
      return cfg.copyWith(sourceLang: s, targetLang: target);
    }

    final s = _machineSourceLangs.contains(source) ? source : '';
    final allowed = _machineTargetsBySource[s] ?? _machineTargetsBySource['']!;
    if (target.isEmpty || !allowed.contains(target)) {
      target = allowed.isNotEmpty ? allowed.first : 'en';
    }
    return cfg.copyWith(sourceLang: s, targetLang: target);
  }

  Future<void> _refreshLocalReadAloudAvailability() async {
    if (kIsWeb) {
      _localReadAloudAvailable = true;
      return;
    }
    bool ok = true;
    try {
      ok = await _localTtsChannel
              .invokeMethod<bool>('isAvailable')
              .timeout(const Duration(seconds: 2)) ==
          true;
    } catch (_) {
      ok = false;
    }
    if (_localReadAloudAvailable == ok) return;
    _localReadAloudAvailable = ok;
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
    await prefs.setBool(_kReadTranslationEnabled, _readTranslationEnabled);
    await prefs.setInt(_kTtsVoiceType, _ttsVoiceType);
    await prefs.setDouble(_kTtsSpeed, _ttsSpeed);
    await prefs.setString(_kReadAloudEngine, _readAloudEngine.name);
  }

  bool _readUsingPersonalTencentKeys(SharedPreferences prefs) {
    return prefs.getBool(_kUserTencentKeysEnabled) ?? false;
  }

  Future<void> _refreshPersonalKeyState() async {
    final prefs = await SharedPreferences.getInstance();
    _usingPersonalTencentKeys = _readUsingPersonalTencentKeys(prefs);
    setUserTencentKeysEnabledOverride(_usingPersonalTencentKeys);
  }

  Future<void> setTranslationMode(TranslationMode mode) async {
    if (_translationMode == mode) return;
    _translationMode = mode;
    _config = _sanitizeConfig(_config, _translationMode);
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

  Future<void> setReadTranslationEnabled(bool enabled) async {
    if (_readTranslationEnabled == enabled) return;
    _readTranslationEnabled = enabled;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setSourceLang(String lang) async {
    _config = _sanitizeConfig(
      _config.copyWith(sourceLang: lang),
      _translationMode,
    );
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setTargetLang(String lang) async {
    _config = _sanitizeConfig(
      _config.copyWith(targetLang: lang),
      _translationMode,
    );
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
      try {
        if (_readAloudEngine == ReadAloudEngine.local &&
            !_localReadAloudAvailable) {
          throw TranslationConfigException('本地朗读不可用');
        }
        if (_readAloudEngine == ReadAloudEngine.online &&
            _usingPersonalTencentKeys &&
            !getEmbeddedPublicHunyuanCredentials().isUsable) {
          throw TranslationConfigException('已开启使用个人密钥，但未正确设置个人密钥');
        }
        if (_readAloudEngine == ReadAloudEngine.online &&
            !_usingPersonalTencentKeys) {
          final entitled = _aiModel?.onlineEntitlementActive ?? false;
          if (!entitled) {
            throw TranslationConfigException('朗读需要购买时长后使用');
          }
        }
      } catch (e) {
        if (e is TranslationConfigException) {
          onError?.call(e.message);
        } else {
          onError?.call(e.toString());
        }
        rethrow;
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
  final Map<String, int> _retryCounts = {}; // 记录重试次数

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

  bool get hasPendingRequests => _pendingKeys.isNotEmpty;

  void retryTranslation(String paragraphText) {
    final key =
        _service.buildCacheKey(config: _config, paragraphText: paragraphText);
    _failedKeys.remove(key); // 清除失败标记
    _pendingKeys.remove(key); // 清除pending标记
    _retryCounts.remove(key); // 清除重试计数

    // 重新请求翻译
    requestTranslationForParagraphs({0: paragraphText});
  }

  void requestTranslationForParagraphs(Map<int, String> paragraphsByIndex) {
    if (paragraphsByIndex.isEmpty) return;
    try {
      try {
        _validateEngineConfig();
      } catch (e) {
        if (e is TranslationConfigException) {
          onError?.call(e.message);
        } else {
          onError?.call(e.toString());
        }
        rethrow;
      }
      bool pendingChanged = false;

      for (final entry in paragraphsByIndex.entries) {
        final cacheKey =
            _service.buildCacheKey(config: _config, paragraphText: entry.value);
        final existing = _cache.getSynchronous(cacheKey);
        if (existing != null) continue;

        if (_failedKeys.contains(cacheKey)) continue;

        if (_pendingKeys.contains(cacheKey)) continue;
        _pendingKeys.add(cacheKey);
        pendingChanged = true;

        Future<String> f;
        try {
          f = _service.translateParagraph(
              config: _config, paragraphText: entry.value);
        } catch (e) {
          _handleTranslationError(cacheKey, entry.value, e);
          continue;
        }

        f.then((result) {
          _pendingKeys.remove(cacheKey);
          _failedKeys.remove(cacheKey); // 清除失败标记
          _retryCounts.remove(cacheKey);
          _scheduleNotify();
        }).catchError((e) {
          _handleTranslationError(cacheKey, entry.value, e);
        });
      }
      if (pendingChanged) {
        _scheduleNotify();
      }
    } catch (_) {}
  }

  void _handleTranslationError(String key, String text, dynamic e) {
    final isNetwork = _isNetworkError(e);
    if (!isNetwork) {
      _retryCounts.remove(key);
      _failedKeys.add(key);
      _pendingKeys.remove(key);
      _scheduleNotify();
      return;
    }

    int count = (_retryCounts[key] ?? 0) + 1;
    _retryCounts[key] = count;
    if (count > 1) {
      _failedKeys.add(key);
      _pendingKeys.remove(key);
      _scheduleNotify();
      return;
    }

    Future.delayed(const Duration(seconds: 2), () {
      _pendingKeys.remove(key);
      requestTranslationForParagraphs({0: text});
    });
  }

  bool _isNetworkError(dynamic e) {
    if (e is TimeoutException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('connection') ||
        msg.contains('network') ||
        msg.contains('clientexception') ||
        msg.contains('xmlhttprequest') ||
        msg.contains('failed host lookup');
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
    if (_usingPersonalTencentKeys) {
      if (!getEmbeddedPublicHunyuanCredentials().isUsable) {
        throw TranslationConfigException('已开启使用个人密钥，但未正确设置个人密钥');
      }
    } else {
      if (!TencentApiClient.hasScfProxyUrl) {
        throw TranslationConfigException('未配置在线翻译服务地址');
      }
    }
    if (_aiTranslateEnabled && _translationMode == TranslationMode.bigModel) {
      if (_usingPersonalTencentKeys) {
        if (!getEmbeddedPublicHunyuanCredentials().isUsable) {
          throw TranslationConfigException('已开启使用个人密钥，但未正确设置个人密钥');
        }
      } else {
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
