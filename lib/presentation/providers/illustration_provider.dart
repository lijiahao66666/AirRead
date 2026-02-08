import 'dart:async';
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
      final cards = await _buildService().analyzeScenesFromParagraphs(
        paragraphs: paragraphs,
        chapterTitle: chapterTitle,
        maxScenes: maxScenes,
        debugName: chapterId,
        generateText: generateText,
      );
      _cache[chapterId] = cards;
      notifyListeners();
    } catch (e) {
      debugPrint('Analyze chapter failed: $e');
      rethrow;
    }
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
      // 1. 提交任务
      final jobId = await _buildService().submitGeneration(
        card: card,
        stylePrefix: stylePrefix,
        resolution: resolution,
      );
      card.jobId = jobId;
      notifyListeners();

      // 2. 轮询结果
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
