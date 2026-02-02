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

enum QAContentScope {
  currentPage,
  currentChapterToPage,
  slidingWindow,
}

enum ModelInstallStatus {
  notInstalled,
  installing,
  installed,
  failed,
}

class AiModelProvider extends ChangeNotifier {
  static const String _kModelSource = 'ai_model_source';
  static const String _kQAContentScope = 'qa_content_scope';
  static const String _kPointsBalance = 'points_balance';

  LlmClient? _llmClient;
  AiModelSource _source = AiModelSource.none;
  QAContentScope _qaContentScope = QAContentScope.slidingWindow;
  int _pointsBalance = 0;

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

  QAContentScope get qaContentScope => _qaContentScope;
  bool get loaded => _llmClient != null && _llmClient!.isAvailable;
  AiModelSource get source => _source;
  bool get isModelEnabled => _source != AiModelSource.none;

  // 模型安装相关 getter
  ModelInstallStatus get modelInstallStatus => _modelInstallStatus;
  double get downloadProgress => _downloadProgress;
  String get currentDownloadFile => _currentDownloadFile;
  bool get isModelInstalled => _modelInstallStatus == ModelInstallStatus.installed;
  bool get isDownloading => _modelInstallStatus == ModelInstallStatus.installing;

  Future<void> setSource(AiModelSource value) async {
    if (_source == value) return;
    _source = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelSource, value.name);
  }

  Future<void> setQAContentScope(QAContentScope value) async {
    if (_qaContentScope == value) return;
    _qaContentScope = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQAContentScope, value.name);
  }

  int get pointsBalance => _pointsBalance;

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

    final scopeRaw = prefs.getString(_kQAContentScope);
    _qaContentScope = QAContentScope.values.firstWhere(
      (e) => e.name == scopeRaw,
      orElse: () => QAContentScope.slidingWindow,
    );

    _pointsBalance = prefs.getInt(_kPointsBalance) ?? 0;

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
    final isInstalled = await ModelManager.isModelInstalled();
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
      final success = await _llmClient!.initialize(
        model: 'qwen3-0.6b-mnn',
      ).timeout(
        const Duration(seconds: 60),  // 增加到60秒，Qwen3-0.6B需要更长时间
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
    _downloader = ModelManager.installModel();

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

    await ModelManager.deleteModel();
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
