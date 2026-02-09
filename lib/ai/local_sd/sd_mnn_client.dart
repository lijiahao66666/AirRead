import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../local_llm/model_manager.dart';
import '../local_llm/mnn_model_downloader.dart';

class SdMnnClient {
  static const MethodChannel _channel = MethodChannel('airread/local_sd');
  static Future<void>? _initFuture;

  static Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('isAvailable');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> ensureInitialized() async {
    if (kIsWeb) throw StateError('Local SD is not supported on web');
    return await (_initFuture ??= _initializeOnce());
  }

  static Future<void> _initializeOnce() async {
    final dir = await MnnModelDownloader(spec: ModelManager.sdV15Spec).getModelDir();
    await _channel.invokeMethod('initialize', {'modelDir': dir});
  }

  static Future<String> txt2img({
    required String prompt,
    int width = 512,
    int height = 512,
    int steps = 20,
    int seed = -1,
    double guidance = 7.5,
  }) async {
    await ensureInitialized();
    final out = await _channel.invokeMethod<String>('txt2img', {
      'prompt': prompt,
      'width': width,
      'height': height,
      'steps': steps,
      'seed': seed,
      'guidance': guidance,
    });
    if (out == null || out.trim().isEmpty) {
      throw StateError('txt2img returned empty path');
    }
    return out;
  }
}

