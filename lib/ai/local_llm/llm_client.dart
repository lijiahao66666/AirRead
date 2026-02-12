import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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
    // - model 为空：使用默认模型
    // - model 是绝对路径：直接使用
    // - 否则认为是模型 id：从 ModelManager 获取对应模型目录
    String? modelPath;
    if (model == null) {
      modelPath = await _getDefaultModelPath();
    } else if (p.isAbsolute(model)) {
      modelPath = model;
    } else {
      modelPath = await ModelManager.getModelPath(model);
    }

    if (modelPath == null) {
      debugPrint('[LlmClientMnn] Model path is null');
      return false;
    }

    debugPrint('[LlmClientMnn] Initializing with modelPath: $modelPath');

    // Debug: Check model files
    try {
      final dir = Directory(modelPath);
      debugPrint('[LlmClientMnn] Checking model directory: ${dir.path}');
      if (await dir.exists()) {
        /*
        final files = await dir.list().toList();
        debugPrint('[LlmClientMnn] Model directory contents (${files.length} files):');
        for (final file in files) {
          if (file is File) {
            final size = await file.length();
            debugPrint('  - ${file.path.split('/').last}: $size bytes');
          } else {
            debugPrint('  - ${file.path.split('/').last} (Dir)');
          }
        }
        */

        // Check specific required files
        final requiredFiles = ['config.json', 'llm.mnn', 'tokenizer.txt'];
        for (var f in requiredFiles) {
          final file = File('${dir.path}/$f');
          if (!await file.exists()) {
            debugPrint(
                '[LlmClientMnn] CRITICAL ERROR: Required file missing: $f');
          } else {
            final size = await file.length();
            if (size == 0)
              debugPrint('[LlmClientMnn] CRITICAL ERROR: File empty: $f');
          }
        }
      } else {
        debugPrint(
            '[LlmClientMnn] CRITICAL ERROR: Model directory does not exist!');
      }
    } catch (e) {
      debugPrint('[LlmClientMnn] Error checking model files: $e');
    }

    final result = await _client.initialize(modelPath: modelPath);
    if (result) {
      _currentModel = model ?? ModelManager.qwen2_5_1_5b;
      debugPrint('[LlmClientMnn] Initialization successful');
    } else {
      debugPrint('[LlmClientMnn] Initialization failed');
    }
    return result;
  }

  Future<String?> _getDefaultModelPath() async {
    final modelPath = await ModelManager.getModelPath(ModelManager.qwen2_5_1_5b);
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
