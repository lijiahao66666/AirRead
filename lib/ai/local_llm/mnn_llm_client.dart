import 'dart:async';
import 'package:flutter/foundation.dart';
import 'mnn_client.dart';
import 'llm_client.dart';
import 'model_manager.dart';

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
      return false;
    }

    // 检查并安装模型
    if (!await ModelManager.isModelInstalled()) {
      debugPrint('[LlmClientMnn] Installing model...');
      final installed = await ModelManager.installModel();
      if (!installed) {
        debugPrint('[LlmClientMnn] Failed to install model');
        return false;
      }
    }

    // 获取模型路径
    final modelPath = await ModelManager.getModelPath();
    if (modelPath == null) {
      return false;
    }

    final result = await _client.initialize(modelPath: modelPath);
    if (result) {
      _currentModel = model ?? 'minicpm4-0.5b-mnn';
    }
    return result;
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
