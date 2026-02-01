import 'dart:async';
import 'dart:io';
import 'package:archive/archive_io.dart';
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
  static const String _zipFileName = 'qwen3-0.6B.zip';

  // ModelScope 下载链接（Qwen3-0.6B MNN 模型）
  static const String _downloadUrl =
      'https://modelscope.cn/models/lijiahaojj/MNN/resolve/master/qwen3-0.6B-mnn.zip';

  // 预估zip文件大小约390MB
  static const int estimatedTotalSize = 390 * 1024 * 1024;
  static const int _estimatedZipSize = estimatedTotalSize;

  // 模型文件列表（用于检查完整性）
  static final List<String> _modelFiles = [
    'config.json',
    'llm_config.json',
    'llm.mnn',
    // 'llm.mnn.json', // 可选，非必需
    'llm.mnn.weight',
    'tokenizer.txt',
  ];

  // 必需的关键文件
  static final List<String> _criticalFiles = [
    'llm.mnn',
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
      for (final fileName in _criticalFiles) {
        final filePath = p.join(modelDir, fileName);
        if (!await File(filePath).exists()) {
          debugPrint('[MnnModelDownloader] Missing critical file: $fileName');
          return false;
        }
      }

      // 检查 config.json 是否存在，如果不存在但 llm_config.json 存在，则视为正常（后面会自动处理）
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
           // 如果连 llm_config.json 都没有，尝试创建一个默认的
           try {
             final defaultContent = '{"llm_model": "llm.mnn", "llm_weight": "llm.mnn.weight", "tokenizer_file": "tokenizer.txt"}';
             await File(configPath).writeAsString(defaultContent);
             debugPrint('[MnnModelDownloader] Created default config.json');
           } catch (e) {
             debugPrint('[MnnModelDownloader] Failed to create default config.json: $e');
             return false;
           }
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

      final downloadSuccess =
          await _downloadZipFile(zipFilePath, (received, total) {
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

      // 使用 compute 在后台 isolate 中执行解压，避免阻塞 UI 线程
      final extractSuccess = await compute(
        _extractZipFileInIsolate,
        _ExtractParams(
          zipFilePath: zipFilePath,
          destDir: modelDir,
          modelFiles: _modelFiles,
        ),
      );

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
      request.headers['User-Agent'] = 'AirRead/1.0';

      // 设置超时
      final response = await _httpClient!.send(request).timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          throw Exception('Download timeout after 10 minutes');
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
            '[MnnModelDownloader] Failed to download zip: ${response.statusCode}');
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
    } on SocketException catch (e) {
      debugPrint('[MnnModelDownloader] Network error: $e');
      return false;
    } on TimeoutException catch (e) {
      debugPrint('[MnnModelDownloader] Download timeout: $e');
      return false;
    } catch (e) {
      debugPrint('[MnnModelDownloader] Error downloading zip: $e');
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

class _ExtractParams {
  final String zipFilePath;
  final String destDir;
  final List<String> modelFiles;

  _ExtractParams({
    required this.zipFilePath,
    required this.destDir,
    required this.modelFiles,
  });
}

/// 顶级函数，用于在 isolate 中执行解压
Future<bool> _extractZipFileInIsolate(_ExtractParams params) async {
  try {
    debugPrint('[MnnModelDownloader] Extracting zip file in isolate...');

    // 手动逐个读取文件头，避免一次性加载所有 Central Directory
    // archive 包的 decodeBuffer 会尝试读取整个 Central Directory，如果文件很多或者注释很长，可能会有问题
    // 但对于 5 个文件，Central Directory 很小。
    
    // 问题在于 InputFileStream 的实现可能在某些情况下 buffer 过大。
    // 我们尝试显式管理 buffer。
    
    final inputStream = InputFileStream(params.zipFilePath);
    final archive = ZipDecoder().decodeBuffer(inputStream);

    debugPrint('[MnnModelDownloader] Zip contains ${archive.files.length} files');

    for (final file in archive.files) {
      final fileName = file.name;
      
      // 跳过目录和隐藏文件
      if (file.isFile &&
          !fileName.startsWith('__MACOSX/') &&
          !fileName.startsWith('.')) {
        // 提取文件名（去掉目录路径）
        final baseName = p.basename(fileName);

        // 只提取需要的模型文件
        if (params.modelFiles.contains(baseName)) {
          final outputPath = p.join(params.destDir, baseName);
          debugPrint('[MnnModelDownloader] Extracting: $baseName');
          
          try {
            final outputStream = OutputFileStream(outputPath);
            file.writeContent(outputStream);
            outputStream.close();
            debugPrint('[MnnModelDownloader] Extracted: $baseName');
          } catch (e) {
            debugPrint('[MnnModelDownloader] Error extracting $baseName: $e');
            inputStream.close();
            return false;
          }
          
          // 强制垃圾回收建议（虽然 Dart 不保证）
          // await Future.delayed(Duration(milliseconds: 100)); 
        }
      }
      // 释放文件内容内存（如果有的话）
      // archive.files 是一个列表，我们无法在这里移除。
    }
    
    inputStream.close();
    
    // Post-extraction check: Ensure config.json exists
    final configPath = p.join(params.destDir, 'config.json');
    if (!await File(configPath).exists()) {
      debugPrint('[MnnModelDownloader] config.json missing after extraction. Creating default...');
      try {
        final defaultContent = '{"llm_model": "llm.mnn", "llm_weight": "llm.mnn.weight", "tokenizer_file": "tokenizer.txt"}';
        await File(configPath).writeAsString(defaultContent);
      } catch (e) {
        debugPrint('[MnnModelDownloader] Failed to create default config.json: $e');
      }
    }
    
    debugPrint('[MnnModelDownloader] Extraction completed');
    return true;
  } catch (e) {
    debugPrint('[MnnModelDownloader] Error extracting zip: $e');
    return false;
  }
}
