import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../ai/illustration/illustration_item.dart';
import '../../ai/illustration/illustration_service.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

class IllustrationProvider extends ChangeNotifier {
  final Map<String, _IllustrationCacheEntry> _cache = {};
  final Set<String> _analyzingKeys = {};
  final Set<String> _generatingIds = {};
  final Map<String, Completer<List<IllustrationItem>>> _analysisInFlight = {};

  String _expandPromptForImage(String s) {
    var t = s.trim();
    t = t.replaceAll(RegExp(r'[；;]\s*'), '，');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r'，{2,}'), '，');
    if (t.endsWith('，')) t = t.substring(0, t.length - 1).trim();
    if (t.length < 45) {
      t = '$t，人物表情细腻，服饰道具清晰，背景层次丰富';
    }
    return t;
  }

  String? _storagePath;
  Future<void>? _initFuture;

  IllustrationProvider() {
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

  IllustrationService _buildService() {
    final storage = _storagePath;
    if (storage == null) {
      throw StateError('IllustrationProvider is not initialized');
    }
    return IllustrationService(
      credentials: getEmbeddedPublicHunyuanCredentials(),
      baseStoragePath: storage,
    );
  }

  String buildCacheKey({
    required String chapterId,
    required String modelKey,
    required bool thinkingEnabled,
    required int count,
    required String styleKey,
    required String ratioKey,
  }) {
    return '$chapterId::il$modelKey::t${thinkingEnabled ? 1 : 0}::c$count::s$styleKey::r$ratioKey';
  }

  bool isAnalyzing(String cacheKey) => _analyzingKeys.contains(cacheKey);

  bool isGenerating(String itemId) => _generatingIds.contains(itemId);

  List<IllustrationItem> getItems(String cacheKey) {
    return _cache[cacheKey]?.items ?? const <IllustrationItem>[];
  }

  bool hasCache(String cacheKey) => _cache.containsKey(cacheKey);

  bool updatePrompt({
    required String cacheKey,
    required String itemId,
    required String prompt,
  }) {
    final entry = _cache[cacheKey];
    if (entry == null) return false;
    final idx = entry.items.indexWhere((e) => e.id == itemId);
    if (idx < 0) return false;
    entry.items[idx].prompt = prompt.trim();
    notifyListeners();
    return true;
  }

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
      if (t.length <= 900) {
        out.add(t);
        continue;
      }

      final byLine = t.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty);
      final byLineList = byLine.toList();
      if (byLineList.length > 1) {
        for (final line in byLineList) {
          if (line.length <= 900) {
            out.add(line);
          } else {
            out.addAll(_splitLongTextBySentence(line, maxLen: 520));
          }
        }
        continue;
      }

      out.addAll(_splitLongTextBySentence(t, maxLen: 520));
    }
    return out;
  }

  List<String> _splitLongTextBySentence(String text, {required int maxLen}) {
    final t = text.trim();
    if (t.isEmpty) return const <String>[];
    if (t.length <= maxLen) return <String>[t];

    final out = <String>[];
    final parts = t.split(RegExp(r'(?<=[。！？!?])'));
    final buf = StringBuffer();
    for (final p in parts) {
      final s = p.trim();
      if (s.isEmpty) continue;
      if (buf.isEmpty) {
        buf.write(s);
        continue;
      }
      if (buf.length + s.length + 1 <= maxLen) {
        buf.write(s);
      } else {
        out.add(buf.toString().trim());
        buf
          ..clear()
          ..write(s);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString().trim());

    final clipped = <String>[];
    for (final s in out) {
      if (s.length <= maxLen) {
        clipped.add(s);
      } else {
        int start = 0;
        while (start < s.length) {
          final end = (start + maxLen).clamp(0, s.length);
          clipped.add(s.substring(start, end));
          start = end;
        }
      }
    }
    return clipped;
  }

  Future<List<IllustrationItem>> generateChapterIllustrations({
    required String chapterId,
    required String chapterTitle,
    required String content,
    required String modelKey,
    required bool thinkingEnabled,
    required int count,
    required String styleKey,
    required String ratioKey,
    required String stylePrefix,
    required String resolution,
    required bool useLocalModel,
    Future<String> Function(String prompt)? generateText,
    bool? enableThinkingForOnline,
    bool force = false,
  }) async {
    await _ensureReady();
    final cacheKey = buildCacheKey(
      chapterId: chapterId,
      modelKey: modelKey,
      thinkingEnabled: thinkingEnabled,
      count: count,
      styleKey: styleKey,
      ratioKey: ratioKey,
    );

    if (!force && _cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!.items;
    }
    final inflight = _analysisInFlight[cacheKey];
    if (inflight != null) return inflight.future;

    final completer = Completer<List<IllustrationItem>>();
    _analysisInFlight[cacheKey] = completer;
    _analyzingKeys.add(cacheKey);
    notifyListeners();

    try {
      final paragraphs = _splitParagraphsForAnalysis(content);
      final items = await _buildService().generateIllustrations(
        paragraphs: paragraphs,
        chapterTitle: chapterTitle,
        count: count,
        useLocalModel: useLocalModel,
        run: generateText,
        enableThinking: enableThinkingForOnline,
        debugName: cacheKey,
      );

      final entry = _IllustrationCacheEntry(
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        paragraphs: paragraphs,
        items: items,
        modelKey: modelKey,
        thinkingEnabled: thinkingEnabled,
        count: count,
        stylePrefix: stylePrefix,
        resolution: resolution,
      );
      _cache[cacheKey] = entry;
      completer.complete(List<IllustrationItem>.unmodifiable(items));
      _analysisInFlight.remove(cacheKey);
      _analyzingKeys.remove(cacheKey);
      notifyListeners();

      return items;
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

  Future<void> generateImage({
    required String cacheKey,
    required String itemId,
  }) async {
    final entry = _cache[cacheKey];
    if (entry == null) return;
    final idx = entry.items.indexWhere((e) => e.id == itemId);
    if (idx < 0) return;
    final item = entry.items[idx];
    if (item.status == IllustrationStatus.generating) return;
    if (_generatingIds.contains(itemId)) return;
    _generatingIds.add(itemId);

    try {
      item.errorMsg = null;
      if ((item.prompt ?? '').trim().isEmpty) {
        throw StateError('画面描述为空，无法生成图片');
      }

      item.status = IllustrationStatus.generating;
      notifyListeners();

      final imageDesc = _expandPromptForImage(item.prompt!);
      final fullPrompt =
          '${entry.stylePrefix}, $imageDesc, 高细节，清晰构图，景深，质感细腻';
      final jobId = await _buildService().submitGeneration(
        prompt: fullPrompt,
        resolution: entry.resolution,
      );
      item.jobId = jobId;
      notifyListeners();

      final localPath = await _buildService().pollJobStatus(jobId);
      item.localImagePath = localPath;
      item.status = IllustrationStatus.completed;
      notifyListeners();
    } catch (e) {
      item.status = IllustrationStatus.failed;
      item.errorMsg = e.toString();
      notifyListeners();
    } finally {
      _generatingIds.remove(itemId);
    }
  }
}

class _IllustrationCacheEntry {
  final String chapterId;
  final String chapterTitle;
  final List<String> paragraphs;
  final List<IllustrationItem> items;
  final String modelKey;
  final bool thinkingEnabled;
  final int count;
  final String stylePrefix;
  final String resolution;

  _IllustrationCacheEntry({
    required this.chapterId,
    required this.chapterTitle,
    required this.paragraphs,
    required this.items,
    required this.modelKey,
    required this.thinkingEnabled,
    required this.count,
    required this.stylePrefix,
    required this.resolution,
  });
}
