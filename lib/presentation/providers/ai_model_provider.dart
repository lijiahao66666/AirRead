import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive_io.dart';
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

// QA内容范围设置
enum QAContentScope {
  currentPage, // 仅当前页面
  currentChapterToPage, // 当前章节开始到当前页面
  slidingWindow, // 滑动窗口（当前页面前后5页）
}

class AiModelProvider extends ChangeNotifier {
  static const _kModelSource = 'ai_model_source';
  static const _kQAContentScope = 'qa_content_scope';

  static const MethodChannel _androidLogcatChannel =
      MethodChannel('airread/local_llm');

  static const bool _smokeTestLocalModel = bool.fromEnvironment(
    'AIRREAD_LOCAL_MODEL_SMOKE_TEST',
    defaultValue: false,
  );

  static const Map<LocalLlmModelType, String> _localModelModelScopeUrlByType = {
    LocalLlmModelType.qa:
        'https://www.modelscope.cn/models/lijiahaojj/HY1.8B-MNN/resolve/master/Hunyuan-1.8B-Instruct.zip',
    LocalLlmModelType.translation:
        'https://www.modelscope.cn/models/lijiahaojj/HY1.8B-MNN/resolve/master/HY-MT1.5-1.8B.zip',
  };

  bool _loaded = false;
  AiModelSource _source = AiModelSource.none;

  final Map<LocalLlmModelType, bool> _localModelExistsByType = {
    for (final t in LocalLlmModelType.values) t: false,
  };
  bool _localModelDownloading = false;
  bool _localModelPaused = false;
  LocalLlmModelType? _pausedDownloadType;
  bool _localModelInstalling = false;
  final Map<LocalLlmModelType, bool> _localModelCorruptRetriedByType = {
    for (final t in LocalLlmModelType.values) t: false,
  };
  double _localModelProgress = 0;
  String _localModelError = '';
  int _localModelDownloadedBytes = 0;
  int _localModelTotalBytes = 0;
  bool _localRuntimeAvailable = false;
  bool _localModelSmokeDone = false;

  final Map<LocalLlmModelType, int> _downloadedBytesByType = {
    for (final t in LocalLlmModelType.values) t: 0,
  };
  final Map<LocalLlmModelType, int> _totalBytesByType = {
    for (final t in LocalLlmModelType.values) t: 0,
  };
  final Map<LocalLlmModelType, int> _installedBytesByType = {
    for (final t in LocalLlmModelType.values) t: 0,
  };

  List<LocalLlmModelType> _downloadQueue = const [];
  LocalLlmModelType? _activeDownloadType;

  http.Client? _downloadClient;
  StreamSubscription<List<int>>? _downloadSub;
  IOSink? _downloadSink;
  Timer? _installWatchdog;

  QAContentScope _qaContentScope = QAContentScope.slidingWindow; // 默认滑动窗口

  AiModelProvider() {
    _load();
  }

  void _debugLog(String message) {
    debugPrint('[AiModelProvider] $message');
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(
        _androidLogcatChannel.invokeMethod<void>(
          'logcat',
          <String, String>{
            'tag': 'AiModelProvider',
            'message': message,
          },
        ).catchError((_) {}),
      );
    }
  }

  Future<bool> _looksLikeZip(File file) async {
    try {
      final len = await file.length();
      if (len < 4) return false;
      final raf = await file.open();
      final header = await raf.read(4);
      await raf.close();
      if (header.length < 4) return false;
      return header[0] == 0x50 && header[1] == 0x4b;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _looksLikeCompleteZip(File file) async {
    try {
      final len = await file.length();
      if (len < 22) return false;
      final raf = await file.open();
      try {
        const maxScan = 65557;
        final scanSize = len < maxScan ? len : maxScan;
        await raf.setPosition(len - scanSize);
        final tail = await raf.read(scanSize);
        if (tail.length < 22) return false;
        for (int i = tail.length - 22; i >= 0; i--) {
          if (tail[i] == 0x50 &&
              tail[i + 1] == 0x4b &&
              tail[i + 2] == 0x05 &&
              tail[i + 3] == 0x06) {
            return true;
          }
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<String> _readFilePreview(File file, {int maxBytes = 256}) async {
    try {
      final len = await file.length();
      final take = len < maxBytes ? len : maxBytes;
      if (take <= 0) return '';
      final raf = await file.open();
      final bytes = await raf.read(take);
      await raf.close();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  int? _tryParseTotalBytesFromContentRange(String? contentRange) {
    if (contentRange == null || contentRange.isEmpty) return null;
    final slashIndex = contentRange.lastIndexOf('/');
    if (slashIndex <= 0 || slashIndex == contentRange.length - 1) return null;
    final tail = contentRange.substring(slashIndex + 1).trim();
    if (tail == '*') return null;
    return int.tryParse(tail);
  }

  Uri _buildLocalModelModelScopeUri(LocalLlmModelType type) {
    final url = _localModelModelScopeUrlByType[type] ?? '';
    if (url.trim().isEmpty) {
      throw const HttpException('未配置 ModelScope 下载地址');
    }
    return Uri.parse(url);
  }

  QAContentScope get qaContentScope => _qaContentScope;

  bool get loaded => _loaded;
  AiModelSource get source => _source;

  bool get isModelEnabled => _source != AiModelSource.none;

  bool get localModelDownloading => _localModelDownloading;
  bool get localModelPaused => _localModelPaused;
  bool get localModelInstalling => _localModelInstalling;
  double get localModelProgress => _localModelProgress;
  String get localModelError => _localModelError;
  int get localModelDownloadedBytes => _localModelDownloadedBytes;
  int get localModelTotalBytes => _localModelTotalBytes;
  bool get localRuntimeAvailable => _localRuntimeAvailable;

  bool get isLocalModelReady => isLocalModelReadyByType(LocalLlmModelType.qa);

  bool get isLocalQaModelReady => isLocalModelReadyByType(LocalLlmModelType.qa);

  bool get isLocalTranslationModelReady =>
      isLocalModelReadyByType(LocalLlmModelType.translation);

  bool localModelExistsByType(LocalLlmModelType type) =>
      _localModelExistsByType[type] ?? false;

  bool isLocalModelDownloadingByType(LocalLlmModelType type) =>
      _localModelDownloading && _activeDownloadType == type;

  bool isLocalModelQueuedByType(LocalLlmModelType type) =>
      _localModelDownloading &&
      _activeDownloadType != type &&
      _downloadQueue.contains(type);

  bool isLocalModelPausedByType(LocalLlmModelType type) =>
      _localModelPaused && _pausedDownloadType == type;

  bool isLocalModelInstallingByType(LocalLlmModelType type) =>
      _localModelInstalling && _activeDownloadType == type;

  int localModelDownloadedBytesByType(LocalLlmModelType type) {
    final installed = _installedBytesByType[type] ?? 0;
    if (installed > 0) return installed;
    return _downloadedBytesByType[type] ?? 0;
  }

  int localModelTotalBytesByType(LocalLlmModelType type) {
    final installed = _installedBytesByType[type] ?? 0;
    if (installed > 0) return installed;
    return _totalBytesByType[type] ?? 0;
  }

  double localModelProgressByType(LocalLlmModelType type) {
    final total = localModelTotalBytesByType(type);
    final downloaded = localModelDownloadedBytesByType(type);
    if (total <= 0) return 0;
    return (downloaded / total).clamp(0, 1);
  }

  bool isLocalModelReadyByType(LocalLlmModelType type) {
    final exists = _localModelExistsByType[type] ?? false;
    if (!exists) return false;
    if (!_localRuntimeAvailable) return false;
    if (_localModelInstalling && _activeDownloadType == type) return false;
    if (_localModelDownloading && _activeDownloadType == type) return false;
    if (_localModelPaused && _pausedDownloadType == type) return false;
    return true;
  }

  @override
  void dispose() {
    _cancelDownload(isPause: false);
    _stopInstallWatchdog();
    super.dispose();
  }

  void _startInstallWatchdog() {
    _installWatchdog?.cancel();
    _installWatchdog = Timer(const Duration(minutes: 8), () async {
      if (!_localModelInstalling) return;
      _debugLog('install: watchdog timeout');
      _localModelDownloading = false;
      _localModelPaused = false;
      _localModelInstalling = false;
      _localModelError = '模型安装超时，请重试';
      notifyListeners();
      await refreshLocalModelStatus();
      await refreshLocalRuntimeStatus();
    });
  }

  void _stopInstallWatchdog() {
    _installWatchdog?.cancel();
    _installWatchdog = null;
  }

  Future<void> setSource(AiModelSource value) async {
    if (_source == value) return;
    _source = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelSource, value.name);
  }

  Future<void> setQAContentScope(QAContentScope value) async {
    if (_qaContentScope == value) return;
    _qaContentScope = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQAContentScope, value.name);
  }

  String _modelDirName(LocalLlmModelType type) {
    return switch (type) {
      LocalLlmModelType.qa => 'qa',
      LocalLlmModelType.translation => 'mt',
    };
  }

  Future<Directory> getLocalModelBaseDir() async {
    if (kIsWeb) {
      throw UnsupportedError('Local model not supported on Web');
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      return Directory(p.join(dir.path, 'models', 'hunyuan'));
    } catch (e) {
      throw Exception('无法获取本地模型路径: $e');
    }
  }

  Future<Directory> getLocalModelDir(LocalLlmModelType type) async {
    final base = await getLocalModelBaseDir();
    return Directory(p.join(base.path, _modelDirName(type)));
  }

  Future<File> getLocalModelConfigFile(LocalLlmModelType type) async {
    final modelDir = await getLocalModelDir(type);
    return File(p.join(modelDir.path, 'config.json'));
  }

  Future<File> getLocalModelZipFile(LocalLlmModelType type) async {
    final base = await getLocalModelBaseDir();
    return File(p.join(base.path, 'model_${_modelDirName(type)}.zip'));
  }

  Future<File> getLocalModelZipPartialFile(LocalLlmModelType type) async {
    final file = await getLocalModelZipFile(type);
    return File('${file.path}.partial');
  }

  Future<List<File>> _resolveLocalModelFiles(LocalLlmModelType type) async {
    final dir = await getLocalModelDir(type);
    final config = File(p.join(dir.path, 'config.json'));
    if (!await config.exists()) return const [];
    if (await config.length().catchError((_) => 0) <= 0) return const [];

    final raw = await config.readAsString().catchError((_) => '');
    if (raw.trim().isEmpty) return const [];

    final referencedNames = <String>{};
    final referencedRelPaths = <String>{};
    void collectFrom(dynamic v) {
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) return;
        if (!RegExp(r'\.(mnn|weight|json|txt)$', caseSensitive: false)
            .hasMatch(s)) return;

        if (s.contains('/') || s.contains('\\')) {
          var rel = s.replaceAll('\\', '/');
          rel = p.posix.normalize(rel);
          if (rel.startsWith('/') || rel.startsWith('..')) return;
          if (rel.startsWith('./')) rel = rel.substring(2);
          if (rel.isEmpty) return;
          referencedRelPaths.add(rel);
          return;
        }

        if (!RegExp(r'^[\w.\-]+$').hasMatch(s)) return;
        referencedNames.add(s);
        return;
      }
      if (v is List) {
        for (final e in v) {
          collectFrom(e);
        }
        return;
      }
      if (v is Map) {
        for (final e in v.values) {
          collectFrom(e);
        }
      }
    }

    try {
      final obj = jsonDecode(raw);
      collectFrom(obj);
    } catch (_) {
      return const [];
    }

    final files = <File>[config];
    for (final name in referencedNames) {
      if (name == 'config.json') continue;
      files.add(File(p.join(dir.path, name)));
    }
    for (final rel in referencedRelPaths) {
      if (rel == 'config.json') continue;
      files.add(File(p.joinAll(<String>[dir.path, ...rel.split('/')])));
    }
    return files;
  }

  Future<bool> _localModelFilesExist(LocalLlmModelType type) async {
    final files = await _resolveLocalModelFiles(type);
    if (files.isEmpty) return false;

    bool hasMnn = false;
    int size = 0;
    for (final f in files) {
      if (!await f.exists()) return false;
      final len = await f.length().catchError((_) => 0);
      if (len <= 0) return false;
      if (f.path.toLowerCase().endsWith('.mnn')) hasMnn = true;
      size += len;
    }
    if (!hasMnn) return false;
    if (size <= 0) return false;
    return true;
  }

  Future<int> _calcLocalModelSize(LocalLlmModelType type) async {
    final files = await _resolveLocalModelFiles(type);
    if (files.isEmpty) return 0;
    int size = 0;
    for (final f in files) {
      size += await f.length().catchError((_) => 0);
    }
    return size;
  }

  void _recomputeAggregateProgress() {
    int downloaded = 0;
    int total = 0;
    for (final t in LocalLlmModelType.values) {
      final installed = _installedBytesByType[t] ?? 0;
      final d = _downloadedBytesByType[t] ?? 0;
      final tt = _totalBytesByType[t] ?? 0;
      downloaded += installed > 0 ? installed : d;
      total += installed > 0 ? installed : tt;
    }
    _localModelDownloadedBytes = downloaded;
    _localModelTotalBytes = total;
    if (total > 0) {
      _localModelProgress = (downloaded / total).clamp(0, 1);
    } else {
      _localModelProgress = 0;
    }
  }

  Future<void> refreshLocalModelStatus() async {
    if (kIsWeb) {
      for (final t in LocalLlmModelType.values) {
        _localModelExistsByType[t] = false;
        _installedBytesByType[t] = 0;
      }
      notifyListeners();
      return;
    }

    bool anyExists = false;
    int totalSize = 0;

    for (final t in LocalLlmModelType.values) {
      final ok = await _localModelFilesExist(t);
      if (!ok) {
        _localModelExistsByType[t] = false;
        _installedBytesByType[t] = 0;
        if ((_downloadedBytesByType[t] ?? 0) == 0) {
          _totalBytesByType[t] = 0;
        }
        continue;
      }
      _localModelExistsByType[t] = true;
      anyExists = true;
      final size = await _calcLocalModelSize(t);
      _installedBytesByType[t] = size;
      _downloadedBytesByType[t] = size;
      _totalBytesByType[t] = size;
      totalSize += size;
    }

    if (anyExists && totalSize > 0) {
      _localModelError = '';
    }
    _recomputeAggregateProgress();
    notifyListeners();
  }

  Future<void> refreshLocalRuntimeStatus() async {
    final client = LocalLlmClient();
    _localRuntimeAvailable = await client.isAvailable();
    notifyListeners();
  }

  Future<void> _runLocalModelSmokeOnce() async {
    if (!_smokeTestLocalModel) return;
    if (_localModelSmokeDone) return;
    if (!isLocalModelReadyByType(LocalLlmModelType.qa)) return;
    _localModelSmokeDone = true;
    try {
      final client = LocalLlmClient();
      final out = await client.chatOnce(userText: '你好，请回复“连读测试成功”。');
      final preview = out.trim().replaceAll(RegExp(r'\s+'), ' ');
      _debugLog(
        'smoke: local chat ok len=${out.length} preview=${preview.substring(0, preview.length > 80 ? 80 : preview.length)}',
      );
    } catch (e) {
      _debugLog('smoke: local chat failed error=${_formatError(e)}');
    }
  }

  Future<void> startLocalModelDownload() async {
    if (_localModelDownloading) return;
    if (_localModelInstalling) return;
    if (kIsWeb) {
      _localModelError = 'Web 端暂不支持下载本地模型';
      notifyListeners();
      return;
    }

    await refreshLocalModelStatus();
    await refreshLocalRuntimeStatus();
    unawaited(_runLocalModelSmokeOnce());
    if (LocalLlmModelType.values.every(localModelExistsByType)) return;

    _debugLog('startLocalModelDownload: begin');

    final baseDir = await getLocalModelBaseDir();
    await baseDir.create(recursive: true);

    _downloadQueue = LocalLlmModelType.values.toList(growable: false);
    _activeDownloadType = null;
    _localModelDownloading = true;
    _localModelPaused = false;
    _pausedDownloadType = null;
    _localModelInstalling = false;
    _localModelError = '';
    _recomputeAggregateProgress();
    notifyListeners();

    unawaited(_startNextLocalModelInQueue());
  }

  Future<void> startLocalModelDownloadForType(
    LocalLlmModelType type,
  ) async {
    if (_localModelDownloading || _localModelInstalling) {
      if (localModelExistsByType(type)) return;
      if (_activeDownloadType == type) return;
      if (_downloadQueue.contains(type)) return;
      _downloadQueue = [..._downloadQueue, type];
      _recomputeAggregateProgress();
      notifyListeners();
      return;
    }
    if (kIsWeb) {
      _localModelError = 'Web 端暂不支持下载本地模型';
      notifyListeners();
      return;
    }

    await refreshLocalModelStatus();
    await refreshLocalRuntimeStatus();
    unawaited(_runLocalModelSmokeOnce());
    if (localModelExistsByType(type)) return;

    _debugLog('startLocalModelDownloadForType: type=${type.name}');

    final baseDir = await getLocalModelBaseDir();
    await baseDir.create(recursive: true);

    _downloadQueue = [type];
    _activeDownloadType = null;
    _localModelDownloading = true;
    _localModelPaused = false;
    _pausedDownloadType = null;
    _localModelInstalling = false;
    _localModelError = '';
    _recomputeAggregateProgress();
    notifyListeners();

    unawaited(_startNextLocalModelInQueue());
  }

  Future<void> _startNextLocalModelInQueue() async {
    if (_localModelPaused) return;
    if (!_localModelDownloading && !_localModelInstalling) return;

    while (_downloadQueue.isNotEmpty) {
      final type = _downloadQueue.first;
      final already = await _localModelFilesExist(type);
      if (already) {
        final size = await _calcLocalModelSize(type);
        _localModelExistsByType[type] = true;
        _installedBytesByType[type] = size;
        _downloadedBytesByType[type] = size;
        _totalBytesByType[type] = size;
        _downloadQueue = _downloadQueue.sublist(1);
        _recomputeAggregateProgress();
        notifyListeners();
        continue;
      }

      _activeDownloadType = type;
      unawaited(_startSingleLocalModelDownload(type));
      return;
    }

    _activeDownloadType = null;
    _downloadQueue = const [];
    _localModelDownloading = false;
    _localModelPaused = false;
    _pausedDownloadType = null;
    _localModelInstalling = false;
    _stopInstallWatchdog();
    await refreshLocalModelStatus();
    await refreshLocalRuntimeStatus();
    unawaited(_runLocalModelSmokeOnce());
    notifyListeners();
  }

  Future<void> _startSingleLocalModelDownload(LocalLlmModelType type) async {
    if (_localModelPaused) return;

    final modelDir = await getLocalModelDir(type);
    final targetZipFile = await getLocalModelZipFile(type);
    final partialZipFile = await getLocalModelZipPartialFile(type);

    int existing = 0;
    if (await partialZipFile.exists()) {
      existing = await partialZipFile.length();
    }

    if (existing == 0) {
      _localModelCorruptRetriedByType[type] = false;
      _downloadedBytesByType[type] = 0;
      _totalBytesByType[type] = 0;
    } else {
      _downloadedBytesByType[type] = existing;
    }

    _recomputeAggregateProgress();
    notifyListeners();

    _downloadClient?.close();
    _downloadClient = http.Client();

    try {
      http.StreamedResponse resp;
      final uri = _buildLocalModelModelScopeUri(type);
      final req = http.Request('GET', uri);
      req.headers['Accept-Encoding'] = 'identity';
      if (existing > 0) {
        req.headers['Range'] = 'bytes=$existing-';
      }
      _debugLog(
          'download: type=${type.name} modelscope send range=${req.headers['Range'] ?? ''}');
      resp = await _downloadClient!.send(req);
      _debugLog(
          'download: type=${type.name} modelscope resp status=${resp.statusCode} contentLength=${resp.contentLength}');
      _debugLog(
          'download: type=${type.name} modelscope headers contentEncoding=${resp.headers['content-encoding'] ?? ''} contentType=${resp.headers['content-type'] ?? ''} contentRange=${resp.headers['content-range'] ?? ''}');
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('ModelScope 下载失败：HTTP ${resp.statusCode}');
      }

      final isPartial = resp.statusCode == 206;
      if (existing > 0 && !isPartial) {
        try {
          await partialZipFile.delete();
        } catch (_) {}
        existing = 0;
        _downloadedBytesByType[type] = 0;
      }

      final respLength = resp.contentLength ?? 0;
      final totalFromRange =
          _tryParseTotalBytesFromContentRange(resp.headers['content-range']);
      _totalBytesByType[type] = totalFromRange ?? (existing + respLength);
      _recomputeAggregateProgress();
      notifyListeners();
      _debugLog(
          'download: type=${type.name} totalBytes=${_totalBytesByType[type]} existingBytes=$existing');

      _downloadSink = partialZipFile.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write,
      );
      _downloadSub = resp.stream.listen(
        (chunk) {
          _downloadSink?.add(chunk);
          _downloadedBytesByType[type] =
              (_downloadedBytesByType[type] ?? 0) + chunk.length;
          _recomputeAggregateProgress();
          notifyListeners();
        },
        onDone: () async {
          try {
            await _downloadSink?.flush();
            await _downloadSink?.close();
            _downloadSink = null;
            _downloadSub = null;

            final total = _totalBytesByType[type] ?? 0;
            final downloaded = _downloadedBytesByType[type] ?? 0;
            if (total > 0 && downloaded != total) {
              throw Exception(
                '模型下载失败：下载字节数不匹配（$downloaded/$total）',
              );
            }

            if (await targetZipFile.exists()) {
              try {
                await targetZipFile.delete();
              } catch (_) {}
            }
            _debugLog('install: type=${type.name} rename partial -> zip');
            await partialZipFile.rename(targetZipFile.path);

            _localModelInstalling = true;
            _startInstallWatchdog();
            notifyListeners();
            _debugLog('install: type=${type.name} begin');
            await _installLocalModelFromZip(targetZipFile, modelDir, type);
            _debugLog('install: type=${type.name} unzip done, cleanup zip');
            try {
              await targetZipFile.delete();
            } catch (_) {}

            final size = await _calcLocalModelSize(type);
            _localModelExistsByType[type] = true;
            _installedBytesByType[type] = size;
            _downloadedBytesByType[type] = size;
            _totalBytesByType[type] = size;
            _recomputeAggregateProgress();

            _localModelInstalling = false;
            _stopInstallWatchdog();
            _downloadQueue =
                _downloadQueue.isEmpty ? const [] : _downloadQueue.sublist(1);
            notifyListeners();
            unawaited(_startNextLocalModelInQueue());
          } catch (e) {
            final raw = '$e';
            final base = _formatError(e);
            final isCorruptZip = e is FormatException ||
                raw.contains('Filter error') ||
                raw.contains('bad data') ||
                base.contains('zip 不完整') ||
                base.contains('下载字节数不匹配');
            if (isCorruptZip &&
                !(_localModelCorruptRetriedByType[type] ?? false)) {
              _localModelCorruptRetriedByType[type] = true;
              try {
                await targetZipFile.delete();
              } catch (_) {}
              try {
                await partialZipFile.delete();
              } catch (_) {}
              _localModelInstalling = false;
              _stopInstallWatchdog();
              _localModelError = '压缩包损坏，正在重新下载…';
              _downloadedBytesByType[type] = 0;
              _totalBytesByType[type] = 0;
              _recomputeAggregateProgress();
              notifyListeners();
              _downloadClient?.close();
              _downloadClient = null;
              await Future<void>.delayed(const Duration(milliseconds: 80));
              unawaited(_startSingleLocalModelDownload(type));
              return;
            }

            _downloadQueue = const [];
            _activeDownloadType = null;
            _localModelDownloading = false;
            _localModelPaused = false;
            _pausedDownloadType = null;
            _localModelInstalling = false;
            _stopInstallWatchdog();
            _localModelError = base;
            _debugLog(
                'install: type=${type.name} failed error=$_localModelError');
            notifyListeners();
          }
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
          _localModelInstalling = false;
          _stopInstallWatchdog();
          final base = _formatError(e);

          _downloadQueue = const [];
          _activeDownloadType = null;
          _localModelDownloading = false;
          _localModelPaused = false;
          _pausedDownloadType = null;
          _localModelInstalling = false;
          _localModelError = base;
          _debugLog(
              'download: type=${type.name} failed error=$_localModelError');
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_localModelPaused) {
        _localModelDownloading = false;
        return;
      }
      _downloadQueue = const [];
      _activeDownloadType = null;
      _localModelDownloading = false;
      _localModelPaused = false;
      _pausedDownloadType = null;
      _localModelInstalling = false;
      _stopInstallWatchdog();
      _localModelError = _formatError(e);
      _debugLog('download: type=${type.name} failed error=$_localModelError');
      notifyListeners();
    }
  }

  Future<void> _installLocalModelFromZip(
    File zipFile,
    Directory modelDir,
    LocalLlmModelType type,
  ) async {
    final sw = Stopwatch()..start();
    final zipLen = await zipFile.length().catchError((_) => -1);
    _debugLog('install: zip=${zipFile.path} size=$zipLen');
    if (!await _looksLikeZip(zipFile)) {
      final preview = await _readFilePreview(zipFile);
      _debugLog('install: not a zip, preview=${preview.replaceAll('\n', ' ')}');
      final modelScopeMsg = _tryParseModelScopeErrorMessage(preview);
      if (modelScopeMsg != null && modelScopeMsg.trim().isNotEmpty) {
        throw Exception('模型下载失败：$modelScopeMsg');
      }
      throw Exception('模型安装失败：下载内容不是 zip 压缩包');
    }
    if (!await _looksLikeCompleteZip(zipFile)) {
      throw Exception('模型安装失败：zip 不完整');
    }
    final tmpDir = Directory(
      p.join(modelDir.parent.path, '${p.basename(modelDir.path)}.tmp'),
    );
    if (await tmpDir.exists()) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
    await tmpDir.create(recursive: true);
    String rootDirPath = '';
    try {
      rootDirPath = await _extractZipToTmpAndFindRootWithProgress(
        zipPath: zipFile.path,
        tmpDirPath: tmpDir.path,
      );
      final rootDir = Directory(rootDirPath);
      _debugLog(
          'install: rootDir=$rootDirPath elapsedMs=${sw.elapsedMilliseconds}');

      if (await modelDir.exists()) {
        try {
          await modelDir.delete(recursive: true);
        } catch (_) {}
      }
      await rootDir.rename(modelDir.path);
      if (await tmpDir.exists()) {
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {}
      }
      _debugLog('install: move done elapsedMs=${sw.elapsedMilliseconds}');
    } catch (e) {
      _debugLog(
          'install: extract failed elapsedMs=${sw.elapsedMilliseconds} error=${_formatError(e)}');
      rethrow;
    } finally {
      if (await tmpDir.exists()) {
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  String? _tryParseModelScopeErrorMessage(String preview) {
    final s = preview.trim();
    if (!s.startsWith('{') && !s.startsWith('[')) return null;
    try {
      final obj = jsonDecode(s);
      if (obj is Map) {
        final msg = obj['Message'];
        if (msg is String && msg.trim().isNotEmpty) return msg.trim();
      }
    } catch (_) {}
    return null;
  }

  Future<String> _extractZipToTmpAndFindRootWithProgress({
    required String zipPath,
    required String tmpDirPath,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _extractZipWorker,
      <String, dynamic>{
        'sendPort': receivePort.sendPort,
        'zipPath': zipPath,
        'tmpDirPath': tmpDirPath,
      },
      errorsAreFatal: true,
    );

    final completer = Completer<String>();
    Timer? timeout;

    void cleanUp() {
      timeout?.cancel();
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }

    timeout = Timer(const Duration(minutes: 30), () {
      if (completer.isCompleted) return;
      cleanUp();
      completer.completeError(Exception('模型安装失败：解压超时'));
    });

    receivePort.listen((dynamic msg) {
      if (completer.isCompleted) return;
      if (msg is Map) {
        final type = msg['type'];
        if (type == 'progress') {
          _startInstallWatchdog();
          final extracted = msg['extracted'];
          final total = msg['total'];
          final file = msg['file'];
          _debugLog('install: extract progress $extracted/$total file=$file');
          return;
        }
        if (type == 'done') {
          final rootDirPath = msg['rootDirPath'];
          cleanUp();
          completer.complete('$rootDirPath');
          return;
        }
        if (type == 'error') {
          final error = msg['error'];
          cleanUp();
          completer.completeError(Exception('$error'));
          return;
        }
      }
    });

    return completer.future;
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
    if (!isPause) {
      _pausedDownloadType = null;
    }
    if (_localModelDownloading) {
      _localModelDownloading = false;
      if (isPause) {
        _localModelPaused = true;
      } else {
        _localModelPaused = false;
      }
      changed = true;
    }
    if (_localModelInstalling) {
      _localModelInstalling = false;
      _stopInstallWatchdog();
      changed = true;
    }

    if (_downloadQueue.isNotEmpty || _activeDownloadType != null) {
      if (isPause && _pausedDownloadType == null) {
        _pausedDownloadType = _activeDownloadType;
      }
      _downloadQueue = const [];
      _activeDownloadType = null;
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
      _recomputeAggregateProgress();
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

    final scopeRaw = prefs.getString(_kQAContentScope);
    _qaContentScope = QAContentScope.values.firstWhere(
      (e) => e.name == scopeRaw,
      orElse: () => QAContentScope.slidingWindow,
    );

    _loaded = true;
    await refreshLocalModelStatus();
    await refreshLocalRuntimeStatus();
    notifyListeners();
  }
}

void _extractZipWorker(Map<String, dynamic> args) {
  final SendPort sendPort = args['sendPort'] as SendPort;
  try {
    final zipPath = (args['zipPath'] as String?) ?? '';
    final tmpDirPath = (args['tmpDirPath'] as String?) ?? '';
    if (zipPath.isEmpty || tmpDirPath.isEmpty) {
      throw Exception('模型安装失败：参数错误');
    }

    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final total = archive.files.length;
      int extracted = 0;
      for (final file in archive.files) {
        final rawName = file.name.replaceAll('\\', '/');
        final name = p.posix.normalize(rawName);
        if (name == '.' || name.startsWith('..') || p.posix.isAbsolute(name)) {
          extracted++;
          continue;
        }
        final outPath = p.joinAll(<String>[tmpDirPath, ...name.split('/')]);
        try {
          if (file.isFile) {
            final outFile = File(outPath);
            outFile.parent.createSync(recursive: true);
            final output = OutputFileStream(outFile.path);
            try {
              file.writeContent(output);
            } finally {
              output.close();
            }
          } else {
            Directory(outPath).createSync(recursive: true);
          }
        } catch (e) {
          throw Exception('模型安装失败：解压异常 file=$name error=$e');
        }
        extracted++;
        if (extracted == 1 || extracted % 40 == 0 || extracted == total) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'extracted': extracted,
            'total': total,
            'file': name,
          });
        }
      }
    } finally {
      input.close();
    }

    final configAtRoot = File(p.join(tmpDirPath, 'config.json'));
    if (configAtRoot.existsSync()) {
      sendPort.send(<String, dynamic>{
        'type': 'done',
        'rootDirPath': tmpDirPath,
      });
      return;
    }

    final tmodelsDirPath = p.join(tmpDirPath, 'tmodels');
    final configAtTmodels = File(p.join(tmodelsDirPath, 'config.json'));
    if (configAtTmodels.existsSync()) {
      sendPort.send(<String, dynamic>{
        'type': 'done',
        'rootDirPath': tmodelsDirPath,
      });
      return;
    }

    String? foundRoot;
    final entities =
        Directory(tmpDirPath).listSync(recursive: true, followLinks: false);
    for (final e in entities) {
      if (e is! File) continue;
      if (p.basename(e.path).toLowerCase() != 'config.json') continue;
      final norm = e.path.replaceAll('\\', '/');
      if (norm.contains('/__macosx/')) continue;
      foundRoot = p.dirname(e.path);
      break;
    }

    if (foundRoot == null) {
      throw Exception('模型安装失败：缺少 config.json');
    }
    sendPort.send(<String, dynamic>{
      'type': 'done',
      'rootDirPath': foundRoot,
    });
  } catch (e) {
    sendPort.send(<String, dynamic>{
      'type': 'error',
      'error': '$e',
    });
  }
}
