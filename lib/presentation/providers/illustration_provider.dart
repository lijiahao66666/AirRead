import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../ai/illustration/illustration_service.dart';
import '../../ai/illustration/scene_card.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';

class IllustrationProvider extends ChangeNotifier {
  // 章节 ID -> 场景卡片列表
  final Map<String, List<SceneCard>> _cache = {};

  // 正在生成的任务 ID 集合
  final Set<String> _generatingTaskIds = {};

  // 串行分析队列
  final Queue<_AnalysisTask> _analysisQueue = Queue();
  bool _isAnalyzing = false;
  final Set<String> _analyzingChapterIds = {};
  final Map<String, Completer<List<SceneCard>>> _analysisInFlight = {};

  bool isAnalyzing(String chapterId) =>
      _analyzingChapterIds.contains(chapterId);
  UnmodifiableSetView<String> get analyzingChapterIds =>
      UnmodifiableSetView(_analyzingChapterIds);
  bool isAnalyzingOrQueued(String chapterId) =>
      _analysisInFlight.containsKey(chapterId);

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
      final docDir = await getApplicationDocumentsDirectory();
      _storagePath = docDir.path;
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

  List<SceneCard> getScenes(String chapterId) {
    return _cache[chapterId] ?? [];
  }

  bool hasChapter(String chapterId) => _cache.containsKey(chapterId);

  void clearChapter(String chapterId) {
    if (!_cache.containsKey(chapterId)) return;
    _cache.remove(chapterId);
    notifyListeners();
  }

  void updateScenePrompt({
    required String chapterId,
    required String sceneId,
    required String prompt,
  }) {
    final scenes = _cache[chapterId];
    if (scenes == null || scenes.isEmpty) return;
    final idx = scenes.indexWhere((e) => e.id == sceneId);
    if (idx < 0) return;
    scenes[idx].action = _normalizeScenePrompt(prompt);
    notifyListeners();
  }

  String _normalizeScenePrompt(String input) {
    var s = input.replaceAll('\u0000', '');
    s = s.replaceAll(RegExp(r'\\[nrt]'), ' ');
    s = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  Future<List<SceneCard>> analyzeSelectionForChapter({
    required String chapterId,
    required String chapterTitle,
    required String selectionText,
    required int paragraphIndex,
    int? pointsBalance,
    Future<String> Function(String prompt)? generateText,
  }) async {
    await _ensureReady();
    if (generateText == null && !usingPersonalTencentKeys()) {
      final available = pointsBalance ?? 0;
      if (available <= 0) {
        throw StateError('插图需要购买积分后使用');
      }
    }

    final inflightKey =
        '$chapterId::sel::${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<List<SceneCard>>();
    _analysisInFlight[inflightKey] = completer;
    final task = _AnalysisTask(
      taskId: inflightKey,
      outputChapterId: chapterId,
      chapterTitle: chapterTitle,
      paragraphs: [selectionText.trim()],
      maxScenes: 1,
      generateText: generateText,
      fixedParagraphIndex: paragraphIndex,
      mergeIntoExisting: true,
      markChapterAnalyzing: false,
      completer: completer,
    );
    _analysisQueue.add(task);
    _processAnalysisQueue();
    return completer.future;
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

  /// 分析章节生成场景卡片
  Future<void> analyzeChapter({
    required String chapterId,
    required String chapterTitle,
    required String content,
    required int maxScenes,
    bool force = false,
    int? pointsBalance,
    Future<String> Function(String prompt)? generateText,
  }) async {
    await _ensureReady();

    if (!force && _cache.containsKey(chapterId)) {
      if (kDebugMode) {
        debugPrint(
          '[ILLU][analyzeChapter] skip cached chapterId=$chapterId scenes=${_cache[chapterId]?.length ?? 0}',
        );
      }
      return;
    }
    final inflight = _analysisInFlight[chapterId];
    if (inflight != null) {
      await inflight.future;
      return;
    }

    try {
      if (generateText == null && !usingPersonalTencentKeys()) {
        final available = pointsBalance ?? 0;
        if (available <= 0) {
          throw StateError('插图需要购买积分后使用');
        }
      }
      final paragraphs = _splitParagraphsForAnalysis(content);

      final completer = Completer<List<SceneCard>>();
      _analysisInFlight[chapterId] = completer;
      final task = _AnalysisTask(
        taskId: chapterId,
        outputChapterId: chapterId,
        chapterTitle: chapterTitle,
        paragraphs: paragraphs,
        maxScenes: maxScenes,
        generateText: generateText,
        fixedParagraphIndex: null,
        mergeIntoExisting: false,
        markChapterAnalyzing: true,
        completer: completer,
      );

      _analysisQueue.add(task);
      if (kDebugMode) {
        debugPrint(
          '[ILLU][analyzeChapter] queued chapterId=$chapterId queueLen=${_analysisQueue.length} local=${generateText != null}',
        );
      }

      _processAnalysisQueue();
      await completer.future;
      return;
    } catch (e) {
      _analysisInFlight.remove(chapterId);
      debugPrint('Analyze chapter failed: $e');
      rethrow;
    }
  }

  Future<void> _processAnalysisQueue() async {
    if (_isAnalyzing || _analysisQueue.isEmpty) return;

    _isAnalyzing = true;
    final task = _analysisQueue.removeFirst();
    if (task.markChapterAnalyzing) {
      _analyzingChapterIds.add(task.outputChapterId);
    }
    notifyListeners();

    try {
      if (kDebugMode) {
        debugPrint(
          '[ILLU][processQueue] start taskId=${task.taskId} out=${task.outputChapterId} maxScenes=${task.maxScenes} paragraphs=${task.paragraphs.length} local=${task.generateText != null}',
        );
      }
      final liveCards = <SceneCard>[];
      if (!task.mergeIntoExisting) {
        _cache[task.outputChapterId] = liveCards;
      }
      final cards = await _buildService().analyzeScenesFromParagraphs(
        paragraphs: task.paragraphs,
        chapterTitle: task.chapterTitle,
        maxScenes: task.maxScenes,
        debugName: task.taskId,
        run: task.generateText,
        onProgress: (partial) {
          if (task.mergeIntoExisting) {
            _mergeIntoChapterCache(
              chapterId: task.outputChapterId,
              newCards: partial,
              fixedParagraphIndex: task.fixedParagraphIndex,
            );
            notifyListeners();
            return;
          }
          liveCards
            ..clear()
            ..addAll(partial);
          notifyListeners();
        },
      );
      if (kDebugMode) {
        debugPrint(
          '[ILLU][processQueue] done taskId=${task.taskId} out=${task.outputChapterId} cards=${cards.length}',
        );
      }
      List<SceneCard> resultCards = cards;
      if (task.fixedParagraphIndex != null) {
        for (final c in resultCards) {
          c.startParagraphIndex = task.fixedParagraphIndex;
          c.endParagraphIndex = task.fixedParagraphIndex;
        }
      }
      if (task.mergeIntoExisting) {
        _mergeIntoChapterCache(
          chapterId: task.outputChapterId,
          newCards: resultCards,
          fixedParagraphIndex: task.fixedParagraphIndex,
        );
      } else {
        liveCards
          ..clear()
          ..addAll(resultCards);
      }
      task.completer.complete(resultCards);
      notifyListeners();
    } catch (e) {
      debugPrint('Process analysis queue failed: $e');
      task.completer.completeError(e);
    } finally {
      _analysisInFlight.remove(task.taskId);
      if (task.markChapterAnalyzing) {
        _analyzingChapterIds.remove(task.outputChapterId);
      }
      _isAnalyzing = false;
      notifyListeners();
      _processAnalysisQueue();
    }
  }

  void _mergeIntoChapterCache({
    required String chapterId,
    required List<SceneCard> newCards,
    required int? fixedParagraphIndex,
  }) {
    final existing = _cache[chapterId] ?? <SceneCard>[];
    final byId = <String, SceneCard>{};
    for (final c in existing) {
      byId[c.id] = c;
    }
    for (final c in newCards) {
      if (fixedParagraphIndex != null) {
        c.startParagraphIndex = fixedParagraphIndex;
        c.endParagraphIndex = fixedParagraphIndex;
      }
      byId[c.id] = c;
    }
    final merged = byId.values.toList()
      ..sort((a, b) {
        final ai = a.endParagraphIndex ?? 999999;
        final bi = b.endParagraphIndex ?? 999999;
        if (ai != bi) return ai.compareTo(bi);
        final at = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final bt = b.createdAt?.millisecondsSinceEpoch ?? 0;
        return at.compareTo(bt);
      });
    _cache[chapterId] = merged;
  }

  /// 对指定卡片进行生图
  Future<void> generateImage(
    String chapterId,
    SceneCard card, {
    String? stylePrefix,
    String resolution = '1024:1024',
  }) async {
    await _ensureReady();
    if (_generatingTaskIds.contains(card.id)) return;

    // 状态置为生成中
    card.status = SceneCardStatus.generating;
    card.errorMsg = null;
    _generatingTaskIds.add(card.id);
    notifyListeners();

    try {
      final jobId = await _buildService().submitGeneration(
        card: card,
        stylePrefix: stylePrefix ?? '',
        forLocalSd: false,
        resolution: resolution,
      );
      card.jobId = jobId;
      notifyListeners();

      final localPath = await _buildService().pollJobStatus(jobId);
      card.localImagePath = localPath;
      card.status = SceneCardStatus.completed;
    } catch (e) {
      debugPrint('Generate image failed: $e');
      card.status = SceneCardStatus.failed;
      card.errorMsg = e.toString();
    } finally {
      _generatingTaskIds.remove(card.id);
      notifyListeners();
    }
  }

  /// 直接从选中文本生成单张插画
  Future<SceneCard> generateFromSelection({
    required String chapterId,
    required String selectionText,
  }) async {
    await _ensureReady();
    final card = SceneCard(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: '灵感插画',
      location: '文中场景',
      time: '未知',
      characters: '未知',
      action: selectionText, // 直接用选中文本作为动作/画面描述
      mood: '默认',
      visualAnchors: '默认',
      lighting: '默认',
      composition: '默认',
      palette: '默认',
      status: SceneCardStatus.draft,
      createdAt: DateTime.now(),
    );

    // 加入缓存列表头部
    final list = _cache[chapterId] ?? [];
    list.insert(0, card);
    _cache[chapterId] = list;
    notifyListeners();
    return card;
  }
}

class _AnalysisTask {
  final String taskId;
  final String outputChapterId;
  final String chapterTitle;
  final List<String> paragraphs;
  final int maxScenes;
  final Future<String> Function(String prompt)? generateText;
  final int? fixedParagraphIndex;
  final bool mergeIntoExisting;
  final bool markChapterAnalyzing;
  final Completer<List<SceneCard>> completer;

  _AnalysisTask({
    required this.taskId,
    required this.outputChapterId,
    required this.chapterTitle,
    required this.paragraphs,
    required this.maxScenes,
    this.generateText,
    required this.fixedParagraphIndex,
    required this.mergeIntoExisting,
    required this.markChapterAnalyzing,
    required this.completer,
  });
}
