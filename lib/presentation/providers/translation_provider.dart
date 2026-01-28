import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/hunyuan/hunyuan_translation_engine.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/tencentcloud/tencent_api_client.dart';
import '../../ai/tencentcloud/tmt_translation_engine.dart';
import '../../ai/translation/engines/translation_engine.dart';
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

class AzureTranslationEngine implements TranslationEngine {
  static const String _defaultEndpoint = String.fromEnvironment(
    'AIRREAD_AZURE_TRANSLATOR_ENDPOINT',
    defaultValue: 'https://api-edge.cognitive.microsofttranslator.com',
  );
  static const String _defaultKey =
      String.fromEnvironment('AIRREAD_AZURE_TRANSLATOR_KEY', defaultValue: '');
  static const String _defaultRegion = String.fromEnvironment(
    'AIRREAD_AZURE_TRANSLATOR_REGION',
    defaultValue: '',
  );

  final http.Client _client;
  final String endpoint;
  final String key;
  final String region;

  AzureTranslationEngine({
    http.Client? client,
    String? endpoint,
    String? key,
    String? region,
  })  : _client = client ?? http.Client(),
        endpoint = (endpoint ?? _defaultEndpoint).trim(),
        key = (key ?? _defaultKey).trim(),
        region = (region ?? _defaultRegion).trim();

  static bool get isConfigured => _defaultEndpoint.trim().isNotEmpty;

  bool get isUsable => endpoint.isNotEmpty;

  @override
  String get id => 'azure_translator';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return '';
    if (!isUsable) {
      throw StateError('Azure translator not configured');
    }

    final from = _normalizeAzureLang(sourceLang, allowEmpty: true);
    final to = _normalizeAzureLang(targetLang);
    if (to.isEmpty) {
      throw StateError('Azure target language missing');
    }

    final uri = _buildUri(from: from, to: to);
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };
    if (key.isNotEmpty) {
      headers['Ocp-Apim-Subscription-Key'] = key;
      if (region.isNotEmpty) {
        headers['Ocp-Apim-Subscription-Region'] = region;
      }
    } else {
      final token = await _getEdgeToken();
      headers['Authorization'] = 'Bearer $token';
      headers['User-Agent'] = 'Mozilla/5.0';
    }

    final body = jsonEncode([
      {'Text': normalized}
    ]);

    debugPrint(
      'AzureTranslator request to=$to from=${from.isEmpty ? 'auto' : from} endpoint=${uri.host}',
    );
    final resp = await _client
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 18));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint('AzureTranslator error status=${resp.statusCode}');
      throw StateError('Azure translate HTTP ${resp.statusCode}: ${resp.body}');
    }

    debugPrint(
        'AzureTranslator response status=${resp.statusCode} bytes=${resp.bodyBytes.length}');
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! List || decoded.isEmpty) {
      throw StateError('Azure translate response empty');
    }
    final first = decoded.first;
    if (first is! Map) {
      throw StateError('Azure translate response invalid');
    }
    final translations = first['translations'];
    if (translations is List && translations.isNotEmpty) {
      final item = translations.first;
      if (item is Map) {
        final out = item['text']?.toString() ?? '';
        return out;
      }
    }
    return '';
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
  }) async {
    final out = <String>[];
    for (final t in texts) {
      out.add(await translate(
        text: t,
        sourceLang: sourceLang,
        targetLang: targetLang,
        contextSources: const [],
      ));
    }
    return out;
  }

  Uri _buildUri({required String from, required String to}) {
    final base = Uri.parse(endpoint);
    final basePath = base.path.trim().isEmpty ? '/' : base.path;
    final resolvedPath =
        basePath.endsWith('/') ? '${basePath}translate' : '$basePath/translate';
    final params = <String, String>{
      'api-version': '3.0',
      'to': to,
    };
    if (from.isNotEmpty) {
      params['from'] = from;
    }
    return base.replace(path: resolvedPath, queryParameters: params);
  }

  Future<String> _getEdgeToken() async {
    final now = DateTime.now();
    final cached = _edgeTokenCache;
    if (cached != null && cached.expiresAt.isAfter(now)) {
      return cached.token;
    }
    final uri = Uri.parse('https://edge.microsoft.com/translate/auth');
    final resp = await _client.get(uri, headers: const {
      'User-Agent': 'Mozilla/5.0',
    }).timeout(const Duration(seconds: 10));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint('AzureTranslator token error status=${resp.statusCode}');
      throw StateError('Azure token HTTP ${resp.statusCode}');
    }
    final token = resp.body.trim();
    if (token.isEmpty) {
      throw StateError('Azure token empty');
    }
    final expiresAt = now.add(const Duration(minutes: 8));
    _edgeTokenCache = _AzureTokenCache(token: token, expiresAt: expiresAt);
    debugPrint('AzureTranslator token refreshed');
    return token;
  }

  String _normalizeAzureLang(String lang, {bool allowEmpty = false}) {
    final v = lang.trim();
    if (v.isEmpty) return allowEmpty ? '' : 'en-US';
    final lower = v.toLowerCase();
    const mapping = <String, String>{
      'en': 'en-US',
      'fr': 'fr-FR',
      'de': 'de-DE',
      'es': 'es-ES',
      'ja': 'ja-JP',
      'it': 'it-IT',
      'ko': 'ko-KR',
      'pt': 'pt-PT',
      'ar': 'ar-SA',
      'nl': 'nl-NL',
      'pl': 'pl-PL',
      'tr': 'tr-TR',
      'id': 'id-ID',
      'ru': 'ru-RU',
      'uk': 'uk-UA',
      'th': 'th-TH',
      'no': 'no-NO',
      'sv': 'sv-SE',
      'fi': 'fi-FI',
      'da': 'da-DK',
      'cs': 'cs-CZ',
      'hu': 'hu-HU',
      'ro': 'ro-RO',
      'bg': 'bg-BG',
      'hr': 'hr-HR',
      'lt': 'lt-LT',
      'sl': 'sl-SI',
      'sk': 'sk-SK',
      'bo': 'bo-CN',
      'zh': 'zh-Hans',
      'zh-cn': 'zh-Hans',
      'zh-tw': 'zh-Hant',
      'zh-mo': 'zh-Hant',
      'zh-hans': 'zh-Hans',
      'zh-hant': 'zh-Hant',
      'zh-tr': 'zh-Hant',
    };
    return mapping[lower] ?? v;
  }
}

class _AzureTokenCache {
  final String token;
  final DateTime expiresAt;
  const _AzureTokenCache({required this.token, required this.expiresAt});
}

_AzureTokenCache? _edgeTokenCache;

class FallbackTranslationEngine implements TranslationEngine {
  final TranslationEngine primary;
  final TranslationEngine fallback;
  final bool Function()? primaryAvailable;
  final bool Function()? fallbackAvailable;

  FallbackTranslationEngine({
    required this.primary,
    required this.fallback,
    this.primaryAvailable,
    this.fallbackAvailable,
  });

  @override
  String get id => '${primary.id}_fallback_${fallback.id}';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) async {
    final usePrimary = primaryAvailable?.call() ?? true;
    if (usePrimary) {
      try {
        return await primary.translate(
          text: text,
          sourceLang: sourceLang,
          targetLang: targetLang,
          contextSources: contextSources,
        );
      } catch (_) {
        if (fallbackAvailable != null && !fallbackAvailable!()) {
          rethrow;
        }
      }
    }

    if (fallbackAvailable != null && !fallbackAvailable!()) {
      throw StateError('No translation backend available');
    }

    return fallback.translate(
      text: text,
      sourceLang: sourceLang,
      targetLang: targetLang,
      contextSources: contextSources,
    );
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
  }) async {
    final usePrimary = primaryAvailable?.call() ?? true;
    if (usePrimary) {
      try {
        return await primary.translateBatch(
          texts: texts,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
      } catch (_) {
        if (fallbackAvailable != null && !fallbackAvailable!()) {
          rethrow;
        }
      }
    }

    if (fallbackAvailable != null && !fallbackAvailable!()) {
      throw StateError('No translation backend available');
    }

    return fallback.translateBatch(
      texts: texts,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
  }
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
  static const _kTtsSpeedLevel = 'tr_tts_speed_level';
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
  double _ttsSpeed = 0.0;
  bool _usingPersonalTencentKeys = false;
  bool _localReadAloudAvailable = true;

  Timer? _notifyTimer;
  bool _notifyScheduled = false;
  int _cacheRevision = 0;

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
    final entitled = (_aiModel?.pointsBalance ?? 0) > 0;
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
      TranslationMode.machine => FallbackTranslationEngine(
          primary: AzureTranslationEngine(),
          fallback: TmtTranslationEngine(credentials: creds),
          primaryAvailable: () => AzureTranslationEngine.isConfigured,
          fallbackAvailable: () =>
              _usingPersonalTencentKeys || TencentApiClient.hasScfProxyUrl,
        ),
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
  int get cacheRevision => _cacheRevision;
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

    final token = prefs.getString('tencent_scf_jwt');
    TencentApiClient.setToken(token);

    final mode = prefs.getString(_kCfgMode);
    final trMode = prefs.getString(_kTranslationMode);

    _aiTranslateEnabled = prefs.getBool(_kAiTranslateEnabled) ?? false;
    _aiReadAloudEnabled = prefs.getBool(_kAiReadAloudEnabled) ?? false;
    _readTranslationEnabled = prefs.getBool(_kReadTranslationEnabled) ?? false;
    _ttsVoiceType = prefs.getInt(_kTtsVoiceType) ?? _ttsVoiceType;

    if (prefs.containsKey(_kTtsSpeedLevel)) {
      _ttsSpeed = prefs.getDouble(_kTtsSpeedLevel) ?? 0.0;
    } else {
      double oldSpeed = prefs.getDouble(_kTtsSpeed) ?? 1.0;
      if ((oldSpeed - 0.6).abs() < 0.1) {
        _ttsSpeed = -2;
      } else if ((oldSpeed - 0.8).abs() < 0.1) {
        _ttsSpeed = -1;
      } else if ((oldSpeed - 1.0).abs() < 0.1) {
        _ttsSpeed = 0;
      } else if ((oldSpeed - 1.2).abs() < 0.1) {
        _ttsSpeed = 1;
      } else if ((oldSpeed - 1.5).abs() < 0.1) {
        _ttsSpeed = 2;
      } else if ((oldSpeed - 1.6).abs() < 0.1) {
        _ttsSpeed = 2;
      } else if ((oldSpeed - 2.5).abs() < 0.1) {
        _ttsSpeed = 6;
      } else {
        _ttsSpeed = 0;
      }
    }

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
      final status = await _localTtsChannel
          .invokeMapMethod<String, dynamic>('isAvailableWithReason')
          .timeout(const Duration(seconds: 2));
      if (status != null) {
        ok = status['ok'] == true;
      } else {
        ok = await _localTtsChannel
                .invokeMethod<bool>('isAvailable')
                .timeout(const Duration(seconds: 2)) ==
            true;
      }
    } on MissingPluginException {
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
    await prefs.setDouble(_kTtsSpeedLevel, _ttsSpeed);
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

  /// Helper to get local TTS rate multiplier from level
  double get localTtsSpeed {
    if (_ttsSpeed == -2) return 0.6;
    if (_ttsSpeed == -1) return 0.8;
    if (_ttsSpeed == 0) return 1.0;
    if (_ttsSpeed == 1) return 1.2;
    if (_ttsSpeed == 2) return 1.5;
    if (_ttsSpeed == 6) return 2.5;
    return 1.0;
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
          final points = _aiModel?.pointsBalance ?? 0;
          if (points <= 0) {
            throw TranslationConfigException('朗读需要购买积分后使用');
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

  Future<String?> translateParagraphWithState(String paragraphText) async {
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

    final normalized = _service.normalizeParagraphText(paragraphText);
    final cacheKey =
        _service.buildCacheKey(config: _config, paragraphText: normalized);
    final cached = _cache.getSynchronous(cacheKey);
    if (cached != null) return cached;
    if (_failedKeys.contains(cacheKey)) return null;
    if (_pendingKeys.contains(cacheKey)) {
      return _waitForPendingTranslation(cacheKey);
    }

    _pendingKeys.add(cacheKey);
    _scheduleNotify();
    try {
      final translated = await _service.translateParagraph(
        config: _config,
        paragraphText: normalized,
      );
      _pendingKeys.remove(cacheKey);
      _failedKeys.remove(cacheKey);
      _cacheRevision++;
      _scheduleNotify();
      return translated;
    } catch (e) {
      _handleTranslationError(cacheKey, normalized, e);
      return null;
    }
  }

  Future<String?> _waitForPendingTranslation(String cacheKey) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final cached = _cache.getSynchronous(cacheKey);
      if (cached != null) return cached;
      if (!_pendingKeys.contains(cacheKey)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return null;
  }

  /// Request translation for specific paragraphs.
  /// Results will be cached and listeners notified as they complete.
  final Set<String> _pendingKeys = {};
  final Set<String> _failedKeys = {}; // 记录翻译失败的key
  int _readerTranslationQueueTotal = 0;
  int _readerTranslationQueueCompleted = 0;
  int _readerTranslationQueueFailed = 0;
  int _readerTranslationQueueInsertFailed = 0;
  int _readerTranslationQueuePendingExternal = 0;
  bool _readerTranslationQueueRunning = false;
  bool _readerTranslationInsertRunning = false;
  bool _readerTranslationQueueInFlight = false;

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

  int get readerTranslationQueueTotal => _readerTranslationQueueTotal;
  int get readerTranslationQueueCompleted => _readerTranslationQueueCompleted;
  int get readerTranslationQueueFailed => _readerTranslationQueueFailed;
  int get readerTranslationQueueInsertFailed =>
      _readerTranslationQueueInsertFailed;
  int get readerTranslationQueuePendingExternal =>
      _readerTranslationQueuePendingExternal;
  bool get readerTranslationQueueRunning => _readerTranslationQueueRunning;
  bool get readerTranslationInsertRunning => _readerTranslationInsertRunning;
  bool get readerTranslationQueueInFlight => _readerTranslationQueueInFlight;

  void updateReaderTranslationQueueStatus({
    required int total,
    required int completed,
    required int failed,
    required int insertFailed,
    required int pendingExternal,
    required bool running,
    required bool inserting,
    required bool inFlight,
  }) {
    bool changed = false;
    if (_readerTranslationQueueTotal != total) {
      _readerTranslationQueueTotal = total;
      changed = true;
    }
    if (_readerTranslationQueueCompleted != completed) {
      _readerTranslationQueueCompleted = completed;
      changed = true;
    }
    if (_readerTranslationQueueFailed != failed) {
      _readerTranslationQueueFailed = failed;
      changed = true;
    }
    if (_readerTranslationQueueInsertFailed != insertFailed) {
      _readerTranslationQueueInsertFailed = insertFailed;
      changed = true;
    }
    if (_readerTranslationQueuePendingExternal != pendingExternal) {
      _readerTranslationQueuePendingExternal = pendingExternal;
      changed = true;
    }
    if (_readerTranslationQueueRunning != running) {
      _readerTranslationQueueRunning = running;
      changed = true;
    }
    if (_readerTranslationInsertRunning != inserting) {
      _readerTranslationInsertRunning = inserting;
      changed = true;
    }
    if (_readerTranslationQueueInFlight != inFlight) {
      _readerTranslationQueueInFlight = inFlight;
      changed = true;
    }
    if (changed) _scheduleNotify();
  }

  void retryTranslation(String paragraphText) {
    final key =
        _service.buildCacheKey(config: _config, paragraphText: paragraphText);
    _failedKeys.remove(key); // 清除失败标记
    _pendingKeys.remove(key); // 清除pending标记

    // 重新请求翻译
    requestTranslationForParagraphs({0: paragraphText});
  }

  void clearFailedForParagraphs(Iterable<String> paragraphs) {
    bool changed = false;
    for (final text in paragraphs) {
      final key = _service.buildCacheKey(config: _config, paragraphText: text);
      if (_failedKeys.remove(key)) {
        changed = true;
      }
    }
    if (changed) _scheduleNotify();
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
          _cacheRevision++;
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
    _failedKeys.add(key);
    _pendingKeys.remove(key);
    _scheduleNotify();
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
      if (!TencentApiClient.hasScfProxyUrl &&
          !AzureTranslationEngine.isConfigured) {
        throw TranslationConfigException('未配置在线翻译服务地址');
      }
    }
    if (_aiTranslateEnabled && _translationMode == TranslationMode.bigModel) {
      if (_usingPersonalTencentKeys) {
        if (!getEmbeddedPublicHunyuanCredentials().isUsable) {
          throw TranslationConfigException('已开启使用个人密钥，但未正确设置个人密钥');
        }
      } else {
        final points = _aiModel?.pointsBalance ?? 0;
        if (points <= 0) {
          throw TranslationConfigException('大模型翻译需积分后使用');
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
