import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum LocalLlmModelType {
  qa,
  translation,
}

class LocalLlmClient {
  static const MethodChannel _channel = MethodChannel('airread/local_llm');
  static const EventChannel _streamChannel =
      EventChannel('airread/local_llm_stream');

  static final _ConcurrencyGate _gate = _ConcurrencyGate(maxConcurrent: 1);

  static String? _initializedModelPath;
  static Future<void>? _initializing;
  static const int _defaultMaxNewTokens = 1024;
  static Future<String?>? _cachedDumpConfig;

  final LocalLlmModelType modelType;

  LocalLlmClient({
    this.modelType = LocalLlmModelType.qa,
  });

  Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('isAvailable');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String> dumpConfig() async {
    if (kIsWeb) {
      throw UnsupportedError('本地模型不支持在 Web 平台上运行');
    }
    final release = await _gate.acquire();
    try {
      final modelPath = await _resolveModelPath(modelType);
      await _ensureInitialized(modelPath);
      final out = await _channel.invokeMethod<String>('dumpConfig');
      return out ?? '';
    } on MissingPluginException {
      throw PlatformException(
        code: 'LocalLlmNotAvailable',
        message: '本地推理暂不可用（当前平台未集成本地推理）',
      );
    } finally {
      release();
    }
  }

  Future<int?> getMaxContextTokens() async {
    if (kIsWeb) return null;
    _cachedDumpConfig ??= () async {
      try {
        final s = await dumpConfig();
        return s.trim().isEmpty ? null : s;
      } catch (_) {
        return null;
      }
    }();
    final cfg = await _cachedDumpConfig;
    if (cfg == null || cfg.trim().isEmpty) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(cfg);
    } catch (_) {
      decoded = null;
    }

    int? found;
    if (decoded is Map) {
      found = _findFirstIntRecursive(decoded, {
        'max_seq_len',
        'maxSequenceLength',
        'max_sequence_length',
        'max_context_length',
        'context_length',
        'n_ctx',
        'max_position_embeddings',
        'seq_len',
      });
    }

    found ??= _findFirstIntByRegex(cfg, {
      'max_seq_len',
      'maxSequenceLength',
      'max_sequence_length',
      'max_context_length',
      'context_length',
      'n_ctx',
      'max_position_embeddings',
      'seq_len',
    });

    if (found == null || found <= 0) return null;
    return found;
  }

  int? _findFirstIntByRegex(String input, Set<String> keys) {
    for (final k in keys) {
      final reg = RegExp('"${RegExp.escape(k)}"\\s*:\\s*(\\d+)');
      final m = reg.firstMatch(input);
      if (m != null) {
        final v = int.tryParse(m.group(1) ?? '');
        if (v != null && v > 0) return v;
      }
    }
    return null;
  }

  int? _findFirstIntRecursive(Object? node, Set<String> keys) {
    if (node is Map) {
      for (final e in node.entries) {
        final k = e.key;
        if (k is String && keys.contains(k)) {
          final v = e.value;
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) {
            final parsed = int.tryParse(v.trim());
            if (parsed != null) return parsed;
          }
        }
      }
      for (final e in node.values) {
        final found = _findFirstIntRecursive(e, keys);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final e in node) {
        final found = _findFirstIntRecursive(e, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<String> chatOnce({
    required String userText,
    int maxNewTokens = _defaultMaxNewTokens,
    int maxInputTokens = 0,
    double? temperature,
    double? topP,
    int? topK,
    double? minP,
    double? presencePenalty,
    double? repetitionPenalty,
    bool? enableThinking,
  }) async {
    final release = await _gate.acquire();
    try {
      final modelPath = await _resolveModelPath(modelType);
      await _ensureInitialized(modelPath);
      final resp = await _channel.invokeMethod<String>('chatOnce', {
        'modelPath': modelPath,
        'userText': userText,
        'maxNewTokens': maxNewTokens,
        'maxInputTokens': maxInputTokens,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (minP != null) 'min_p': minP,
        if (presencePenalty != null) 'presence_penalty': presencePenalty,
        if (repetitionPenalty != null) 'repetition_penalty': repetitionPenalty,
        if (enableThinking != null) 'enable_thinking': enableThinking,
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
    double? temperature,
    double? topP,
    int? topK,
    double? minP,
    double? presencePenalty,
    double? repetitionPenalty,
    bool? enableThinking,
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
          final modelPath = await _resolveModelPath(modelType);
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

          await _channel.invokeMethod('chatStream', {
            'modelPath': modelPath,
            'userText': userText,
            'maxNewTokens': maxNewTokens,
            'maxInputTokens': maxInputTokens,
            if (temperature != null) 'temperature': temperature,
            if (topP != null) 'top_p': topP,
            if (topK != null) 'top_k': topK,
            if (minP != null) 'min_p': minP,
            if (presencePenalty != null) 'presence_penalty': presencePenalty,
            if (repetitionPenalty != null)
              'repetition_penalty': repetitionPenalty,
            if (enableThinking != null) 'enable_thinking': enableThinking,
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

  Future<String> _resolveModelPath(LocalLlmModelType modelType) async {
    if (kIsWeb) {
      throw UnsupportedError('本地模型不支持在 Web 平台上运行');
    }
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = switch (modelType) {
      LocalLlmModelType.qa => 'qa',
      LocalLlmModelType.translation => 'mt',
    };
    final modelPath =
        p.join(dir.path, 'models', 'hunyuan', modelDir, 'config.json');
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
    _cachedDumpConfig = null;
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
