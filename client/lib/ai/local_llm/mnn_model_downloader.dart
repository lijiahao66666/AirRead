import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'mnn_model_spec.dart';

/// MNN 模型下载状态
enum ModelDownloadStatus {
  notDownloaded,
  downloading,
  extracting,
  completed,
  failed,
}

/// MNN 模型下载器
/// 从 ModelScope 下载 MNN 模型（直接下载文件）
class MnnModelDownloader {
  final MnnModelSpec spec;

  MnnModelDownloader({required this.spec});

  int get estimatedTotalSize => spec.estimatedTotalSizeBytes;

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
  bool _sessionPrepared = false;
  final Map<String, int> _receivedBytesByFile = {};
  final Map<String, int> _expectedBytesByFile = {};

  ModelDownloadStatus get status => _status;
  double get progress => _progress;
  String get currentFile => _currentFile;

  static const int _defaultMaxAttemptsPerFile = 6;
  static const Duration _defaultInitialBackoff = Duration(milliseconds: 800);
  static const Duration _defaultMaxBackoff = Duration(seconds: 30);
  static const Duration _defaultRequestTimeout = Duration(minutes: 20);
  static const Duration _defaultSmallFileTimeout = Duration(seconds: 45);
  static const Duration _defaultStreamInactivityTimeoutSmall =
      Duration(seconds: 20);
  static const Duration _defaultStreamInactivityTimeoutLarge =
      Duration(seconds: 45);
  String _lastError = '';

  Future<Directory> _getAppDirSafe() async {
    if (kIsWeb) {
      throw UnsupportedError('Local model storage is not supported on Web.');
    }
    try {
      return await getApplicationDocumentsDirectory();
    } on MissingPluginException {
      return Directory.systemTemp;
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  /// 获取模型目录路径
  Future<String> getModelDir() async {
    final appDir = await _getAppDirSafe();
    return p.join(appDir.path, spec.modelDirRelative);
  }

  /// 检查模型是否已下载
  Future<bool> isModelDownloaded() async {
    try {
      final modelDir = await getModelDir();
      final dir = Directory(modelDir);

      if (!await dir.exists()) {
        return false;
      }

      // 检查所有必需文件是否存在
      for (final fileName in spec.criticalFiles) {
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
  Future<int> getDownloadedSize() async {
    try {
      final modelDir = await getModelDir();
      int totalSize = 0;

      for (final fileName in spec.filesToDownload) {
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
    _httpClient = IOClient(_createHttpClient());
    _sessionPrepared = false;
    _receivedBytesByFile.clear();
    _expectedBytesByFile.clear();

    try {
      final modelDir = await getModelDir();

      // 创建目录
      final dir = Directory(modelDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      await _prepareModelScopeSession();
      await _initializeProgressBaseline(modelDir);

      // 逐个下载文件
      for (final fileName in spec.filesToDownload) {
        if (_cancelled) break;
        
        _currentFile = fileName;
        _currentFileController.add(_currentFile);
        
        final filePath = p.join(modelDir, fileName);
        if (!_supportsResume(fileName)) {
          _receivedBytesByFile[fileName] = 0;
          _expectedBytesByFile[fileName] = 0;
          _updateOverallProgress();
        }
        
        final success = await _downloadSingleFileWithRetry(
          fileName, 
          filePath, 
          (bytes) {
             _receivedBytesByFile[fileName] = bytes;
             _updateOverallProgress();
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

  Future<void> _initializeProgressBaseline(String modelDir) async {
    for (final fileName in spec.filesToDownload) {
      final filePath = p.join(modelDir, fileName);
      if (_supportsResume(fileName)) {
        _receivedBytesByFile[fileName] = await _safeFileLength(filePath);
      } else {
        _receivedBytesByFile[fileName] = 0;
      }
      _expectedBytesByFile[fileName] = 0;
    }
    _updateOverallProgress();
  }

  void _updateOverallProgress() {
    final files = spec.filesToDownload;
    if (files.isEmpty) return;

    // Calculate total received bytes
    int totalReceived = 0;
    for (final fileName in files) {
      totalReceived += _receivedBytesByFile[fileName] ?? 0;
    }

    // Use estimated total size as the baseline
    // If estimated size is 0 or invalid, fallback to a small number to avoid div by zero
    final totalExpected = spec.estimatedTotalSizeBytes > 0
        ? spec.estimatedTotalSizeBytes
        : 1024 * 1024 * 100; // 100MB fallback

    double p = totalReceived / totalExpected;
    
    // Clamp to 0.0 - 0.99
    // We leave 1.0 for the explicit completion state
    final next = p.clamp(0.0, 0.99);

    if ((next - _progress).abs() > 0.001) {
      _progress = next;
      _progressController.add(_progress);
    }
  }

  HttpClient _createHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    return client;
  }

  Future<void> _prepareModelScopeSession() async {
    if (_sessionPrepared) return;
    final client = _httpClient;
    if (client == null) return;

    final baseUri = Uri.parse(spec.baseUrl);
    final warmupUri = Uri(
      scheme: baseUri.scheme,
      host: baseUri.host,
      path: '/',
    );

    try {
      final request = http.Request('GET', warmupUri);
      _applyDefaultHeaders(request, baseUri: baseUri);
      final response = await client.send(request).timeout(
        const Duration(seconds: 20),
      );
      await response.stream.drain<void>();
      debugPrint(
        '[MnnModelDownloader] Session warmup status=${response.statusCode}',
      );
    } catch (e) {
      debugPrint('[MnnModelDownloader] Session warmup failed: $e');
    } finally {
      _sessionPrepared = true;
    }
  }

  void _applyDefaultHeaders(
    http.BaseRequest request, {
    required Uri baseUri,
  }) {
    request.headers['User-Agent'] =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    request.headers['Accept'] =
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    request.headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    request.headers['Connection'] = 'keep-alive';
    final referer = _modelScopeReferer(baseUri);
    if (referer != null) request.headers['Referer'] = referer;
  }

  String? _modelScopeReferer(Uri baseUri) {
    final seg = baseUri.pathSegments.where((e) => e.isNotEmpty).toList();
    final modelsIndex = seg.indexOf('models');
    if (modelsIndex < 0 || seg.length <= modelsIndex + 2) return null;
    final org = seg[modelsIndex + 1];
    final repo = seg[modelsIndex + 2];
    return Uri(
      scheme: baseUri.scheme,
      host: baseUri.host,
      path: '/models/$org/$repo/summary',
    ).toString();
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

      final existingBytes =
          _supportsResume(fileName) ? await _safeFileLength(savePath) : 0;
      final res = await _downloadSingleFileOnce(
        fileName: fileName,
        savePath: savePath,
        existingBytes: existingBytes,
        onProgress: onProgress,
      );

      if (res == _DownloadResult.success) return true;
      if (res == _DownloadResult.cancelled) return false;
      if (res == _DownloadResult.fatal) return false;

      debugPrint(
        '[MnnModelDownloader] Retryable failure for $fileName (attempt=$attempt) error=$_lastError',
      );

      if (_defaultMaxAttemptsPerFile > 0 && attempt >= _defaultMaxAttemptsPerFile) {
        debugPrint(
          '[MnnModelDownloader] Giving up on $fileName after $attempt attempts. lastError=$_lastError',
        );
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
    _lastError = '';
    final client = _httpClient;
    if (client == null) {
      _lastError = 'http client is null';
      return _DownloadResult.retryable;
    }

    http.StreamedResponse? response;
    Object? lastException;
    for (final url in _candidateUrlsForFile(fileName)) {
      debugPrint('[MnnModelDownloader] Downloading $fileName from $url');
      try {
        final request = http.Request('GET', Uri.parse(url));
        _applyDefaultHeaders(request, baseUri: Uri.parse(spec.baseUrl));
        request.headers['Accept'] = 'application/octet-stream,*/*;q=0.8';
        if (existingBytes > 0 && _supportsResume(fileName)) {
          request.headers['Range'] = 'bytes=$existingBytes-';
        }

        response = await client.send(request).timeout(
          _requestTimeoutForFile(fileName),
          onTimeout: () {
            throw TimeoutException('Download timeout for $fileName');
          },
        );
      } catch (e) {
        if (_cancelled) return _DownloadResult.cancelled;
        lastException = e;
        _lastError = e.toString();
        if (_isRetryableException(e)) return _DownloadResult.retryable;
        return _DownloadResult.fatal;
      }

      if (_cancelled) return _DownloadResult.cancelled;

      if (response.statusCode == 200 || response.statusCode == 206) {
        break;
      }

      // Handle 416 Range Not Satisfiable
      // Usually means the file is already fully downloaded (existingBytes >= remoteSize)
      if (response.statusCode == 416) {
        debugPrint(
            '[MnnModelDownloader] 416 Range Not Satisfiable for $fileName. Checking local file...');
        final localSize = await _safeFileLength(savePath);
        final minBytes = _minExpectedBytes(fileName) ?? 1;
        if (localSize > 0 && localSize >= minBytes) {
          debugPrint(
              '[MnnModelDownloader] Local file seems valid (size=$localSize). Treating as success.');
          onProgress(localSize); // Update progress with full size
          return _DownloadResult.success;
        } else {
          debugPrint(
              '[MnnModelDownloader] Local file invalid/small ($localSize). Deleting and retrying.');
          try {
            await File(savePath).delete();
          } catch (_) {}
          _lastError = '416 but local file invalid';
          // Continue to next attempt (which will be from scratch since file is deleted)
          continue;
        }
      }

      debugPrint(
        '[MnnModelDownloader] Failed to download $fileName: ${response.statusCode}',
      );
      _lastError = 'http ${response.statusCode}';

      if (_isRetryableStatusCode(response.statusCode)) return _DownloadResult.retryable;

      final shouldTryNext = response.statusCode == 404 || response.statusCode == 403;
      if (!shouldTryNext) return _DownloadResult.fatal;
    }

    if (response == null) {
      _lastError = lastException?.toString() ?? 'no response';
      return _DownloadResult.fatal;
    }

    if (_cancelled) return _DownloadResult.cancelled;

    if (response.statusCode != 200 && response.statusCode != 206) {
      debugPrint('[MnnModelDownloader] Failed to download $fileName: ${response.statusCode}');
      _lastError = 'http ${response.statusCode}';
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
    final expected = totalBytes ??
        response.contentLength ??
        spec.minExpectedBytesByFile[fileName] ??
        1;
    _expectedBytesByFile[fileName] = expected;
    _updateOverallProgress();
    final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
    int receivedBytes = 0;

    try {
      await for (final chunk
          in response.stream.timeout(_streamInactivityTimeoutForFile(fileName))) {
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
      _lastError = e.toString();
      if (_isRetryableException(e)) return _DownloadResult.retryable;
      return _DownloadResult.retryable;
    }

    final finalSize = await _safeFileLength(savePath);
    if (totalBytes != null && totalBytes > 0 && finalSize != totalBytes) {
      debugPrint('[MnnModelDownloader] Incomplete file for $fileName: size=$finalSize total=$totalBytes');
      _lastError = 'incomplete file size=$finalSize total=$totalBytes';
      return _DownloadResult.retryable;
    }

    final looksTextPointer = await _looksLikeTextPointer(file);
    if (looksTextPointer) {
      debugPrint('[MnnModelDownloader] Downloaded content looks like a text pointer/html for $fileName');
      try {
        await file.delete();
      } catch (_) {}
      _lastError = 'downloaded content looks like html/pointer';
      return _DownloadResult.fatal;
    }

    final minBytes = _minExpectedBytes(fileName);
    if (minBytes != null && finalSize < minBytes) {
      debugPrint('[MnnModelDownloader] File too small for $fileName: size=$finalSize minExpected=$minBytes');
      _lastError = 'file too small size=$finalSize minExpected=$minBytes';
      return _DownloadResult.retryable;
    }

    debugPrint('[MnnModelDownloader] $fileName downloaded successfully');
    return _DownloadResult.success;
  }

  Duration _requestTimeoutForFile(String fileName) {
    final isLarge = fileName == spec.progressFileName || fileName.endsWith('.weight');
    return isLarge ? _defaultRequestTimeout : _defaultSmallFileTimeout;
  }

  bool _supportsResume(String fileName) {
    return fileName == spec.progressFileName || fileName.endsWith('.weight');
  }

  Duration _streamInactivityTimeoutForFile(String fileName) {
    final isLarge = fileName == spec.progressFileName || fileName.endsWith('.weight');
    return isLarge
        ? _defaultStreamInactivityTimeoutLarge
        : _defaultStreamInactivityTimeoutSmall;
  }

  List<String> _candidateUrlsForFile(String fileName) {
    final baseUri = Uri.parse(spec.baseUrl);
    final base = baseUri.resolve(fileName).toString();
    final candidates = <String>[base];

    void addIf(String url) {
      if (!candidates.contains(url)) candidates.add(url);
    }

    for (final url in List<String>.from(candidates)) {
      if (url.contains('/resolve/master/')) {
        addIf(url.replaceFirst('/resolve/master/', '/resolve/main/'));
      }
      if (url.contains('://modelscope.cn/')) {
        addIf(url.replaceFirst('://modelscope.cn/', '://www.modelscope.cn/'));
      }
      if (url.contains('://www.modelscope.cn/')) {
        addIf(url.replaceFirst('://www.modelscope.cn/', '://modelscope.cn/'));
      }
    }

    return candidates;
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

  int? _minExpectedBytes(String fileName) {
    return spec.minExpectedBytesByFile[fileName];
  }

  /// 取消下载
  void cancel() {
    _cancelled = true;
    _httpClient?.close();
  }

  /// 删除已下载的模型
  Future<bool> deleteModel() async {
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
  Future<String?> getModelPath() async {
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
