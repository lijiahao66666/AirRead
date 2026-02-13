import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../ai/manga/manga_panel.dart';
import '../../ai/manga/manga_service.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

class MangaProvider extends ChangeNotifier {
  final Map<String, _MangaCacheEntry> _cache = {};
  final Set<String> _analyzingKeys = {};
  final Set<String> _generatingPanelIds = {};
  final Map<String, Completer<List<MangaPanel>>> _analysisInFlight = {};

  String? _storagePath;
  Future<void>? _initFuture;

  MangaProvider() {
    _initFuture = _init();
  }

  Future<void> _init() async {
    if (kIsWeb) {
      _storagePath = '';
      notifyListeners();
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storagePath = dir.path;
    } on MissingPluginException {
      _storagePath = Directory.systemTemp.path;
    } catch (_) {
      _storagePath = Directory.systemTemp.path;
    }
    notifyListeners();
  }

  Future<void> _ensureReady() async {
    if (_storagePath != null) return;
    await (_initFuture ??= _init());
  }

  MangaService _buildService() {
    final storage = _storagePath;
    if (storage == null) {
      throw StateError('MangaProvider is not initialized');
    }
    return MangaService(
      credentials: getEmbeddedPublicHunyuanCredentials(),
      baseStoragePath: storage,
    );
  }

  String buildCacheKey({
    required String chapterId,
    required String modelKey,
    required bool thinkingEnabled,
    required int panelCount,
    required int autoRenderCount,
    required String styleKey,
    required String ratioKey,
  }) {
    return '$chapterId::m$modelKey::t${thinkingEnabled ? 1 : 0}::p$panelCount::a$autoRenderCount::s$styleKey::r$ratioKey';
  }

  bool isAnalyzing(String cacheKey) => _analyzingKeys.contains(cacheKey);

  bool isGeneratingPanel(String panelId) => _generatingPanelIds.contains(panelId);

  List<MangaPanel> getPanels(String cacheKey) {
    return _cache[cacheKey]?.panels ?? const <MangaPanel>[];
  }

  bool hasCache(String cacheKey) => _cache.containsKey(cacheKey);

  void clearChapter(String chapterId) {
    final keys = _cache.keys.where((k) => k.startsWith('$chapterId::')).toList();
    if (keys.isEmpty) return;
    for (final k in keys) {
      _cache.remove(k);
      _analysisInFlight.remove(k);
      _analyzingKeys.remove(k);
    }
    notifyListeners();
  }

  List<String> _splitParagraphsForAnalysis(String content) {
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final parts = normalized.split(RegExp(r'\n{2,}'));
    final out = <String>[];
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      out.add(t);
    }
    return out;
  }

  Future<List<MangaPanel>> analyzeChapter({
    required String chapterId,
    required String chapterTitle,
    required String content,
    required String modelKey,
    required bool thinkingEnabled,
    required int panelCount,
    required int autoRenderCount,
    required String styleKey,
    required String ratioKey,
    required String stylePrefix,
    required String resolution,
    Future<String> Function(String prompt)? generateText,
    bool? enableThinkingForOnline,
    bool force = false,
  }) async {
    await _ensureReady();
    final cacheKey = buildCacheKey(
      chapterId: chapterId,
      modelKey: modelKey,
      thinkingEnabled: thinkingEnabled,
      panelCount: panelCount,
      autoRenderCount: autoRenderCount,
      styleKey: styleKey,
      ratioKey: ratioKey,
    );

    if (!force && _cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!.panels;
    }
    final inflight = _analysisInFlight[cacheKey];
    if (inflight != null) return inflight.future;

    final completer = Completer<List<MangaPanel>>();
    _analysisInFlight[cacheKey] = completer;
    _analyzingKeys.add(cacheKey);
    notifyListeners();

    try {
      final paragraphs = _splitParagraphsForAnalysis(content);
      final panels = await _buildService().generateStoryboard(
        paragraphs: paragraphs,
        chapterTitle: chapterTitle,
        panelCount: panelCount,
        run: generateText,
        enableThinking: enableThinkingForOnline,
        debugName: cacheKey,
      );

      final entry = _MangaCacheEntry(
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        paragraphs: paragraphs,
        panels: panels,
        modelKey: modelKey,
        thinkingEnabled: thinkingEnabled,
        panelCount: panelCount,
        autoRenderCount: autoRenderCount,
        stylePrefix: stylePrefix,
        resolution: resolution,
      );
      _cache[cacheKey] = entry;
      completer.complete(List<MangaPanel>.unmodifiable(panels));
      _analysisInFlight.remove(cacheKey);
      _analyzingKeys.remove(cacheKey);
      notifyListeners();

      final autoN = autoRenderCount.clamp(0, panels.length);
      if (autoN > 0) {
        unawaited(_autoRender(
          cacheKey: cacheKey,
          count: autoN,
          generateText: generateText,
        ));
      }
      return panels;
    } catch (e) {
      _analysisInFlight.remove(cacheKey);
      _analyzingKeys.remove(cacheKey);
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _autoRender({
    required String cacheKey,
    required int count,
    Future<String> Function(String prompt)? generateText,
  }) async {
    final entry = _cache[cacheKey];
    if (entry == null) return;
    final panels = entry.panels;
    for (int i = 0; i < count && i < panels.length; i++) {
      final p = panels[i];
      if (p.status == MangaPanelStatus.completed) continue;
      await generateImage(
        cacheKey: cacheKey,
        panelId: p.id,
        generateText: generateText,
      );
    }
  }

  Future<void> generateImage({
    required String cacheKey,
    required String panelId,
    Future<String> Function(String prompt)? generateText,
    bool? enableThinkingForOnline,
  }) async {
    final entry = _cache[cacheKey];
    if (entry == null) return;
    final idx = entry.panels.indexWhere((e) => e.id == panelId);
    if (idx < 0) return;
    final panel = entry.panels[idx];
    if (panel.status == MangaPanelStatus.generating) return;
    if (_generatingPanelIds.contains(panelId)) return;
    _generatingPanelIds.add(panelId);

    try {
      panel.errorMsg = null;
      if ((panel.expandedPrompt ?? '').trim().isEmpty) {
        final prompt = await _buildService().expandPanelPrompt(
          panel: panel,
          paragraphs: entry.paragraphs,
          chapterTitle: entry.chapterTitle,
          stylePrefix: entry.stylePrefix,
          run: generateText,
          enableThinking: enableThinkingForOnline,
        );
        panel.expandedPrompt = prompt;
        panel.status = MangaPanelStatus.promptReady;
        notifyListeners();
      }

      panel.status = MangaPanelStatus.generating;
      notifyListeners();

      final jobId = await _buildService().submitGeneration(
        prompt: panel.expandedPrompt ?? '',
        resolution: entry.resolution,
      );
      panel.jobId = jobId;
      notifyListeners();

      final localPath = await _buildService().pollJobStatus(jobId);
      panel.localImagePath = localPath;
      panel.status = MangaPanelStatus.completed;
      notifyListeners();
    } catch (e) {
      panel.status = MangaPanelStatus.failed;
      panel.errorMsg = e.toString();
      notifyListeners();
    } finally {
      _generatingPanelIds.remove(panelId);
    }
  }
}

class _MangaCacheEntry {
  final String chapterId;
  final String chapterTitle;
  final List<String> paragraphs;
  final List<MangaPanel> panels;
  final String modelKey;
  final bool thinkingEnabled;
  final int panelCount;
  final int autoRenderCount;
  final String stylePrefix;
  final String resolution;

  _MangaCacheEntry({
    required this.chapterId,
    required this.chapterTitle,
    required this.paragraphs,
    required this.panels,
    required this.modelKey,
    required this.thinkingEnabled,
    required this.panelCount,
    required this.autoRenderCount,
    required this.stylePrefix,
    required this.resolution,
  });
}
