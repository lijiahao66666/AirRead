import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MnnClient {
  static const MethodChannel _channel = MethodChannel('airread/local_llm');
  static const EventChannel _eventChannel =
      EventChannel('airread/local_llm_stream');

  bool _isInitialized = false;
  String? _modelPath;

  MnnClient();

  bool get isAvailable => _isInitialized;
  String? get modelPath => _modelPath;

  void _debugLogModelInput({
    required String where,
    required String prompt,
  }) {
    if (!kDebugMode) return;
    final trimmed = prompt.trimRight();
    const tailLen = 160;
    final tail = trimmed.length <= tailLen
        ? trimmed
        : trimmed.substring(trimmed.length - tailLen);
    debugPrint(
      '[MnnClient][$where] modelPath=$_modelPath inLen=${trimmed.length} inTail=${jsonEncode(tail)}',
    );
  }

  static Future<bool> isPlatformAvailable() async {
    // 桌面端暂时返回 true 以支持开发测试（使用模拟实现或通过插件支持）
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return true;
    }
    try {
      final isAvailable = await _channel.invokeMethod<bool>('isAvailable');
      if (isAvailable == false && Platform.isAndroid) {
        final error = await _channel.invokeMethod<String>('getNativeLoadError');
        if (error != null) {
          debugPrint('[MnnClient] MNN not available due to: $error');
        }
      }
      return isAvailable ?? false;
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
  }) async {
    if (!_isInitialized) {
      throw Exception('MNN client not initialized');
    }

    try {
      _debugLogModelInput(
        where: 'chatOnce',
        prompt: prompt,
      );
      final result = await _channel.invokeMethod<String>('chatOnce', {
        'userText': prompt,
      });

      if (kDebugMode && result != null) {
        final trimmed = result.trimRight();
        const tailLen = 200;
        final tail = trimmed.length <= tailLen
            ? trimmed
            : trimmed.substring(trimmed.length - tailLen);
        debugPrint(
          '[MnnClient][chatOnce] outLen=${trimmed.length} outTail=${jsonEncode(tail)}',
        );
      }
      return result;
    } on PlatformException catch (e) {
      debugPrint('[MnnClient] generate error: ${e.message}');
      throw Exception('Failed to generate: ${e.message}');
    }
  }

  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
  }) async* {
    if (!_isInitialized) {
      throw Exception('MNN client not initialized');
    }

    final controller = StreamController<String>();
    final decoderSink = utf8.decoder.startChunkedConversion(controller);
    StreamSubscription? subscription;

    controller.onCancel = () {
      debugPrint('MnnClient: Controller cancelled, cancelling subscription');
      subscription?.cancel();
      decoderSink.close();
      cancel();
    };

    try {
      // 1. 先监听事件通道，确保 streamSink 已准备好
      subscription = _eventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is Map) {
            final type = event['type'] as String?;
            if (type == 'chunk') {
              final data = event['data'];
              if (data is String) {
                if (data.isNotEmpty) {
                  controller.add(data);
                }
              } else if (data is Uint8List) {
                if (data.isNotEmpty) {
                  decoderSink.add(data);
                }
              }
            } else if (type == 'done') {
              debugPrint('MnnClient: Stream done');
              subscription?.cancel();
              decoderSink.close();
            } else if (type == 'error') {
              final msg = event['data'] as String? ?? 'Unknown error';
              debugPrint('MnnClient: Stream error: $msg');
              subscription?.cancel();
              controller.addError(msg);
              decoderSink.close();
            }
          }
        },
        onError: (dynamic error) {
          debugPrint('MnnClient: EventChannel error: $error');
          subscription?.cancel();
          controller.addError(error);
          decoderSink.close();
        },
        onDone: () {
          debugPrint('MnnClient: EventChannel done');
          decoderSink.close();
        },
      );

      // 2. 再调用 native 启动生成
      _debugLogModelInput(
        where: 'chatStream',
        prompt: prompt,
      );
      await _channel.invokeMethod('chatStream', {
        'userText': prompt,
      });

      yield* controller.stream;
    } catch (e) {
      debugPrint('MnnClient: invokeMethod error: $e');
      subscription?.cancel();
      controller.close();
      throw Exception('Failed to start stream: $e');
    } finally {
      await subscription?.cancel();
    }
  }

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancelChatStream');
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
    try {
      await cancel();
    } catch (_) {}
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
    _isInitialized = false;
    _modelPath = null;
  }
}
