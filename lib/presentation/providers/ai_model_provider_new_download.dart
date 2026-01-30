// 新的 GGUF 模型下载方法
// 请将此方法添加到 AiModelProvider 类中

  /// 下载 GGUF 格式模型（llama.cpp）
  Future<void> _startLlamaModelDownload() async {
    if (_localModelPaused) return;

    final modelPath = await LlamaModelDownloader.getModelPath();
    final partialPath = '$modelPath.partial';
    final partialFile = File(partialPath);
    final targetFile = File(modelPath);

    // 检查是否已存在
    if (await targetFile.exists() && await targetFile.length() > 0) {
      final size = await targetFile.length();
      _localModelExistsByType[LocalLlmModelType.qa] = true;
      _installedBytesByType[LocalLlmModelType.qa] = size;
      _downloadedBytesByType[LocalLlmModelType.qa] = size;
      _totalBytesByType[LocalLlmModelType.qa] = size;
      _recomputeAggregateProgress();
      notifyListeners();
      
      // 加载模型
      await _loadLlamaModel();
      
      _downloadQueue = const [];
      _activeDownloadType = null;
      _localModelDownloading = false;
      notifyListeners();
      return;
    }

    int existing = 0;
    if (await partialFile.exists()) {
      existing = await partialFile.length();
    }

    if (existing == 0) {
      _downloadedBytesByType[LocalLlmModelType.qa] = 0;
      _totalBytesByType[LocalLlmModelType.qa] = 0;
    } else {
      _downloadedBytesByType[LocalLlmModelType.qa] = existing;
    }

    _recomputeAggregateProgress();
    notifyListeners();

    _downloadClient?.close();
    _downloadClient = http.Client();

    try {
      final uri = Uri.parse(_localModelUrl);
      final req = http.Request('GET', uri);
      req.headers['Accept-Encoding'] = 'identity';
      if (existing > 0) {
        req.headers['Range'] = 'bytes=$existing-';
      }
      _debugLog(
          'download: llama modelscope send range=${req.headers['Range'] ?? ''}');
      
      final resp = await _downloadClient!.send(req);
      _debugLog(
          'download: llama modelscope resp status=${resp.statusCode} contentLength=${resp.contentLength}');
      
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('ModelScope 下载失败：HTTP ${resp.statusCode}');
      }

      final isPartial = resp.statusCode == 206;
      if (existing > 0 && !isPartial) {
        try {
          await partialFile.delete();
        } catch (_) {}
        existing = 0;
        _downloadedBytesByType[LocalLlmModelType.qa] = 0;
      }

      final respLength = resp.contentLength ?? 0;
      final totalFromRange =
          _tryParseTotalBytesFromContentRange(resp.headers['content-range']);
      _totalBytesByType[LocalLlmModelType.qa] = totalFromRange ?? (existing + respLength);
      _recomputeAggregateProgress();
      notifyListeners();
      _debugLog(
          'download: llama totalBytes=${_totalBytesByType[LocalLlmModelType.qa]} existingBytes=$existing');

      _downloadSink = partialFile.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write,
      );
      
      _downloadSub = resp.stream.listen(
        (chunk) {
          _downloadSink?.add(chunk);
          _downloadedBytesByType[LocalLlmModelType.qa] =
              (_downloadedBytesByType[LocalLlmModelType.qa] ?? 0) + chunk.length;
          _recomputeAggregateProgress();
          notifyListeners();
        },
        onDone: () async {
          try {
            await _downloadSink?.flush();
            await _downloadSink?.close();
            _downloadSink = null;
            _downloadSub = null;

            final total = _totalBytesByType[LocalLlmModelType.qa] ?? 0;
            final downloaded = _downloadedBytesByType[LocalLlmModelType.qa] ?? 0;
            if (total > 0 && downloaded != total) {
              throw Exception(
                '模型下载失败：下载字节数不匹配（$downloaded/$total）',
              );
            }

            // 重命名为最终文件
            _debugLog('install: llama rename partial -> gguf');
            await partialFile.rename(targetFile.path);

            // 更新状态
            final size = await targetFile.length();
            _localModelExistsByType[LocalLlmModelType.qa] = true;
            _installedBytesByType[LocalLlmModelType.qa] = size;
            _downloadedBytesByType[LocalLlmModelType.qa] = size;
            _totalBytesByType[LocalLlmModelType.qa] = size;
            _recomputeAggregateProgress();

            // 加载模型
            await _loadLlamaModel();

            _downloadQueue = const [];
            _activeDownloadType = null;
            _localModelDownloading = false;
            notifyListeners();
          } catch (e) {
            _downloadQueue = const [];
            _activeDownloadType = null;
            _localModelDownloading = false;
            _localModelError = _formatError(e);
            _debugLog(
                'install: llama failed error=$_localModelError');
            notifyListeners();
          }
        },
        onError: (e) async {
          await _downloadSink?.flush().catchError((_) {});
          await _downloadSink?.close().catchError((_) {});
          _downloadSink = null;
          _downloadSub = null;
          _localModelInstalling = false;
          final base = _formatError(e);

          _downloadQueue = const [];
          _activeDownloadType = null;
          _localModelDownloading = false;
          _localModelError = base;
          _debugLog(
              'download: llama failed error=$_localModelError');
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
      _localModelError = _formatError(e);
      _debugLog('download: llama failed error=$_localModelError');
      notifyListeners();
    }
  }

  /// 加载 llama.cpp 模型
  Future<void> _loadLlamaModel() async {
    try {
      final modelPath = await LlamaModelDownloader.getModelPath();
      final llamaClient = LlamaCppClient();
      
      final success = await llamaClient.initialize(
        modelPath: modelPath,
        nCtx: 4096,
      );
      
      if (success) {
        _localRuntimeAvailable = true;
        _debugLog('llama: model loaded successfully');
      } else {
        _localRuntimeAvailable = false;
        _debugLog('llama: failed to load model');
      }
    } catch (e) {
      _localRuntimeAvailable = false;
      _debugLog('llama: error loading model: $e');
    }
    notifyListeners();
  }
