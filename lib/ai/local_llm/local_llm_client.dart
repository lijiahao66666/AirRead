import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LocalLlmClient {
  static const MethodChannel _channel = MethodChannel('airread/local_llm');

  String? _initializedModelPath;

  Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('isAvailable');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String> chatOnce({
    required String userText,
  }) async {
    final modelPath = await _resolveModelPath();
    await _ensureInitialized(modelPath);
    String? resp;
    try {
      resp = await _channel.invokeMethod<String>('chatOnce', {
        'modelPath': modelPath,
        'userText': userText,
      });
    } on MissingPluginException {
      throw PlatformException(
        code: 'LocalLlmNotAvailable',
        message: '本地推理暂不可用（当前平台未集成本地推理）',
      );
    }
    if (resp == null) {
      throw PlatformException(
        code: 'LocalLlmNullResponse',
        message: '本地推理返回为空',
      );
    }
    return resp;
  }

  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
  }) async {
    // Construct a prompt for translation
    final prompt =
        'Please translate the following text from $sourceLang to $targetLang:\n\n$text';
    return chatOnce(userText: prompt);
  }

  Future<String> _resolveModelPath() async {
    if (kIsWeb) {
      throw UnsupportedError('本地模型不支持在 Web 平台上运行');
    }
    final dir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(dir.path, 'models', 'hunyuan', 'model.mnn');
    final file = File(modelPath);
    if (!await file.exists()) {
      throw FileSystemException('本地模型文件不存在');
    }
    if (await file.length() <= 0) {
      throw FileSystemException('本地模型文件为空');
    }
    return modelPath;
  }

  Future<void> _ensureInitialized(String modelPath) async {
    if (_initializedModelPath == modelPath) return;
    try {
      await _channel.invokeMethod<void>('init', {
        'modelPath': modelPath,
      });
    } on MissingPluginException {
      throw PlatformException(
        code: 'LocalLlmNotAvailable',
        message: '本地推理暂不可用（当前平台未集成本地推理）',
      );
    }
    _initializedModelPath = modelPath;
  }
}
