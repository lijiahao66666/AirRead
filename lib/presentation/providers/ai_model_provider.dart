import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/local_llm/llm_client.dart';
import '../../ai/local_llm/model_manager.dart';
import '../../ai/local_llm/mnn_model_downloader.dart';
import '../../ai/tencentcloud/tencent_api_client.dart';

enum AiModelSource {
  none,
  local,
  online,
}

enum ModelInstallStatus {
  notInstalled,
  installing,
  installed,
  failed,
}

class AiModelProvider extends ChangeNotifier {
  static const String _kModelSource = 'ai_model_source';
  static const String _kLocalModelId = 'ai_local_model_id';
  static const String _kPointsBalance = 'points_balance';
  static const String _kMaxIllustrationsPerChapter =
      'ai_max_illustrations_per_chapter';
  static const String _kIllustrationEnabled = 'ai_illustration_enabled';

  LlmClient? _llmClient;
  AiModelSource _source = AiModelSource.none;
  String _localModelId = ModelManager.qwen3_0_6b;
  int _pointsBalance = 0;
  int _maxIllustrationsPerChapter = 3;
  bool _illustrationEnabled = false;

  // 模型安装状态
  ModelInstallStatus _modelInstallStatus = ModelInstallStatus.notInstalled;
  double _downloadProgress = 0.0;
  String _currentDownloadFile = '';
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
  AiModelSource get source => _source;
  bool get isModelEnabled => _source != AiModelSource.none;
  String get localModelId => _localModelId;
  String get localModelName => ModelManager.displayNameFor(_localModelId);
  String get localModelSizeLabel => ModelManager.sizeLabelFor(_localModelId);

  // 模型安装相关 getter
  ModelInstallStatus get modelInstallStatus => _modelInstallStatus;
  double get downloadProgress => _downloadProgress;
  String get currentDownloadFile => _currentDownloadFile;
  bool get isModelInstalled =>
      _modelInstallStatus == ModelInstallStatus.installed;
  bool get isDownloading =>
      _modelInstallStatus == ModelInstallStatus.installing;

  Future<void> setSource(AiModelSource value) async {
    if (_source == value) return;
    _source = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelSource, value.name);
  }

  Future<void> setLocalModelId(String modelId) async {
    if (_localModelId == modelId) return;
    _localModelId = modelId;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocalModelId, modelId);
    await _checkModelInstallation();
    if (_modelInstallStatus == ModelInstallStatus.installed) {
      await _initializeLlmClient();
    }
    notifyListeners();
  }

  int get pointsBalance => _pointsBalance;
  int get maxIllustrationsPerChapter => _maxIllustrationsPerChapter;
  bool get illustrationEnabled => _illustrationEnabled;

  Future<void> setMaxIllustrationsPerChapter(int value) async {
    final v = value.clamp(3, 5);
    if (_maxIllustrationsPerChapter == v) return;
    _maxIllustrationsPerChapter = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMaxIllustrationsPerChapter, v);
  }

  Future<void> setIllustrationEnabled(bool value) async {
    if (_illustrationEnabled == value) return;
    _illustrationEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kIllustrationEnabled, value);
  }

  Future<void> setPointsBalance(int value) async {
    final v = value < 0 ? 0 : value;
    if (_pointsBalance == v) return;
    _pointsBalance = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPointsBalance, v);
  }

  Future<void> addPoints(int delta) async {
    if (delta == 0) return;
    final next = _pointsBalance + delta;
    await setPointsBalance(next);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kModelSource);
    _source = AiModelSource.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => AiModelSource.none,
    );

    final localModelRaw = prefs.getString(_kLocalModelId);
    final candidate = localModelRaw != null && localModelRaw.trim().isNotEmpty
        ? localModelRaw.trim()
        : ModelManager.qwen3_0_6b;
    final supported =
        ModelManager.localModels.any((spec) => spec.id == candidate);
    _localModelId = supported ? candidate : ModelManager.qwen3_0_6b;
    if (!supported) {
      await prefs.setString(_kLocalModelId, _localModelId);
    }

    _pointsBalance = prefs.getInt(_kPointsBalance) ?? 0;
    _maxIllustrationsPerChapter =
        (prefs.getInt(_kMaxIllustrationsPerChapter) ?? 3).clamp(3, 5);
    _illustrationEnabled = prefs.getBool(_kIllustrationEnabled) ?? false;

    // 检查模型是否已安装
    await _checkModelInstallation();

    // 如果模型已安装，初始化 LLM 客户端
    if (_modelInstallStatus == ModelInstallStatus.installed) {
      await _initializeLlmClient();
    }

    notifyListeners();
  }

  /// 检查模型安装状态
  Future<void> _checkModelInstallation() async {
    final isInstalled = await ModelManager.isModelInstalled(_localModelId);
    if (isInstalled) {
      _modelInstallStatus = ModelInstallStatus.installed;
    } else {
      _modelInstallStatus = ModelInstallStatus.notInstalled;
    }
  }

  /// 初始化 LLM 客户端
  Future<void> _initializeLlmClient() async {
    // 使用适合平台的本地 LLM 客户端
    _llmClient = createLocalLlmClient();

    try {
      final success = await _llmClient!
          .initialize(
        model: _localModelId,
      )
          .timeout(
        const Duration(seconds: 60), // 增加到60秒，Qwen3-0.6B需要更长时间
        onTimeout: () {
          debugPrint('[AiModelProvider] LLM initialization timed out');
          return false;
        },
      );

      if (success) {
        debugPrint('[AiModelProvider] LLM initialized successfully');
      } else {
        debugPrint('[AiModelProvider] LLM initialization failed');
      }
    } catch (e) {
      debugPrint('[AiModelProvider] Failed to initialize LLM: $e');
    }

    notifyListeners();
  }

  /// 开始下载模型
  Future<void> startModelDownload() async {
    if (_modelInstallStatus == ModelInstallStatus.installing) {
      return;
    }

    _modelInstallStatus = ModelInstallStatus.installing;
    _downloadProgress = 0.0;
    _currentDownloadFile = '';
    notifyListeners();

    // 取消之前的订阅
    await _cancelSubscriptions();

    // 创建新的下载器
    _downloader = ModelManager.installModel(_localModelId);

    // 监听下载状态
    _statusSubscription = _downloader!.statusStream.listen((status) {
      switch (status) {
        case ModelDownloadStatus.completed:
          _modelInstallStatus = ModelInstallStatus.installed;
          _initializeLlmClient();
          break;
        case ModelDownloadStatus.failed:
          _modelInstallStatus = ModelInstallStatus.failed;
          break;
        case ModelDownloadStatus.notDownloaded:
          _modelInstallStatus = ModelInstallStatus.notInstalled;
          break;
        case ModelDownloadStatus.downloading:
        case ModelDownloadStatus.extracting:
          // 下载和解压中状态，保持安装中
          _modelInstallStatus = ModelInstallStatus.installing;
          break;
      }
      notifyListeners();
    });

    // 监听下载进度
    _progressSubscription = _downloader!.progressStream.listen((progress) {
      _downloadProgress = progress;
      notifyListeners();
    });

    // 监听当前下载文件
    _fileSubscription = _downloader!.currentFileStream.listen((fileName) {
      _currentDownloadFile = fileName;
      notifyListeners();
    });
  }

  /// 取消下载
  Future<void> cancelModelDownload() async {
    _downloader?.cancel();
    await _cancelSubscriptions();
    _modelInstallStatus = ModelInstallStatus.notInstalled;
    _downloadProgress = 0.0;
    notifyListeners();
  }

  /// 取消所有订阅
  Future<void> _cancelSubscriptions() async {
    await _statusSubscription?.cancel();
    await _progressSubscription?.cancel();
    await _fileSubscription?.cancel();
    _statusSubscription = null;
    _progressSubscription = null;
    _fileSubscription = null;
  }

  /// 删除已下载的模型
  Future<void> deleteModel() async {
    await _cancelSubscriptions();
    _downloader?.dispose();
    _downloader = null;

    await ModelManager.deleteModel(_localModelId);
    _llmClient?.dispose();
    _llmClient = null;
    _modelInstallStatus = ModelInstallStatus.notInstalled;
    _downloadProgress = 0.0;
    notifyListeners();
  }

  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async {
    if (_llmClient == null) {
      throw Exception('LLM client not initialized');
    }

    final response = await _llmClient!.generate(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
    );

    return response;
  }

  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    if (_llmClient == null) {
      throw Exception('LLM client not initialized');
    }

    yield* _llmClient!.generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    _downloader?.dispose();
    _llmClient?.dispose();
    super.dispose();
  }
}
