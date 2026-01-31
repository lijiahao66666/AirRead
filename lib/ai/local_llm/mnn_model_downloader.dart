import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
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
/// 从 ModelScope 下载 Qwen3-0.6B MNN 模型（zip格式）
class MnnModelDownloader {
  static const String _modelDir = 'models/qwen3-0.6b-mnn';
  static const String _zipFileName = 'qwen3-0.6b-mnn.zip';

  // ModelScope 下载链接（Qwen3-0.6B MNN int4 量化模型）
  static const String _downloadUrl =
      'https://modelscope.cn/models/lijiahaojj/MNN/resolve/master/qwen3-0.6B.zip';

  // 预估zip文件大小约600MB
  static const int _estimatedZipSize = 600 * 1024 * 1024;

  // 模型文件列表（用于检查完整性）
  static final List<String> _modelFiles = [
    'config.json',
    'llm_config.json',
    'llm.mnn',
    'llm.mnn.json',
    'llm.mnn.weight',
    'tokenizer.txt',
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

  /// 获取zip文件路径
  static Future<String> _getZipFilePath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, _zipFileName);
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
      for (final fileName in _modelFiles) {
        final filePath = p.join(modelDir, fileName);
        if (!await File(filePath).exists()) {
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

      for (final fileName in _modelFiles) {
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
      final zipFilePath = await _getZipFilePath();

      // 创建目录
      final dir = Directory(modelDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 下载zip文件
      _currentFile = 'qwen3-0.6b-mnn.zip';
      _currentFileController.add(_currentFile);

      final downloadSuccess = await _downloadZipFile(zipFilePath, (received, total) {
        _progress = received / total;
        _progressController.add(_progress);
      });

      if (!downloadSuccess) {
        _status = ModelDownloadStatus.failed;
        _statusController.add(_status);
        return false;
      }

      if (_cancelled) {
        _status = ModelDownloadStatus.notDownloaded;
        _statusController.add(_status);
        return false;
      }

      // 解压zip文件
      _status = ModelDownloadStatus.extracting;
      _statusController.add(_status);
      _currentFile = '解压中...';
      _currentFileController.add(_currentFile);

      final extractSuccess = await _extractZipFile(zipFilePath, modelDir);

      if (!extractSuccess) {
        _status = ModelDownloadStatus.failed;
        _statusController.add(_status);
        return false;
      }

      // 删除zip文件
      try {
        final zipFile = File(zipFilePath);
        if (await zipFile.exists()) {
          await zipFile.delete();
        }
      } catch (e) {
        debugPrint('[MnnModelDownloader] Error deleting zip file: $e');
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

  /// 下载zip文件
  Future<bool> _downloadZipFile(
    String zipFilePath,
    Function(int received, int total) onProgress,
  ) async {
    try {
      debugPrint('[MnnModelDownloader] Downloading zip from $_downloadUrl');

      final request = http.Request('GET', Uri.parse(_downloadUrl));
      final response = await _httpClient!.send(request);

      if (response.statusCode != 200) {
        debugPrint('[MnnModelDownloader] Failed to download zip: ${response.statusCode}');
        return false;
      }

      final contentLength = response.contentLength ?? _estimatedZipSize;
      final file = File(zipFilePath);
      final sink = file.openWrite();
      int receivedBytes = 0;

      await for (final chunk in response.stream) {
        if (_cancelled) {
          sink.close();
          return false;
        }
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress(receivedBytes, contentLength);
      }

      await sink.close();
      debugPrint('[MnnModelDownloader] Zip file downloaded successfully');
      return true;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Error downloading zip: $e');
      return false;
    }
  }

  /// 解压zip文件
  Future<bool> _extractZipFile(String zipFilePath, String destDir) async {
    try {
      debugPrint('[MnnModelDownloader] Extracting zip file...');

      final zipFile = File(zipFilePath);
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        if (_cancelled) {
          return false;
        }

        final fileName = file.name;

        // 跳过目录和隐藏文件
        if (file.isFile && !fileName.startsWith('__MACOSX/') && !fileName.startsWith('.')) {
          // 提取文件名（去掉目录路径）
          final baseName = p.basename(fileName);

          // 只提取需要的模型文件
          if (_modelFiles.contains(baseName)) {
            final outputPath = p.join(destDir, baseName);
            final outputFile = File(outputPath);
            await outputFile.writeAsBytes(file.content as List<int>);
            debugPrint('[MnnModelDownloader] Extracted: $baseName');
          }
        }
      }

      debugPrint('[MnnModelDownloader] Extraction completed');
      return true;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Error extracting zip: $e');
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

      // 同时删除zip文件
      final zipFilePath = await _getZipFilePath();
      final zipFile = File(zipFilePath);
      if (await zipFile.exists()) {
        await zipFile.delete();
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
