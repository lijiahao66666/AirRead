import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/local_llm/local_llm_client.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

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

  static const String _localModelCosBucket = 'hunyuan-mnn-1256643821';
  static const String _localModelCosRegion = 'ap-guangzhou';
  static const String _localModelCosObjectKey = 'hunyuan-1.8b-4bit-mnn.zip';
  static const String _localModelModelScopeUrl =
      'https://www.modelscope.cn/models/lijiahaojj/Hunyuan-0.5B-Instruct-mnn-int4/resolve/master/hunyuan-1.8b-4bit-mnn.zip';

  bool _loaded = false;
  AiModelSource _source = AiModelSource.none;

  bool _localModelExists = false;
  bool _localModelDownloading = false;
  bool _localModelPaused = false;
  bool _localModelInstalling = false;
  bool _localModelCorruptRetried = false;
  bool _localModelModelScopeFallbackRetried = false;
  double _localModelProgress = 0;
  String _localModelError = '';
  int _localModelDownloadedBytes = 0;
  int _localModelTotalBytes = 0;
  bool _localRuntimeAvailable = false;
  bool _localModelSmokeDone = false;

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

  Uri _buildLocalModelCosUri() {
    const host = '$_localModelCosBucket.cos.$_localModelCosRegion.myqcloud.com';
    return Uri(
      scheme: 'https',
      host: host,
      path: '/$_localModelCosObjectKey',
    );
  }

  Uri _buildLocalModelModelScopeUri() {
    return Uri.parse(_localModelModelScopeUrl);
  }

  String _buildCosAuthorization({
    required String method,
    required Uri uri,
    required String secretId,
    required String secretKey,
    required Map<String, String> headersToSign,
    required Map<String, String> urlParamsToSign,
  }) {
    final now = DateTime.now().toUtc();
    final start = now.subtract(const Duration(minutes: 5));
    final end = now.add(const Duration(hours: 12));
    final startTs = start.millisecondsSinceEpoch ~/ 1000;
    final endTs = end.millisecondsSinceEpoch ~/ 1000;
    final signTime = '$startTs;$endTs';
    final keyTime = signTime;

    final headerNames = headersToSign.keys
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    final urlParamNames = urlParamsToSign.keys
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();

    final headerList = headerNames.join(';');
    final urlParamList = urlParamNames.join(';');

    final canonicalHeaders = headerNames.map((k) {
      final v = headersToSign[k] ?? headersToSign[k.toLowerCase()] ?? '';
      return '$k=${Uri.encodeQueryComponent(v.trim())}';
    }).join('&');

    final canonicalQuery = urlParamNames.map((k) {
      final v = urlParamsToSign[k] ?? urlParamsToSign[k.toLowerCase()] ?? '';
      return '$k=${Uri.encodeQueryComponent(v.trim())}';
    }).join('&');

    final httpString =
        '${method.toLowerCase()}\n${uri.path}\n$canonicalQuery\n$canonicalHeaders\n';
    final httpStringSha1 = sha1.convert(utf8.encode(httpString)).toString();

    final stringToSign = 'sha1\n$signTime\n$httpStringSha1\n';
    final signKey = Hmac(sha1, utf8.encode(secretKey))
        .convert(utf8.encode(keyTime))
        .toString();
    final signature = Hmac(sha1, utf8.encode(signKey))
        .convert(utf8.encode(stringToSign))
        .toString();

    return [
      'q-sign-algorithm=sha1',
      'q-ak=$secretId',
      'q-sign-time=$signTime',
      'q-key-time=$keyTime',
      'q-header-list=$headerList',
      'q-url-param-list=$urlParamList',
      'q-signature=$signature',
    ].join('&');
  }

  QAContentScope get qaContentScope => _qaContentScope;

  bool get loaded => _loaded;
  AiModelSource get source => _source;

  bool get isModelEnabled => _source != AiModelSource.none;

  bool get localModelExists => _localModelExists;
  bool get localModelDownloading => _localModelDownloading;
  bool get localModelPaused => _localModelPaused;
  bool get localModelInstalling => _localModelInstalling;
  double get localModelProgress => _localModelProgress;
  String get localModelError => _localModelError;
  int get localModelDownloadedBytes => _localModelDownloadedBytes;
  int get localModelTotalBytes => _localModelTotalBytes;
  bool get localRuntimeAvailable => _localRuntimeAvailable;

  bool get isLocalModelReady =>
      _localModelExists &&
      _localRuntimeAvailable &&
      !_localModelDownloading &&
      !_localModelPaused &&
      !_localModelInstalling;

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

  Future<File> getLocalModelFile() async {
    return getLocalModelConfigFile();
  }

  Future<File> getLocalModelPartialFile() async {
    return getLocalModelZipPartialFile();
  }

  Future<Directory> getLocalModelDir() async {
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

  Future<File> getLocalModelConfigFile() async {
    final modelDir = await getLocalModelDir();
    return File(p.join(modelDir.path, 'config.json'));
  }

  Future<File> getLocalModelZipFile() async {
    final modelDir = await getLocalModelDir();
    return File(p.join(modelDir.path, 'model.zip'));
  }

  Future<File> getLocalModelZipPartialFile() async {
    final file = await getLocalModelZipFile();
    return File('${file.path}.partial');
  }

  Future<void> refreshLocalModelStatus() async {
    if (kIsWeb) {
      _localModelExists = false;
      notifyListeners();
      return;
    }
    final dir = await getLocalModelDir();
    final config = File(p.join(dir.path, 'config.json'));
    final llm = File(p.join(dir.path, 'llm.mnn'));
    final weight = File(p.join(dir.path, 'llm.mnn.weight'));
    final llmConfig = File(p.join(dir.path, 'llm_config.json'));
    final tokenizer = File(p.join(dir.path, 'tokenizer.txt'));

    final exists = await config.exists() &&
        await llm.exists() &&
        await weight.exists() &&
        await llmConfig.exists() &&
        await tokenizer.exists();

    int size = 0;
    if (exists) {
      final sizes = await Future.wait<int>([
        config.length(),
        llm.length(),
        weight.length(),
        llmConfig.length(),
        tokenizer.length(),
      ]);
      size = sizes.fold<int>(0, (a, b) => a + b);
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

  Future<void> _runLocalModelSmokeOnce() async {
    if (!_smokeTestLocalModel) return;
    if (_localModelSmokeDone) return;
    if (!_localModelExists || !_localRuntimeAvailable) return;
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

  Future<void> startLocalModelDownload({bool forceCos = false}) async {
    if (_localModelDownloading) return;
    if (_localModelInstalling) return;
    if (kIsWeb) {
      _localModelError = 'Web 端暂不支持下载本地模型';
      notifyListeners();
      return;
    }

    _debugLog('startLocalModelDownload: begin forceCos=$forceCos');
    final modelDir = await getLocalModelDir();
    final targetZipFile = await getLocalModelZipFile();
    final partialZipFile = await getLocalModelZipPartialFile();
    final configFile = await getLocalModelConfigFile();

    if (await configFile.exists()) {
      await refreshLocalModelStatus();
      await refreshLocalRuntimeStatus();
      unawaited(_runLocalModelSmokeOnce());
      if (_localModelExists) return;
    }

    await modelDir.create(recursive: true);

    int existing = 0;
    if (await partialZipFile.exists()) {
      existing = await partialZipFile.length();
    }
    if (existing == 0) {
      _localModelCorruptRetried = false;
      _localModelModelScopeFallbackRetried = false;
    }
    _debugLog(
        'download: primaryUri=${_buildLocalModelModelScopeUri()} fallbackUri=${_buildLocalModelCosUri()} existingBytes=$existing forceCos=$forceCos');

    _localModelDownloading = true;
    _localModelPaused = false;
    _localModelInstalling = false;
    _localModelError = '';
    // If resuming, don't reset total bytes if we already knew it (though usually 0 on restart app)
    // But if we are starting fresh or resuming, existing bytes is correct.
    _localModelDownloadedBytes = existing;
    notifyListeners();

    _downloadClient?.close();
    _downloadClient = http.Client();

    try {
      http.StreamedResponse resp;
      bool usedFallbackCos = false;
      String? modelScopeError;

      Future<http.StreamedResponse> sendCos() async {
        final creds = getEmbeddedPublicHunyuanCredentials();
        if (!creds.isUsable) {
          throw const HttpException('缺少腾讯 COS 鉴权信息');
        }

        final uri = _buildLocalModelCosUri();
        int attempts = 0;
        http.StreamedResponse resp;
        while (true) {
          final req = http.Request('GET', uri);
          final headersToSign = <String, String>{
            'host': uri.host,
            if (existing > 0) 'range': 'bytes=$existing-',
          };
          final authorization = _buildCosAuthorization(
            method: 'GET',
            uri: uri,
            secretId: creds.secretId,
            secretKey: creds.secretKey,
            headersToSign: headersToSign,
            urlParamsToSign: uri.queryParameters,
          );
          req.headers['Host'] = uri.host;
          req.headers['Authorization'] = authorization;
          req.headers['Accept-Encoding'] = 'identity';
          if (existing > 0) {
            req.headers['Range'] = 'bytes=$existing-';
          }
          _debugLog(
              'download: cos send attempt=$attempts range=${req.headers['Range'] ?? ''}');
          resp = await _downloadClient!.send(req);
          _debugLog(
              'download: cos resp status=${resp.statusCode} contentLength=${resp.contentLength}');
          _debugLog(
              'download: cos headers contentEncoding=${resp.headers['content-encoding'] ?? ''} contentType=${resp.headers['content-type'] ?? ''} contentRange=${resp.headers['content-range'] ?? ''}');

          if ((resp.statusCode == 401 || resp.statusCode == 403) &&
              existing > 0 &&
              attempts == 0) {
            attempts++;
            try {
              await partialZipFile.delete();
            } catch (_) {}
            existing = 0;
            _localModelDownloadedBytes = 0;
            notifyListeners();
            continue;
          }
          break;
        }

        if (resp.statusCode != 200 && resp.statusCode != 206) {
          if (resp.statusCode == 403) {
            throw const HttpException('COS 下载无权限（HTTP 403）');
          }
          if (resp.statusCode == 401) {
            throw const HttpException('COS 下载鉴权失败（HTTP 401）');
          }
          throw HttpException('COS 下载失败：HTTP ${resp.statusCode}');
        }
        return resp;
      }

      if (forceCos) {
        usedFallbackCos = true;
        resp = await sendCos();
      } else {
        try {
          final uri = _buildLocalModelModelScopeUri();
          final req = http.Request('GET', uri);
          req.headers['Accept-Encoding'] = 'identity';
          if (existing > 0) {
            req.headers['Range'] = 'bytes=$existing-';
          }
          _debugLog(
              'download: modelscope send range=${req.headers['Range'] ?? ''}');
          resp = await _downloadClient!.send(req);
          _debugLog(
              'download: modelscope resp status=${resp.statusCode} contentLength=${resp.contentLength}');
          _debugLog(
              'download: modelscope headers contentEncoding=${resp.headers['content-encoding'] ?? ''} contentType=${resp.headers['content-type'] ?? ''} contentRange=${resp.headers['content-range'] ?? ''}');
          if (resp.statusCode != 200 && resp.statusCode != 206) {
            throw HttpException('ModelScope 下载失败：HTTP ${resp.statusCode}');
          }
        } catch (e) {
          usedFallbackCos = true;
          modelScopeError = _formatError(e);
          resp = await sendCos();
        }
      }

      final isPartial = resp.statusCode == 206;
      if (existing > 0 && !isPartial) {
        try {
          await partialZipFile.delete();
        } catch (_) {}
        existing = 0;
        _localModelDownloadedBytes = 0;
      }

      final respLength = resp.contentLength ?? 0;
      final totalFromRange =
          _tryParseTotalBytesFromContentRange(resp.headers['content-range']);
      _localModelTotalBytes = totalFromRange ?? (existing + respLength);
      notifyListeners();
      _debugLog(
          'download: totalBytes=$_localModelTotalBytes existingBytes=$existing');

      _downloadSink = partialZipFile.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write,
      );
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
          try {
            _debugLog(
                'download: stream done, downloadedBytes=$_localModelDownloadedBytes');
            await _downloadSink?.flush();
            await _downloadSink?.close();
            _downloadSink = null;
            _downloadSub = null;

            if (_localModelTotalBytes > 0 &&
                _localModelDownloadedBytes != _localModelTotalBytes) {
              throw Exception(
                '模型下载失败：下载字节数不匹配（$_localModelDownloadedBytes/$_localModelTotalBytes）',
              );
            }

            if (await targetZipFile.exists()) {
              try {
                await targetZipFile.delete();
              } catch (_) {}
            }
            _debugLog('install: rename partial -> zip');
            await partialZipFile.rename(targetZipFile.path);

            _localModelInstalling = true;
            _startInstallWatchdog();
            notifyListeners();
            _debugLog('install: begin');
            await _installLocalModelFromZip(targetZipFile, modelDir);
            _debugLog('install: unzip done, cleanup zip');
            try {
              await targetZipFile.delete();
            } catch (_) {}

            _localModelDownloading = false;
            _localModelPaused = false;
            _localModelInstalling = false;
            _stopInstallWatchdog();
            await refreshLocalModelStatus();
            await refreshLocalRuntimeStatus();
            unawaited(_runLocalModelSmokeOnce());
            _debugLog('install: completed localModelExists=$_localModelExists');
          } catch (e) {
            final raw = '$e';
            final base = _formatError(e);
            final isNotZip =
                base.contains('不是 zip') || base.contains('not a zip');
            if (isNotZip &&
                !forceCos &&
                !usedFallbackCos &&
                !_localModelModelScopeFallbackRetried) {
              _localModelModelScopeFallbackRetried = true;
              _debugLog('install: modelscope not zip, fallback to cos');
              try {
                await targetZipFile.delete();
              } catch (_) {}
              try {
                await partialZipFile.delete();
              } catch (_) {}
              _localModelDownloading = false;
              _localModelPaused = false;
              _localModelInstalling = false;
              _stopInstallWatchdog();
              _localModelError = 'ModelScope 返回内容异常，正在改用腾讯 COS 下载…';
              _localModelDownloadedBytes = 0;
              _localModelTotalBytes = 0;
              _localModelProgress = 0;
              notifyListeners();
              _downloadClient?.close();
              _downloadClient = null;
              await Future<void>.delayed(const Duration(milliseconds: 80));
              _debugLog('install: retry startLocalModelDownload forceCos=true');
              unawaited(startLocalModelDownload(forceCos: true));
              return;
            }
            final isCorruptZip = e is FormatException ||
                raw.contains('Filter error') ||
                raw.contains('bad data') ||
                base.contains('zip 不完整') ||
                base.contains('下载字节数不匹配');
            if (isCorruptZip && !_localModelCorruptRetried) {
              _localModelCorruptRetried = true;
              if (!forceCos && !usedFallbackCos) {
                _debugLog(
                    'install: zip corrupt from modelscope, fallback to cos');
              } else {
                _debugLog('install: zip corrupt, will retry download once');
              }
              try {
                await targetZipFile.delete();
              } catch (_) {}
              try {
                await partialZipFile.delete();
              } catch (_) {}
              _localModelDownloading = false;
              _localModelPaused = false;
              _localModelInstalling = false;
              _stopInstallWatchdog();
              if (!forceCos && !usedFallbackCos) {
                _localModelError = 'ModelScope 压缩包损坏，正在改用腾讯 COS 重新下载…';
              } else {
                _localModelError = '压缩包损坏，正在重新下载…';
              }
              _localModelDownloadedBytes = 0;
              _localModelTotalBytes = 0;
              _localModelProgress = 0;
              notifyListeners();
              _downloadClient?.close();
              _downloadClient = null;
              await Future<void>.delayed(const Duration(milliseconds: 80));
              final retryForceCos = !forceCos && !usedFallbackCos
                  ? true
                  : (forceCos || usedFallbackCos);
              _debugLog(
                  'install: retry startLocalModelDownload forceCos=$retryForceCos');
              unawaited(startLocalModelDownload(forceCos: retryForceCos));
              return;
            }
            _localModelDownloading = false;
            _localModelPaused = false;
            _localModelInstalling = false;
            _stopInstallWatchdog();
            if (usedFallbackCos && modelScopeError != null) {
              _localModelError = 'ModelScope 下载失败：$modelScopeError；$base';
            } else {
              _localModelError = base;
            }
            _debugLog('install: failed error=$_localModelError');
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
          _localModelDownloading = false;
          _localModelPaused = false;
          _localModelInstalling = false;
          _stopInstallWatchdog();
          final base = _formatError(e);
          if (!forceCos &&
              !usedFallbackCos &&
              !_localModelModelScopeFallbackRetried) {
            _localModelModelScopeFallbackRetried = true;
            _debugLog('download: modelscope stream error, fallback to cos');
            try {
              await targetZipFile.delete();
            } catch (_) {}
            try {
              await partialZipFile.delete();
            } catch (_) {}
            _localModelError = 'ModelScope 下载失败，正在改用腾讯 COS 下载…';
            _localModelDownloadedBytes = 0;
            _localModelTotalBytes = 0;
            _localModelProgress = 0;
            notifyListeners();
            _downloadClient?.close();
            _downloadClient = null;
            await Future<void>.delayed(const Duration(milliseconds: 80));
            _debugLog('download: retry startLocalModelDownload forceCos=true');
            unawaited(startLocalModelDownload(forceCos: true));
            return;
          }
          if (usedFallbackCos && modelScopeError != null) {
            _localModelError = 'ModelScope 下载失败：$modelScopeError；$base';
          } else {
            _localModelError = base;
          }
          _debugLog('download: stream error=$_localModelError');
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
      _localModelInstalling = false;
      _stopInstallWatchdog();
      _localModelError = _formatError(e);
      _debugLog('download: failed error=$_localModelError');
      notifyListeners();
    }
  }

  Future<void> _installLocalModelFromZip(
    File zipFile,
    Directory modelDir,
  ) async {
    final sw = Stopwatch()..start();
    final zipLen = await zipFile.length().catchError((_) => -1);
    _debugLog('install: zip=${zipFile.path} size=$zipLen');
    if (!await _looksLikeZip(zipFile)) {
      final preview = await _readFilePreview(zipFile);
      _debugLog('install: not a zip, preview=${preview.replaceAll('\n', ' ')}');
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
