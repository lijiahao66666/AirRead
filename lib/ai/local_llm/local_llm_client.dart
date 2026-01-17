import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LocalLlmClient {
  static const MethodChannel _channel = MethodChannel('airread/local_llm');
  static const EventChannel _streamChannel =
      EventChannel('airread/local_llm_stream');

  static final _ConcurrencyGate _gate = _ConcurrencyGate(maxConcurrent: 1);

  static String? _initializedModelPath;
  static Future<void>? _initializing;
  static const int _defaultMaxNewTokens = 1024;

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
    int maxNewTokens = _defaultMaxNewTokens,
    int maxInputTokens = 0,
  }) async {
    final release = await _gate.acquire();
    try {
      final modelPath = await _resolveModelPath();
      await _ensureInitialized(modelPath);
      final resp = await _channel.invokeMethod<String>('chatOnce', {
        'modelPath': modelPath,
        'userText': userText,
        'maxNewTokens': maxNewTokens,
        'maxInputTokens': maxInputTokens,
      });
      if (resp == null) {
        throw PlatformException(
          code: 'LocalLlmNullResponse',
          message: '本地推理返回为空',
        );
      }
      return resp;
    } on MissingPluginException {
      throw PlatformException(
        code: 'LocalLlmNotAvailable',
        message: '本地推理暂不可用（当前平台未集成本地推理）',
      );
    } finally {
      release();
    }
  }

  Stream<String> chatStream({
    required String userText,
    int maxNewTokens = _defaultMaxNewTokens,
    int maxInputTokens = 0,
  }) {
    if (kIsWeb) {
      return Stream.error(UnsupportedError('本地模型不支持在 Web 平台上运行'));
    }

    late final StreamController<String> controller;
    StreamSubscription<dynamic>? sub;
    void Function()? release;
    bool closed = false;

    Future<void> closeSafely([Object? error, StackTrace? st]) async {
      if (closed) return;
      closed = true;
      try {
        await sub?.cancel();
      } catch (_) {}
      if (error != null) {
        try {
          controller.addError(error, st);
        } catch (_) {}
      }
      try {
        await controller.close();
      } catch (_) {}
      release?.call();
    }

    controller = StreamController<String>(
      onListen: () async {
        try {
          release = await _gate.acquire();
          if (closed) {
            release?.call();
            release = null;
            return;
          }
          final modelPath = await _resolveModelPath();
          if (closed) {
            release?.call();
            release = null;
            return;
          }
          await _ensureInitialized(modelPath);
          if (closed) {
            release?.call();
            release = null;
            return;
          }

          sub = _streamChannel.receiveBroadcastStream().listen(
            (event) {
              if (closed) return;
              if (event is Map) {
                final type = event['type'];
                if (type == 'chunk') {
                  final data = event['data'];
                  if (data is String && data.isNotEmpty) {
                    try {
                      controller.add(data);
                    } catch (_) {}
                  }
                } else if (type == 'done') {
                  closeSafely();
                } else if (type == 'error') {
                  final message = event['message'];
                  closeSafely(
                    PlatformException(
                      code: 'LocalLlmStreamError',
                      message: message is String ? message : '本地推理流式输出失败',
                    ),
                  );
                }
              } else if (event is String) {
                if (event.isNotEmpty) {
                  try {
                    controller.add(event);
                  } catch (_) {}
                }
              }
            },
            onError: (e) {
              closeSafely(e);
            },
          );

          await _channel.invokeMethod<void>('chatStream', {
            'modelPath': modelPath,
            'userText': userText,
            'maxNewTokens': maxNewTokens,
            'maxInputTokens': maxInputTokens,
          });
        } on MissingPluginException {
          await closeSafely(
            PlatformException(
              code: 'LocalLlmNotAvailable',
              message: '本地推理暂不可用（当前平台未集成本地推理）',
            ),
          );
        } catch (e) {
          await closeSafely(e);
        }
      },
      onCancel: () async {
        try {
          await _channel.invokeMethod<void>('cancelChatStream');
        } catch (_) {}
        await closeSafely();
      },
    );

    return controller.stream;
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
    final modelPath = p.join(dir.path, 'models', 'hunyuan', 'config.json');
    final file = File(modelPath);
    if (!await file.exists()) {
      throw const FileSystemException('本地模型文件不存在');
    }
    if (await file.length() <= 0) {
      throw const FileSystemException('本地模型文件为空');
    }
    return modelPath;
  }

  Future<void> _ensureInitialized(String modelPath) async {
    if (_initializedModelPath == modelPath) return;
    if (_initializing != null) {
      await _initializing;
      if (_initializedModelPath == modelPath) return;
    }
    final future = _init(modelPath);
    _initializing = future;
    try {
      await future;
      _initializedModelPath = modelPath;
    } finally {
      if (identical(_initializing, future)) {
        _initializing = null;
      }
    }
  }

  Future<void> _init(String modelPath) async {
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
  }
}

class _ConcurrencyGate {
  final int maxConcurrent;
  final Queue<Completer<void Function()>> _waiters = Queue();
  int _active = 0;

  _ConcurrencyGate({required this.maxConcurrent}) : assert(maxConcurrent >= 1);

  Future<void Function()> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value(_release);
    }
    final c = Completer<void Function()>();
    _waiters.addLast(c);
    return c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      next.complete(_release);
      return;
    }
    _active--;
  }
}
