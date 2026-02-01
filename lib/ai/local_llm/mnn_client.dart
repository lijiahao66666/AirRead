import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'model_manager.dart';

class MnnClient {
  static const MethodChannel _channel = MethodChannel('airread/mnn_llm');
  static const EventChannel _eventChannel = EventChannel('airread/mnn_llm_events');

  bool _isInitialized = false;
  String? _modelPath;

  MnnClient();

  bool get isAvailable => _isInitialized;
  String? get modelPath => _modelPath;

  static Future<bool> isPlatformAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } catch (e) {
      debugPrint('[MnnClient] isPlatformAvailable error: $e');
      return false;
    }
  }

  Future<bool> initialize({required String modelPath}) async {
    try {
      final result = await _channel.invokeMethod<bool>('initialize', {
        'modelPath': modelPath,
      });

      if (result == true) {
        _isInitialized = true;
        _modelPath = modelPath;
        return true;
      } else {
        _isInitialized = false;
        return false;
      }
    } on PlatformException catch (e) {
      debugPrint('[MnnClient] initialize error: ${e.message}');
      _isInitialized = false;
      return false;
    } catch (e) {
      debugPrint('[MnnClient] initialize unexpected error: $e');
      _isInitialized = false;
      return false;
    }
  }

  Future<String?> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.05,
    double presencePenalty = 0.0,
    double repetitionPenalty = 1.0,
    bool enableThinking = false,
  }) async {
    if (!_isInitialized) {
      throw Exception('MNN client not initialized');
    }

    try {
      final result = await _channel.invokeMethod<String>('chatOnce', {
        'userText': prompt,
        'maxNewTokens': maxTokens,
        'maxInputTokens': 2048,
        'temperature': temperature,
        'topP': topP,
        'topK': topK,
        'minP': minP,
        'presencePenalty': presencePenalty,
        'repetitionPenalty': repetitionPenalty,
        'enableThinking': enableThinking,
      });

      return result;
    } on PlatformException catch (e) {
      debugPrint('[MnnClient] generate error: ${e.message}');
      throw Exception('Failed to generate: ${e.message}');
    }
  }

  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.05,
    double presencePenalty = 0.0,
    double repetitionPenalty = 1.0,
    bool enableThinking = false,
  }) async* {
    if (!_isInitialized) {
      throw Exception('MNN client not initialized');
    }

    final completer = Completer<void>();
    final controller = StreamController<String>();

    try {
      await _channel.invokeMethod('chatStream', {
        'userText': prompt,
        'maxNewTokens': maxTokens,
        'maxInputTokens': 2048,
        'temperature': temperature,
        'topP': topP,
        'topK': topK,
        'minP': minP,
        'presencePenalty': presencePenalty,
        'repetitionPenalty': repetitionPenalty,
        'enableThinking': enableThinking,
      });

      // 监听事件通道
      _eventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is Map) {
            final type = event['type'] as String?;
            if (type == 'chunk') {
              final chunk = event['data'] as String?;
              if (chunk != null && chunk.isNotEmpty) {
                controller.add(chunk);
              }
            } else if (type == 'done') {
              controller.close();
              completer.complete();
            } else if (type == 'error') {
              final errorMsg = event['error'] as String? ?? 'Unknown error';
              controller.addError(Exception(errorMsg));
              controller.close();
              completer.completeError(Exception(errorMsg));
            }
          }
        },
        onError: (dynamic error) {
          controller.addError(error);
          controller.close();
          completer.completeError(error);
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      yield* controller.stream;
    } catch (e) {
      controller.close();
      throw Exception('Failed to start stream: $e');
    }
  }

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (e) {
      debugPrint('[MnnClient] cancel error: $e');
    }
  }

  Future<String?> dumpConfig() async {
    if (!_isInitialized) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<String>('dumpConfig');
      return result;
    } catch (e) {
      debugPrint('[MnnClient] dumpConfig error: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    _isInitialized = false;
    _modelPath = null;
  }
}
