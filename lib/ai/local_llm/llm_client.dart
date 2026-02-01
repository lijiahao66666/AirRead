import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ollama_client.dart';
import 'ollama_model_downloader.dart';
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
  });

  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  });

  Future<void> dispose();
}

class LlmClientOllama implements LlmClient {
  final OllamaClient _client = OllamaClient();

  @override
  bool get isAvailable => _client.isAvailable;

  @override
  String? get currentModel => _client.currentModel;

  @override
  Future<bool> initialize({String? model}) async {
    return await _client.initialize(model: model);
  }

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async {
    return await _client.generate(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  @override
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    yield* _client.generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  @override
  Future<void> dispose() async {
    await _client.dispose();
  }
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
    // 检查平台是否支持 MNN
    final platformAvailable = await MnnClient.isPlatformAvailable();
    if (!platformAvailable) {
      debugPrint('[LlmClientMnn] Platform not available');
      return false;
    }

    // 获取模型路径
    // 如果传入的 model 是相对路径（如 'minicpm4-0.5b-mnn'），则获取完整路径
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
      _currentModel = model ?? 'minicpm4-0.5b-mnn';
      debugPrint('[LlmClientMnn] Initialization successful');
    } else {
      debugPrint('[LlmClientMnn] Initialization failed');
    }
    return result;
  }

  Future<String?> _getDefaultModelPath() async {
    // 默认模型路径：应用文档目录下的 models/minicpm4-0.5b-mnn
    final modelPath = await ModelManager.getModelPath();
    return modelPath;
  }

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async {
    final result = await _client.generate(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
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
  }) async* {
    yield* _client.generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  @override
  Future<void> dispose() async {
    await _client.dispose();
  }
}

/// 创建适合当前平台的本地 LLM 客户端
LlmClient createLocalLlmClient() {
  if (Platform.isIOS) {
    // iOS 使用 MNN
    return LlmClientMnn();
  } else {
    // Android 和其他平台使用 Ollama
    return LlmClientOllama();
  }
}
