import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/local_llm/llm_client.dart';
import '../../ai/local_llm/model_manager.dart';
import '../../ai/local_llm/mnn_model_downloader.dart';
import '../../ai/local_llm/mnn_model_spec.dart';
import '../../ai/config/auth_service.dart';
import '../../ai/tencentcloud/tencent_api_client.dart';

enum ModelInstallStatus {
  notInstalled,
  installing,
  installed,
  failed,
}

class AiModelProvider extends ChangeNotifier {
  static const String _kPointsBalance = 'points_balance';
  static const String _kDebugPointsOverride = 'debug_points_override';
  static const String _kIllustrationCount = 'ai_illustration_count';
  static const String _kLegacyIllustrationCount = 'ai_storybook_page_count';
  static const String _kLastLocalModelId = 'ai_last_local_model_id';

  LlmClient? _llmClient;
  String _activeLocalModelId = ModelManager.defaultLocalModelId;
  int _pointsBalance = 0;
  int? _debugPointsOverride;
  int _illustrationCount = 0; // 0 = Auto
  bool _anyLocalModelInstalled = false;
  Timer? _localIdleUnloadTimer;
  DateTime? _lastLocalInferenceAt;
  int? _lastIdleScheduleAtMs;
  String? _lastIdleScheduleModelId;

  final Map<String, ModelInstallStatus> _installStatusByModelId = {};
  final Map<String, double> _downloadProgressByModelId = {};
  final Map<String, String> _currentDownloadFileByModelId = {};
  String? _downloadingModelId;
  MnnModelDownloader? _downloader;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription? _fileSubscription;

  AiModelProvider() {
    TencentApiClient.onPointsBalanceChanged = (v) {
      if (_pointsBalance == v) return;
      unawaited(setPointsBalance(v));
    };
    _load();
  }

  bool get loaded => _llmClient != null && _llmClient!.isAvailable;
  String get activeLocalModelId => _activeLocalModelId;
  List<MnnModelSpec> get availableLocalModels => ModelManager.localModels;

  bool get anyLocalTextInstalled => _anyLocalModelInstalled;
  bool get localTextReady => loaded;

  int get illustrationCount => _illustrationCount;

  Future<void> setIllustrationCount(int value) async {
    final allowed = <int>{0, 4, 8, 12};
    final next = allowed.contains(value) ? value : 0;
    if (_illustrationCount == next) return;
    _illustrationCount = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIllustrationCount, next);
    if (prefs.containsKey(_kLegacyIllustrationCount)) {
      await prefs.remove(_kLegacyIllustrationCount);
    }
  }

  Future<void> _checkAnyLocalModelInstallation() async {
    final before = _anyLocalModelInstalled;
    try {
      for (final spec in ModelManager.localModels) {
        final ok = await ModelManager.isModelInstalled(spec.id);
        if (ok) {
          _anyLocalModelInstalled = true;
          if (before != _anyLocalModelInstalled) notifyListeners();
          return;
        }
      }
      _anyLocalModelInstalled = false;
      if (before != _anyLocalModelInstalled) notifyListeners();
    } catch (_) {
      _anyLocalModelInstalled = false;
      if (before != _anyLocalModelInstalled) notifyListeners();
    }
  }

  Future<String?> _findInstalledLocalModelId() async {
    if (await ModelManager.isModelInstalled(_activeLocalModelId)) {
      return _activeLocalModelId;
    }
    for (final id in ModelManager.preferredLocalModelIds) {
      if (await ModelManager.isModelInstalled(id)) return id;
    }
    for (final spec in ModelManager.localModels) {
      if (await ModelManager.isModelInstalled(spec.id)) return spec.id;
    }
    return null;
  }

  Future<void> _ensureSelectedLocalModelInstalledIfAny() async {
    await _checkAnyLocalModelInstallation();
    if (!_anyLocalModelInstalled) return;
    final installedId = await _findInstalledLocalModelId();
    if (installedId == null) return;
    _activeLocalModelId = installedId;
    notifyListeners();
  }

  int get pointsBalance =>
      kDebugMode ? (_debugPointsOverride ?? _pointsBalance) : _pointsBalance;
  int? get debugPointsOverride => kDebugMode ? _debugPointsOverride : null;

  Future<void> setPointsBalance(int value) async {
    final v = value < 0 ? 0 : value;
    if (_pointsBalance == v) return;
    _pointsBalance = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPointsBalance, v);
  }

  Future<void> setDebugPointsOverride(int? value) async {
    if (!kDebugMode) return;
    final v = value == null ? null : (value < 0 ? 0 : value);
    if (_debugPointsOverride == v) return;
    _debugPointsOverride = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (v == null) {
      await prefs.remove(_kDebugPointsOverride);
    } else {
      await prefs.setInt(_kDebugPointsOverride, v);
    }
  }

  Future<void> addPoints(int delta) async {
    if (delta == 0) return;
    if (kDebugMode) {
      final override = _debugPointsOverride;
      if (override != null) {
        await setDebugPointsOverride(override + delta);
        return;
      }
    }
    await setPointsBalance(_pointsBalance + delta);
  }

  /// 从服务端同步积分余额（登录后用 userId，否则用 deviceId）
  Future<void> syncBalanceFromServer() => _syncBalanceFromServer();

  Future<void> _syncBalanceFromServer() async {
    try {
      final deviceId = TencentApiClient.deviceId;
      if (deviceId.isEmpty) return;
      const proxyUrl =
          String.fromEnvironment('AIRREAD_API_PROXY_URL', defaultValue: '');
      if (proxyUrl.isEmpty) return;
      const apiKey =
          String.fromEnvironment('AIRREAD_API_KEY', defaultValue: '');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'X-Device-Id': deviceId,
      };
      if (apiKey.isNotEmpty) headers['X-Api-Key'] = apiKey;
      if (AuthService.isLoggedIn && AuthService.token.isNotEmpty) {
        headers['X-Auth-Token'] = AuthService.token;
      }
      final resp = await http
          .post(Uri.parse('$proxyUrl/points/init'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final balance = (json['balance'] as num?)?.toInt();
        if (balance != null) {
          await setPointsBalance(balance);
        }
      }
    } catch (e) {
      debugPrint('[AiModelProvider] _syncBalanceFromServer error: $e');
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final localModelRaw = (prefs.getString(_kLastLocalModelId) ?? '').trim();
    final supported =
        ModelManager.localModels.any((spec) => spec.id == localModelRaw);
    _activeLocalModelId =
        supported ? localModelRaw : ModelManager.defaultLocalModelId;
    if (!supported && localModelRaw.isNotEmpty) {
      await prefs.setString(_kLastLocalModelId, _activeLocalModelId);
    }

    // 从服务端同步积分余额（deviceId 即可，无需登录）
    _pointsBalance = prefs.getInt(_kPointsBalance) ?? 0;
    unawaited(_syncBalanceFromServer());
    if (kDebugMode) {
      if (prefs.containsKey(_kDebugPointsOverride)) {
        _debugPointsOverride = prefs.getInt(_kDebugPointsOverride);
      } else {
        _debugPointsOverride = 1000;
        await prefs.setInt(_kDebugPointsOverride, 1000);
      }
    }
    final allowedPages = <int>{0, 4, 8, 12};
    int rawPages = prefs.getInt(_kIllustrationCount) ?? 0;
    if (rawPages == 0 && !prefs.containsKey(_kIllustrationCount)) {
      rawPages = prefs.getInt(_kLegacyIllustrationCount) ?? 0;
      if (prefs.containsKey(_kLegacyIllustrationCount)) {
        await prefs.setInt(_kIllustrationCount, rawPages);
        await prefs.remove(_kLegacyIllustrationCount);
      }
    }
    _illustrationCount = allowedPages.contains(rawPages) ? rawPages : 0;
    if (_illustrationCount != rawPages) {
      await prefs.setInt(_kIllustrationCount, _illustrationCount);
    }

    await _refreshAllInstallStates();
    await _checkAnyLocalModelInstallation();

    notifyListeners();
  }

  /*
  Future<void> _checkImageModelInstallation() async {
    try {
      final isInstalled =
          await ModelManager.isModelInstalled(ModelManager.sd_v1_5);
      _imageModelInstallStatus = isInstalled
          ? ModelInstallStatus.installed
          : ModelInstallStatus.notInstalled;
    } catch (e) {
      debugPrint('[AiModelProvider] _checkImageModelInstallation failed: $e');
      _imageModelInstallStatus = ModelInstallStatus.notInstalled;
    }
  }
  */

  ModelInstallStatus installStatusFor(String modelId) {
    return _installStatusByModelId[modelId] ?? ModelInstallStatus.notInstalled;
  }

  double downloadProgressFor(String modelId) {
    return _downloadProgressByModelId[modelId] ?? 0.0;
  }

  String currentDownloadFileFor(String modelId) {
    return _currentDownloadFileByModelId[modelId] ?? '';
  }

  bool isDownloadingModel(String modelId) {
    return _downloadingModelId == modelId &&
        installStatusFor(modelId) == ModelInstallStatus.installing;
  }

  Future<bool> isLocalModelInstalled(String modelId) async {
    try {
      return await ModelManager.isModelInstalled(modelId);
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshAllInstallStates() async {
    for (final spec in ModelManager.localModels) {
      try {
        final ok = await ModelManager.isModelInstalled(spec.id);
        _installStatusByModelId[spec.id] =
            ok ? ModelInstallStatus.installed : ModelInstallStatus.notInstalled;
      } catch (_) {
        _installStatusByModelId[spec.id] = ModelInstallStatus.notInstalled;
      }
    }
    notifyListeners();
  }

  Future<void> ensureLocalModelReady(String modelId) async {
    final supported =
        ModelManager.localModels.any((spec) => spec.id == modelId);
    if (!supported) {
      throw StateError('不支持的本地模型：$modelId');
    }
    final installed = await isLocalModelInstalled(modelId);
    if (!installed) {
      throw StateError('本地模型未下载：${ModelManager.displayNameFor(modelId)}');
    }
    debugPrint('[AiModelProvider] ensureLocalModelReady modelId=$modelId');
    await _initializeLlmClientFor(modelId);
  }

  Future<void> unloadLocalModel({required String reason}) async {
    final c = _llmClient;
    if (c == null) return;
    debugPrint(
      '[AiModelProvider] unload local model reason=$reason model=$_activeLocalModelId',
    );
    _localIdleUnloadTimer?.cancel();
    _lastLocalInferenceAt = null;
    _lastIdleScheduleAtMs = null;
    _lastIdleScheduleModelId = null;
    await c.dispose();
    _llmClient = null;
    notifyListeners();
  }

  void _markLocalInferenceUsed() {
    _lastLocalInferenceAt = DateTime.now();
    _localIdleUnloadTimer?.cancel();
    _localIdleUnloadTimer = Timer(const Duration(minutes: 3), () {
      final last = _lastLocalInferenceAt;
      if (last == null) return;
      final idleFor = DateTime.now().difference(last);
      if (idleFor < const Duration(minutes: 3)) return;
      final c = _llmClient;
      if (c != null) {
        debugPrint(
          '[AiModelProvider] idle unload start model=$_activeLocalModelId idleMs=${idleFor.inMilliseconds}',
        );
        unawaited(c.dispose());
      }
      _llmClient = null;
      _lastLocalInferenceAt = null;
      _lastIdleScheduleAtMs = null;
      _lastIdleScheduleModelId = null;
      debugPrint(
          '[AiModelProvider] idle unload done model=$_activeLocalModelId');
      notifyListeners();
    });
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final shouldLog = _lastIdleScheduleAtMs == null ||
        _lastIdleScheduleModelId != _activeLocalModelId ||
        nowMs - _lastIdleScheduleAtMs! > 15000;
    if (shouldLog) {
      _lastIdleScheduleAtMs = nowMs;
      _lastIdleScheduleModelId = _activeLocalModelId;
      debugPrint(
        '[AiModelProvider] idle unload scheduled model=$_activeLocalModelId',
      );
    }
  }

  Future<void> _initializeLlmClientFor(String modelId) async {
    if (_llmClient != null &&
        (_activeLocalModelId != modelId || !_llmClient!.isAvailable)) {
      debugPrint(
        '[AiModelProvider] reinit local model (current=$_activeLocalModelId target=$modelId available=${_llmClient!.isAvailable}), disposing',
      );
      _localIdleUnloadTimer?.cancel();
      _lastLocalInferenceAt = null;
      _lastIdleScheduleAtMs = null;
      _lastIdleScheduleModelId = null;
      await _llmClient!.dispose();
      _llmClient = null;
      debugPrint('[AiModelProvider] dispose complete for $_activeLocalModelId');
    }
    _llmClient ??= createLocalLlmClient();
    _activeLocalModelId = modelId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastLocalModelId, modelId);
    notifyListeners();

    try {
      await _llmClient!
          .initialize(model: modelId)
          .timeout(const Duration(seconds: 60), onTimeout: () => false);
    } catch (_) {}
    debugPrint('[AiModelProvider] initialize done model=$modelId');
    // Start idle unload timer so the model gets auto-unloaded even if
    // no inference is ever run after initialization.
    _markLocalInferenceUsed();
    notifyListeners();
  }

  Future<void> startModelDownload(String modelId) async {
    if (_downloadingModelId != null && _downloadingModelId != modelId) {
      await cancelModelDownload();
    }
    if (installStatusFor(modelId) == ModelInstallStatus.installing) return;

    _downloadingModelId = modelId;
    _installStatusByModelId[modelId] = ModelInstallStatus.installing;
    _downloadProgressByModelId[modelId] = 0.0;
    _currentDownloadFileByModelId[modelId] = '';
    notifyListeners();

    await _cancelSubscriptions();
    _downloader?.dispose();
    _downloader = null;

    _downloader = ModelManager.installModel(modelId);

    _statusSubscription = _downloader!.statusStream.listen((status) {
      final id = _downloadingModelId;
      if (id == null) return;
      switch (status) {
        case ModelDownloadStatus.completed:
          _installStatusByModelId[id] = ModelInstallStatus.installed;
          _downloadingModelId = null;
          unawaited(_checkAnyLocalModelInstallation());
          break;
        case ModelDownloadStatus.failed:
          _installStatusByModelId[id] = ModelInstallStatus.failed;
          _downloadingModelId = null;
          break;
        case ModelDownloadStatus.notDownloaded:
          _installStatusByModelId[id] = ModelInstallStatus.notInstalled;
          _downloadingModelId = null;
          unawaited(_checkAnyLocalModelInstallation());
          break;
        case ModelDownloadStatus.downloading:
        case ModelDownloadStatus.extracting:
          _installStatusByModelId[id] = ModelInstallStatus.installing;
          break;
      }
      notifyListeners();
    });

    _progressSubscription = _downloader!.progressStream.listen((progress) {
      final id = _downloadingModelId;
      if (id == null) return;
      _downloadProgressByModelId[id] = progress;
      notifyListeners();
    });

    _fileSubscription = _downloader!.currentFileStream.listen((fileName) {
      final id = _downloadingModelId;
      if (id == null) return;
      _currentDownloadFileByModelId[id] = fileName;
      notifyListeners();
    });
  }

  Future<void> cancelModelDownload() async {
    _downloader?.cancel();
    await _cancelSubscriptions();
    final id = _downloadingModelId;
    _downloadingModelId = null;
    if (id != null) {
      if (installStatusFor(id) == ModelInstallStatus.installing) {
        _installStatusByModelId[id] = ModelInstallStatus.notInstalled;
        _downloadProgressByModelId[id] = 0.0;
      }
    }
    notifyListeners();
    await _checkAnyLocalModelInstallation();
  }

  Future<void> _cancelSubscriptions() async {
    await _statusSubscription?.cancel();
    await _progressSubscription?.cancel();
    await _fileSubscription?.cancel();
    _statusSubscription = null;
    _progressSubscription = null;
    _fileSubscription = null;
  }

  Future<void> deleteModel(String modelId) async {
    if (_downloadingModelId == modelId) {
      await cancelModelDownload();
    }
    await ModelManager.deleteModel(modelId);
    _installStatusByModelId[modelId] = ModelInstallStatus.notInstalled;
    _downloadProgressByModelId.remove(modelId);
    _currentDownloadFileByModelId.remove(modelId);
    if (_activeLocalModelId == modelId) {
      _llmClient?.dispose();
      _llmClient = null;
    }
    await _checkAnyLocalModelInstallation();
    notifyListeners();
  }

  Future<String> generate({
    required String prompt,
    String? modelId,
    int maxTokens = 512,
  }) async {
    if (modelId != null) {
      await ensureLocalModelReady(modelId);
      _markLocalInferenceUsed();
    } else {
      if (_llmClient == null) {
        throw Exception('LLM client not initialized');
      }
      _markLocalInferenceUsed();
    }
    final response = await _llmClient!.generate(
      prompt: prompt,
      maxTokens: maxTokens,
    );

    return response;
  }

  Stream<String> generateStream({
    required String prompt,
    String? modelId,
    int maxTokens = 512,
  }) async* {
    if (modelId != null) {
      await ensureLocalModelReady(modelId);
      _markLocalInferenceUsed();
    } else {
      if (_llmClient == null) {
        throw Exception('LLM client not initialized');
      }
      _markLocalInferenceUsed();
    }

    yield* _llmClient!
        .generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
    )
        .map((chunk) {
      _markLocalInferenceUsed();
      return chunk;
    });
  }

  @override
  void dispose() {
    _localIdleUnloadTimer?.cancel();
    _cancelSubscriptions();
    _downloader?.dispose();
    _llmClient?.dispose();
    super.dispose();
  }
}
