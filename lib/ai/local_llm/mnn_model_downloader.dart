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
        if (!await File(filePath).exists()) {
          debugPrint('[MnnModelDownloader] Missing critical file: $fileName');
          return false;
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
        
        final success = await _downloadSingleFile(
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

  /// 下载单个文件
  Future<bool> _downloadSingleFile(
    String fileName,
    String savePath,
    Function(int received) onProgress,
  ) async {
    try {
      final url = '$_baseUrl$fileName';
      debugPrint('[MnnModelDownloader] Downloading $fileName from $url');

      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'AirRead/1.0';

      final response = await _httpClient!.send(request).timeout(
        const Duration(minutes: 20), // 大文件给多点时间
        onTimeout: () {
          throw Exception('Download timeout for $fileName');
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
            '[MnnModelDownloader] Failed to download $fileName: ${response.statusCode}');
        return false;
      }

      final file = File(savePath);
      final sink = file.openWrite();
      int receivedBytes = 0;

      await for (final chunk in response.stream) {
        if (_cancelled) {
          sink.close();
          return false;
        }
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress(receivedBytes);
      }

      await sink.close();
      debugPrint('[MnnModelDownloader] $fileName downloaded successfully');
      return true;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Error downloading $fileName: $e');
      return false;
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
