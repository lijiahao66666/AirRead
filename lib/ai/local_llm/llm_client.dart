import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'mnn_client.dart';
import 'model_manager.dart';

abstract class LlmClient {
  bool get isAvailable;
  String? get currentModel;

  Future<bool> initialize({String? model});
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.0,
    double repetitionPenalty = 1.1,
  });

  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.0,
    double repetitionPenalty = 1.1,
  });

  Future<void> dispose();
}

class LlmClientMnn implements LlmClient {
  final MnnClient _client = MnnClient();
  String? _currentModel;

  @override
  bool get isAvailable => _client.isAvailable;

  @override
  String? get currentModel => _currentModel;

  @override
  Future<bool> initialize({String? model}) async {
    // 如果已经初始化了相同的模型，则跳过
    if (_client.isAvailable && (_currentModel == model || model == null)) {
      debugPrint(
          '[LlmClientMnn] Already initialized with model: $_currentModel');
      return true;
    }

    // 检查平台是否支持 MNN
    final platformAvailable = await MnnClient.isPlatformAvailable();
    if (!platformAvailable) {
      debugPrint('[LlmClientMnn] Platform not available');
      return false;
    }

    // 获取模型路径
    // 如果传入的 model 是相对路径（如 'qwen3-0.6b-mnn'），则获取完整路径
    // 如果传入的 model 已经是完整路径，则直接使用
    String? modelPath;
    if (model == null) {
      modelPath = await _getDefaultModelPath();
    } else if (model.startsWith('/')) {
      // 已经是完整路径
      modelPath = model;
    } else {
      // 是相对路径，获取完整路径
      modelPath = await ModelManager.getModelPath();
    }

    if (modelPath == null) {
      debugPrint('[LlmClientMnn] Model path is null');
      return false;
    }

    debugPrint('[LlmClientMnn] Initializing with modelPath: $modelPath');

    final result = await _client.initialize(modelPath: modelPath);
    if (result) {
      _currentModel = model ?? 'qwen3-0.6b-mnn';
      debugPrint('[LlmClientMnn] Initialization successful');
    } else {
      debugPrint('[LlmClientMnn] Initialization failed');
    }
    return result;
  }

  Future<String?> _getDefaultModelPath() async {
    // 默认模型路径：应用文档目录下的 models/qwen3-0.6b-mnn
    final modelPath = await ModelManager.getModelPath();
    return modelPath;
  }

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.0,
    double repetitionPenalty = 1.1,
  }) async {
    final result = await _client.generate(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      repetitionPenalty: repetitionPenalty,
    );

    if (result == null) {
      throw Exception('MNN generation returned null');
    }

    return result;
  }

  @override
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.0,
    double repetitionPenalty = 1.1,
  }) async* {
    yield* _client.generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      repetitionPenalty: repetitionPenalty,
    );
  }

  @override
  Future<void> dispose() async {
    await _client.dispose();
  }
}

/// 创建适合当前平台的本地 LLM 客户端
LlmClient createLocalLlmClient() {
  if (Platform.isIOS || Platform.isAndroid) {
    // iOS 和 Android 使用 MNN
    return LlmClientMnn();
  } else {
    // 其他平台暂不支持
    throw UnsupportedError('Local LLM is only supported on iOS and Android.');
  }
}
