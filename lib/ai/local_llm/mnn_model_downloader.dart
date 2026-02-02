import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// MNN 模型下载状态
enum ModelDownloadStatus {
  notDownloaded,
  downloading,
  extracting,
  completed,
  failed,
}

/// MNN 模型下载器
/// 从 ModelScope 下载 Qwen3-0.6B MNN 模型（直接下载文件）
class MnnModelDownloader {
  static const String _modelDir = 'models/qwen3-0.6b-mnn';
  
  // ModelScope 基础URL
  static const String _baseUrl = 'https://modelscope.cn/models/MNN/Qwen3-0.6B-MNN/resolve/master/';

  // 预估总大小约455MB
  static const int estimatedTotalSize = 455 * 1024 * 1024;

  // 需要下载的文件列表
  static final List<String> _filesToDownload = [
    'config.json',
    'llm_config.json',
    'llm.mnn',
    'llm.mnn.weight',
    'tokenizer.txt',
  ];

  // 必需的关键文件（用于检查是否已安装）
  static final List<String> _criticalFiles = [
    'llm.mnn',
    'llm.mnn.weight',
    'tokenizer.txt',
    'config.json',
  ];

  // 下载状态流
  final _statusController = StreamController<ModelDownloadStatus>.broadcast();
  final _progressController = StreamController<double>.broadcast();
  final _currentFileController = StreamController<String>.broadcast();

  Stream<ModelDownloadStatus> get statusStream => _statusController.stream;
  Stream<double> get progressStream => _progressController.stream;
  Stream<String> get currentFileStream => _currentFileController.stream;

  ModelDownloadStatus _status = ModelDownloadStatus.notDownloaded;
  double _progress = 0.0;
  String _currentFile = '';
  http.Client? _httpClient;
  bool _cancelled = false;

  ModelDownloadStatus get status => _status;
  double get progress => _progress;
  String get currentFile => _currentFile;

  static const int _defaultMaxAttemptsPerFile = 0;
  static const Duration _defaultInitialBackoff = Duration(milliseconds: 800);
  static const Duration _defaultMaxBackoff = Duration(seconds: 30);
  static const Duration _defaultRequestTimeout = Duration(minutes: 20);

  /// 获取模型目录路径
  static Future<String> getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, _modelDir);
  }

  /// 检查模型是否已下载
  static Future<bool> isModelDownloaded() async {
    try {
      final modelDir = await getModelDir();
      final dir = Directory(modelDir);

      if (!await dir.exists()) {
        return false;
      }

      // 检查所有必需文件是否存在
      for (final fileName in _criticalFiles) {
        final filePath = p.join(modelDir, fileName);
        final f = File(filePath);
        if (!await f.exists()) {
          debugPrint('[MnnModelDownloader] Missing critical file: $fileName');
          return false;
        }
        final minBytes = _minExpectedBytes(fileName);
        if (minBytes != null) {
          final size = await f.length();
          if (size < minBytes) {
            debugPrint('[MnnModelDownloader] Critical file too small: $fileName size=$size min=$minBytes');
            return false;
          }
        }
      }

      // 检查 config.json 是否存在
      // 但为了 isModelInstalled 返回 true，我们需要确保 config.json 存在
      final configPath = p.join(modelDir, 'config.json');
      if (!await File(configPath).exists()) {
         // 尝试修复：如果 llm_config.json 存在，复制一份
         final llmConfigPath = p.join(modelDir, 'llm_config.json');
         if (await File(llmConfigPath).exists()) {
           try {
             await File(llmConfigPath).copy(configPath);
             debugPrint('[MnnModelDownloader] Auto-created config.json from llm_config.json');
           } catch (e) {
             debugPrint('[MnnModelDownloader] Failed to create config.json: $e');
             return false;
           }
         } else {
           debugPrint('[MnnModelDownloader] Missing config.json and llm_config.json');
           return false;
         }
      }

      return true;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Error checking model: $e');
      return false;
    }
  }

  /// 获取已下载的文件大小
  static Future<int> getDownloadedSize() async {
    try {
      final modelDir = await getModelDir();
      int totalSize = 0;

      for (final fileName in _filesToDownload) {
        final filePath = p.join(modelDir, fileName);
        final file = File(filePath);
        if (await file.exists()) {
          totalSize += await file.length();
        }
      }

      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// 开始下载模型
  Future<bool> download() async {
    if (_status == ModelDownloadStatus.downloading ||
        _status == ModelDownloadStatus.extracting) {
      return false;
    }

    _status = ModelDownloadStatus.downloading;
    _statusController.add(_status);
    _cancelled = false;
    _httpClient = http.Client();

    try {
      final modelDir = await getModelDir();

      // 创建目录
      final dir = Directory(modelDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 逐个下载文件
      for (final fileName in _filesToDownload) {
        if (_cancelled) break;
        
        _currentFile = fileName;
        _currentFileController.add(_currentFile);
        
        final filePath = p.join(modelDir, fileName);
        
        // 如果文件已存在且大小匹配（这里很难预知大小，所以简单覆盖或者跳过）
        // 为确保完整性，我们选择覆盖下载
        
        final success = await _downloadSingleFileWithRetry(
          fileName, 
          filePath, 
          (bytes) {
             // 临时方案：如果正在下载 weight，进度有效；其他文件瞬间完成
             if (fileName == 'llm.mnn.weight') {
               _progress = bytes / (450 * 1024 * 1024); // 约450MB
               if (_progress > 1.0) _progress = 1.0;
               _progressController.add(_progress);
             }
          }
        );
        
        if (!success) {
          _status = ModelDownloadStatus.failed;
          _statusController.add(_status);
          return false;
        }
      }

      if (_cancelled) {
        _status = ModelDownloadStatus.notDownloaded;
        _statusController.add(_status);
        return false;
      }

      _status = ModelDownloadStatus.completed;
      _statusController.add(_status);
      _progress = 1.0;
      _progressController.add(1.0);
      return true;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Download error: $e');
      _status = ModelDownloadStatus.failed;
      _statusController.add(_status);
      return false;
    } finally {
      _httpClient?.close();
      _httpClient = null;
    }
  }

  Future<bool> _downloadSingleFileWithRetry(
    String fileName,
    String savePath,
    Function(int receivedTotal) onProgress,
  ) async {
    int attempt = 0;
    Duration backoff = _defaultInitialBackoff;
    while (!_cancelled) {
      attempt++;

      final existingBytes = await _safeFileLength(savePath);
      final res = await _downloadSingleFileOnce(
        fileName: fileName,
        savePath: savePath,
        existingBytes: existingBytes,
        onProgress: onProgress,
      );

      if (res == _DownloadResult.success) return true;
      if (res == _DownloadResult.cancelled) return false;
      if (res == _DownloadResult.fatal) return false;

      if (_defaultMaxAttemptsPerFile > 0 && attempt >= _defaultMaxAttemptsPerFile) {
        return false;
      }

      await Future<void>.delayed(backoff + _jitter(backoff));
      backoff = _nextBackoff(backoff);
    }
    return false;
  }

  Duration _nextBackoff(Duration current) {
    final nextMs = (current.inMilliseconds * 2).clamp(
      _defaultInitialBackoff.inMilliseconds,
      _defaultMaxBackoff.inMilliseconds,
    );
    return Duration(milliseconds: nextMs);
  }

  Duration _jitter(Duration base) {
    final ms = base.inMilliseconds;
    if (ms <= 0) return Duration.zero;
    final jitter = (ms * 0.2).round();
    final now = DateTime.now().microsecondsSinceEpoch;
    final r = (now % (jitter * 2 + 1)) - jitter;
    return Duration(milliseconds: r);
  }

  static Future<int> _safeFileLength(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// 下载单个文件
  Future<_DownloadResult> _downloadSingleFileOnce({
    required String fileName,
    required String savePath,
    required int existingBytes,
    required Function(int receivedTotal) onProgress,
  }) async {
    final client = _httpClient;
    if (client == null) return _DownloadResult.retryable;

    final url = '$_baseUrl$fileName';
    debugPrint('[MnnModelDownloader] Downloading $fileName from $url');

    http.StreamedResponse response;
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'AirRead/1.0';
      if (existingBytes > 0) {
        request.headers['Range'] = 'bytes=$existingBytes-';
      }

      response = await client.send(request).timeout(
        _defaultRequestTimeout,
        onTimeout: () {
          throw TimeoutException('Download timeout for $fileName');
        },
      );
    } catch (e) {
      if (_cancelled) return _DownloadResult.cancelled;
      if (_isRetryableException(e)) return _DownloadResult.retryable;
      return _DownloadResult.fatal;
    }

    if (_cancelled) return _DownloadResult.cancelled;

    if (response.statusCode != 200 && response.statusCode != 206) {
      debugPrint('[MnnModelDownloader] Failed to download $fileName: ${response.statusCode}');
      if (_isRetryableStatusCode(response.statusCode)) return _DownloadResult.retryable;
      return _DownloadResult.fatal;
    }

    final file = File(savePath);
    int startOffset = 0;
    bool append = false;

    if (response.statusCode == 206 && existingBytes > 0) {
      startOffset = existingBytes;
      append = true;
    } else if (existingBytes > 0 && response.statusCode == 200) {
      try {
        await file.writeAsBytes(const [], mode: FileMode.write);
      } catch (_) {}
      startOffset = 0;
      append = false;
    }

    final totalBytes = _totalBytesFromResponse(response);
    final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
    int receivedBytes = 0;

    try {
      await for (final chunk in response.stream) {
        if (_cancelled) {
          await sink.close();
          return _DownloadResult.cancelled;
        }
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress(startOffset + receivedBytes);
      }
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (_cancelled) return _DownloadResult.cancelled;
      if (_isRetryableException(e)) return _DownloadResult.retryable;
      return _DownloadResult.retryable;
    }

    final finalSize = await _safeFileLength(savePath);
    if (totalBytes != null && totalBytes > 0 && finalSize != totalBytes) {
      debugPrint('[MnnModelDownloader] Incomplete file for $fileName: size=$finalSize total=$totalBytes');
      return _DownloadResult.retryable;
    }

    final looksTextPointer = await _looksLikeTextPointer(file);
    if (looksTextPointer) {
      debugPrint('[MnnModelDownloader] Downloaded content looks like a text pointer/html for $fileName');
      try {
        await file.delete();
      } catch (_) {}
      return _DownloadResult.fatal;
    }

    final minBytes = _minExpectedBytes(fileName);
    if (minBytes != null && finalSize < minBytes) {
      debugPrint('[MnnModelDownloader] File too small for $fileName: size=$finalSize minExpected=$minBytes');
      return _DownloadResult.retryable;
    }

    debugPrint('[MnnModelDownloader] $fileName downloaded successfully');
    return _DownloadResult.success;
  }

  static bool _isRetryableStatusCode(int code) {
    if (code == 408) return true;
    if (code == 429) return true;
    if (code >= 500 && code <= 599) return true;
    return false;
  }

  static bool _isRetryableException(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    if (e is HandshakeException) return true;
    if (e is HttpException) return true;
    if (e is http.ClientException) return true;
    return false;
  }

  static int? _totalBytesFromResponse(http.StreamedResponse response) {
    if (response.statusCode == 200) return response.contentLength;
    final contentRange = response.headers['content-range'] ?? response.headers['Content-Range'];
    if (contentRange == null) return null;
    return parseTotalBytesFromContentRange(contentRange);
  }

  static int? parseTotalBytesFromContentRange(String value) {
    final v = value.trim();
    final slash = v.lastIndexOf('/');
    if (slash < 0) return null;
    final totalStr = v.substring(slash + 1).trim();
    if (totalStr == '*' || totalStr.isEmpty) return null;
    return int.tryParse(totalStr);
  }

  static Future<bool> _looksLikeTextPointer(File file) async {
    try {
      final raf = await file.open();
      final bytes = await raf.read(512);
      await raf.close();
      if (bytes.isEmpty) return true;

      final text = String.fromCharCodes(bytes).toLowerCase();
      if (text.contains('git-lfs.github.com')) return true;
      if (text.contains('<html') || text.contains('<!doctype html')) return true;
      if (text.contains('access denied') || text.contains('forbidden')) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  static int? _minExpectedBytes(String fileName) {
    switch (fileName) {
      case 'llm.mnn.weight':
        return 100 * 1024 * 1024;
      case 'llm.mnn':
        return 200 * 1024;
      case 'tokenizer.txt':
        return 4 * 1024;
      case 'config.json':
      case 'llm_config.json':
        return 200;
      default:
        return null;
    }
  }

  /// 取消下载
  void cancel() {
    _cancelled = true;
    _httpClient?.close();
  }

  /// 删除已下载的模型
  static Future<bool> deleteModel() async {
    try {
      final modelDir = await getModelDir();
      final dir = Directory(modelDir);

      if (await dir.exists()) {
        await dir.delete(recursive: true);
        debugPrint('[MnnModelDownloader] Model deleted');
      }

      return true;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Error deleting model: $e');
      return false;
    }
  }

  /// 获取模型路径
  static Future<String?> getModelPath() async {
    if (await isModelDownloaded()) {
      return getModelDir();
    }
    return null;
  }

  void dispose() {
    _statusController.close();
    _progressController.close();
    _currentFileController.close();
  }
}

enum _DownloadResult {
  success,
  retryable,
  fatal,
  cancelled,
}
