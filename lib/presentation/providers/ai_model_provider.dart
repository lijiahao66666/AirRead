import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/local_llm/local_llm_client.dart';

enum AiModelSource {
  none,
  local,
  online,
}

class AiModelProvider extends ChangeNotifier {
  static const _kModelSource = 'ai_model_source';

  static const String localModelDownloadUrl =
      'https://www.modelscope.cn/models/Tencent-Hunyuan/Hunyuan-0.5B-Instruct-AWQ-Int4/resolve/master/model.safetensors';

  bool _loaded = false;
  AiModelSource _source = AiModelSource.none;

  bool _localModelExists = false;
  bool _localModelDownloading = false;
  bool _localModelPaused = false;
  double _localModelProgress = 0;
  String _localModelError = '';
  int _localModelDownloadedBytes = 0;
  int _localModelTotalBytes = 0;
  bool _localRuntimeAvailable = false;

  http.Client? _downloadClient;
  StreamSubscription<List<int>>? _downloadSub;
  IOSink? _downloadSink;

  AiModelProvider() {
    _load();
  }

  bool get loaded => _loaded;
  AiModelSource get source => _source;

  bool get isModelEnabled => _source != AiModelSource.none;

  bool get localModelExists => _localModelExists;
  bool get localModelDownloading => _localModelDownloading;
  bool get localModelPaused => _localModelPaused;
  double get localModelProgress => _localModelProgress;
  String get localModelError => _localModelError;
  int get localModelDownloadedBytes => _localModelDownloadedBytes;
  int get localModelTotalBytes => _localModelTotalBytes;
  bool get localRuntimeAvailable => _localRuntimeAvailable;

  bool get isLocalModelReady =>
      _localModelExists &&
      _localRuntimeAvailable &&
      !_localModelDownloading &&
      !_localModelPaused;

  @override
  void dispose() {
    _cancelDownload(isPause: false);
    super.dispose();
  }

  Future<void> setSource(AiModelSource value) async {
    if (_source == value) return;
    _source = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelSource, value.name);
  }

  Future<File> getLocalModelFile() async {
    if (kIsWeb) {
      // Web environment does not support path_provider in the same way.
      // We'll return a dummy file object that shouldn't be accessed.
      // Or better, logic using this should check kIsWeb first.
      throw UnsupportedError('Local model not supported on Web');
    }
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = Directory(p.join(dir.path, 'models', 'hunyuan'));
    return File(p.join(modelDir.path, 'model.mnn'));
  }

  Future<File> getLocalModelPartialFile() async {
    if (kIsWeb) throw UnsupportedError('Local model not supported on Web');
    final file = await getLocalModelFile();
    return File('${file.path}.partial');
  }

  Future<void> refreshLocalModelStatus() async {
    if (kIsWeb) {
      _localModelExists = false;
      notifyListeners();
      return;
    }
    final file = await getLocalModelFile();
    final exists = await file.exists();
    int size = 0;
    if (exists) {
      size = await file.length();
    }
    _localModelExists = exists && size > 0;
    if (_localModelExists) {
      _localModelError = '';
      _localModelProgress = 1;
      _localModelDownloadedBytes = size;
      _localModelTotalBytes = size;
    }
    notifyListeners();
  }

  Future<void> refreshLocalRuntimeStatus() async {
    final client = LocalLlmClient();
    _localRuntimeAvailable = await client.isAvailable();
    notifyListeners();
  }

  Future<void> startLocalModelDownload() async {
    if (_localModelDownloading) return;
    if (kIsWeb) {
      _localModelError = 'Web 端暂不支持下载本地模型';
      notifyListeners();
      return;
    }

    final targetFile = await getLocalModelFile();
    final partialFile = await getLocalModelPartialFile();

    if (await targetFile.exists()) {
      await refreshLocalModelStatus();
      return;
    }

    await targetFile.parent.create(recursive: true);

    int existing = 0;
    if (await partialFile.exists()) {
      existing = await partialFile.length();
    }

    _localModelDownloading = true;
    _localModelPaused = false;
    _localModelError = '';
    // If resuming, don't reset total bytes if we already knew it (though usually 0 on restart app)
    // But if we are starting fresh or resuming, existing bytes is correct.
    _localModelDownloadedBytes = existing;
    notifyListeners();

    _downloadClient?.close();
    _downloadClient = http.Client();

    try {
      final uri = Uri.parse(localModelDownloadUrl);
      final req = http.Request('GET', uri);
      if (existing > 0) {
        req.headers['Range'] = 'bytes=$existing-';
      }

      final resp = await _downloadClient!.send(req);

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('下载失败：HTTP ${resp.statusCode}');
      }

      final isPartial = resp.statusCode == 206;
      if (existing > 0 && !isPartial) {
        // Server didn't support range, restart
        await partialFile.delete().catchError((_) {});
        existing = 0;
        _localModelDownloadedBytes = 0;
      }

      final respLength = resp.contentLength ?? 0;
      _localModelTotalBytes = existing + respLength;
      notifyListeners();

      _downloadSink = partialFile.openWrite(mode: FileMode.append);
      _downloadSub = resp.stream.listen(
        (chunk) {
          _downloadSink?.add(chunk);
          _localModelDownloadedBytes += chunk.length;
          if (_localModelTotalBytes > 0) {
            _localModelProgress =
                _localModelDownloadedBytes / _localModelTotalBytes;
          }
          notifyListeners();
        },
        onDone: () async {
          await _downloadSink?.flush();
          await _downloadSink?.close();
          _downloadSink = null;
          _downloadSub = null;

          if (await targetFile.exists()) {
            await targetFile.delete().catchError((_) {});
          }
          await partialFile.rename(targetFile.path);
          _localModelDownloading = false;
          _localModelPaused = false;
          await refreshLocalModelStatus();
        },
        onError: (e) async {
          if (_localModelPaused) {
            _localModelDownloading = false;
            return;
          }
          await _downloadSink?.flush().catchError((_) {});
          await _downloadSink?.close().catchError((_) {});
          _downloadSink = null;
          _downloadSub = null;
          _localModelDownloading = false;
          _localModelPaused = false;
          _localModelError = _formatError(e);
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_localModelPaused) {
        _localModelDownloading = false;
        return;
      }
      _localModelDownloading = false;
      _localModelPaused = false;
      _localModelError = _formatError(e);
      notifyListeners();
    }
  }

  String _formatError(Object e) {
    final raw = '$e';
    if (raw.startsWith('HttpException: ')) {
      return raw.substring('HttpException: '.length);
    }
    if (raw.startsWith('ClientException: ')) {
      return raw.substring('ClientException: '.length);
    }
    return raw;
  }

  void pauseLocalModelDownload() {
    _cancelDownload(isPause: true);
  }

  void _cancelDownload({required bool isPause}) {
    bool changed = false;
    if (_localModelDownloading) {
      _localModelDownloading = false;
      if (isPause) {
        _localModelPaused = true;
      } else {
        _localModelPaused = false;
      }
      changed = true;
    }

    try {
      _downloadSub?.cancel().catchError((_) {});
    } catch (_) {}
    _downloadSub = null;

    try {
      _downloadClient?.close();
    } catch (_) {}
    _downloadClient = null;

    try {
      _downloadSink?.flush().catchError((_) {});
      _downloadSink?.close().catchError((_) {});
    } catch (_) {}
    _downloadSink = null;

    if (changed) {
      notifyListeners();
    }
  }

  // Deprecated: use pauseLocalModelDownload or specific cancel method
  void stopLocalModelDownload() {
    pauseLocalModelDownload();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kModelSource);
    _source = AiModelSource.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => AiModelSource.none,
    );
    _loaded = true;
    await refreshLocalModelStatus();
    await refreshLocalRuntimeStatus();
    notifyListeners();
  }
}
