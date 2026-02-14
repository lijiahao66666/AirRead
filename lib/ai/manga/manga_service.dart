import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../hunyuan/hunyuan_image_client.dart';
import '../hunyuan/hunyuan_text_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import 'manga_panel.dart';

typedef _AnchorRange = ({
  int anchorStart,
  int anchorEnd,
});

class MangaService {
  final HunyuanImageClient _imageClient;
  final HunyuanTextClient _textClient;
  final String _baseStoragePath;

  static const Duration _pollInterval = Duration(seconds: 3);
  static const int _maxPollCount = 40;

  MangaService({
    required TencentCredentials credentials,
    required String baseStoragePath,
  })  : _imageClient = HunyuanImageClient(credentials: credentials),
        _textClient = HunyuanTextClient(credentials: credentials),
        _baseStoragePath = baseStoragePath;

  String _snippet(String text, {int max = 900}) {
    final t = text.trim();
    if (t.isEmpty) return '';
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  /// Generate Storybook (AI 绘本)
  /// 
  /// [pageCount] 0 means Auto.
  Future<List<MangaPanel>> generateStorybook({
    required List<String> paragraphs,
    required String chapterTitle,
    required int pageCount,
    required bool useLocalModel,
    Future<String> Function(String prompt)? run,
    bool? enableThinking,
    String? debugName,
  }) async {
    if (paragraphs.isEmpty) return const <MangaPanel>[];

    // 1. Determine effective page count
    int effectivePageCount = pageCount;
    if (effectivePageCount <= 0) {
      // Auto: ~500-800 chars per image? Or just 4-8 images.
      // Let's default to 4 for short, 8 for long.
      effectivePageCount = paragraphs.length > 50 ? 8 : 4;
    }
    effectivePageCount = effectivePageCount.clamp(1, 12);

    final runFn = run ?? ((p) => _runOnlineTextModel(p, enableThinking: enableThinking));

    if (useLocalModel) {
      return _generateStorybookLocal(
        paragraphs: paragraphs,
        pageCount: effectivePageCount,
        runFn: runFn,
        debugName: debugName,
      );
    } else {
      return _generateStorybookOnline(
        paragraphs: paragraphs,
        pageCount: effectivePageCount,
        runFn: runFn,
        debugName: debugName,
      );
    }
  }

  Future<List<MangaPanel>> _generateStorybookLocal({
    required List<String> paragraphs,
    required int pageCount,
    required Future<String> Function(String prompt) runFn,
    String? debugName,
  }) async {
    // Strategy: Rule-based slicing + Translation Prompt
    // Use weighted length to slice paragraphs evenly by content volume
    final anchors = _buildAnchorsByWeightedLength(
      paragraphs: paragraphs,
      count: pageCount,
    );

    final panels = <MangaPanel>[];

    for (int i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      final text = paragraphs
          .sublist(anchor.anchorStart, anchor.anchorEnd + 1)
          .map((p) => p.trim())
          .join('\n');
      // Truncate if too long for local model
      final truncatedText = _normalizeForPrompt(text, maxLen: 600);

      final prompt = '请阅读这段文字，用一句话描述一个画面。要求：\n1. 描述主体、动作和环境。\n2. 不要出现人名，用男孩/女孩/男人/女人代替。\n3. 30字以内。\n4. 直接输出内容，不要罗嗦，不要解释。\n\n文字：\n$truncatedText';

      if (kDebugMode) {
        debugPrint('[MANGA] Local Prompt [$i]: $prompt');
      }

      String desc = await runFn(prompt);
      desc = _stripModelNoise(desc).trim();
      // Remove quotes if any
      desc = desc.replaceAll(RegExp(r'^["“]|["”]$'), '');
      
      if (desc.isEmpty) desc = '无画面描述';

      panels.add(MangaPanel(
        id: const Uuid().v4(),
        anchorStart: anchor.anchorStart,
        anchorEnd: anchor.anchorEnd,
        narrativeRole: '绘本',
        title: '第${i + 1}页',
        subject: '', action: '', setting: '', time: '', weather: '',
        shot: '', camera: '', lighting: '', mood: '', composition: '',
        expandedPrompt: desc,
        status: MangaPanelStatus.promptReady,
        createdAt: DateTime.now(),
      ));
    }
    return panels;
  }

  Future<List<MangaPanel>> _generateStorybookOnline({
    required List<String> paragraphs,
    required int pageCount,
    required Future<String> Function(String prompt) runFn,
    String? debugName,
  }) async {
    // Strategy: Intelligent Extraction.
    // If pageCount > 6, split into chunks to maintain quality.
    int chunks = 1;
    if (pageCount > 6) chunks = 2;

    // Use weighted length to split chunks evenly
    final chunkAnchors = _buildAnchorsByWeightedLength(
      paragraphs: paragraphs,
      count: chunks,
    );

    final panels = <MangaPanel>[];
    int globalIndex = 0;

    for (int i = 0; i < chunks; i++) {
      final anchor = chunkAnchors[i];
      final chunkText = paragraphs
          .sublist(anchor.anchorStart, anchor.anchorEnd + 1)
          .map((p) => p.trim())
          .join('\n');
      final truncatedText = _normalizeForPrompt(chunkText, maxLen: 2000);

      // Distribute page count
      final subCount = (pageCount / chunks).ceil(); 
      // (Simple distribution, might result in slightly more panels, we can trim later)

      final prompt = _buildOnlineSceneExtractionPrompt(truncatedText, subCount);
      
      if (kDebugMode) {
        debugPrint('[MANGA] Online Prompt [$i]: $prompt');
      }

      final response = await runFn(prompt);
      final scenes = _parseSceneExtraction(response);

      // Create panels for this chunk
      // We map scenes to sub-anchors within this chunk
      final sceneAnchors = _buildAnchorsByParagraphCount(
        paragraphCount: anchor.anchorEnd - anchor.anchorStart + 1,
        count: scenes.length,
      );

      for (int k = 0; k < scenes.length; k++) {
        final subAnchor = sceneAnchors[k];
        // Offset anchors by chunk start
        final realStart = anchor.anchorStart + subAnchor.anchorStart;
        final realEnd = anchor.anchorStart + subAnchor.anchorEnd;

        globalIndex++;
        panels.add(MangaPanel(
          id: const Uuid().v4(),
          anchorStart: realStart,
          anchorEnd: realEnd,
          narrativeRole: '绘本',
          title: '第$globalIndex页',
          subject: '', action: '', setting: '', time: '', weather: '',
          shot: '', camera: '', lighting: '', mood: '', composition: '',
          expandedPrompt: scenes[k],
          status: MangaPanelStatus.promptReady,
          createdAt: DateTime.now(),
        ));
      }
    }

    // Trim if we generated too many (due to ceil)
    if (panels.length > pageCount) {
      return panels.sublist(0, pageCount);
    }
    return panels;
  }

  String _buildOnlineSceneExtractionPrompt(String text, int count) {
    return '''你是绘本导演。请阅读以下小说片段，提取最具画面感的 $count 个关键场景。

要求：
1. 提取 $count 个场景，按故事发展顺序排列。
2. 每个场景用一段话描述（100字以内），包含主体、动作、环境、光影、氛围。
3. 描写要像“文生图提示词”一样具体，不要出现人名（用外貌特征代替）。
4. 严格按格式输出，每行一个场景，以序号开头。

格式示例：
1. 一个穿着白衬衫的短发少年站在屋顶，背景是燃烧的夕阳，逆光，氛围悲伤。
2. 黑暗的地下室，只有一盏摇摇欲坠的吊灯，地面上有积水，反射着冷光。

小说片段：
$text

请输出 $count 个场景：''';
  }

  List<String> _parseSceneExtraction(String raw) {
    final clean = _stripModelNoise(raw);
    final lines = clean.split('\n');
    final out = <String>[];
    final re = RegExp(r'^\d+[\.、\s]\s*(.*)');
    
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final m = re.firstMatch(t);
      if (m != null) {
        final content = m.group(1)?.trim() ?? '';
        if (content.isNotEmpty) out.add(content);
      }
    }
    
    // Fallback: if regex failed (model didn't output numbers), just take non-empty lines
    if (out.isEmpty && clean.isNotEmpty) {
      for (final line in lines) {
         final t = line.trim();
         if (t.length > 10) out.add(t);
      }
    }
    return out;
  }

  Future<String> submitGeneration({
    required String prompt,
    String resolution = '1024:1024',
  }) async {
    final p = _normalizeModelPrompt(prompt);
    if (p.isEmpty) throw StateError('提示词为空');
    return await _imageClient.submitTextToImageJob(
      prompt: p,
      resolution: resolution,
    );
  }

  Future<String> pollJobStatus(String jobId) async {
    int count = 0;
    while (count < _maxPollCount) {
      await Future.delayed(_pollInterval);
      final status = await _imageClient.queryTextToImageJob(jobId);
      final code = status['JobStatusCode'];

      if (code == '5' || code == 5) {
        final urls = status['ResultImage'];
        if (urls is List && urls.isNotEmpty) {
          final url = urls.first.toString();
          if (kIsWeb) return url;
          return await _downloadImage(url, jobId);
        }
        throw Exception('Success but no image url');
      }

      if (code == '4' || code == 4) {
        final msg =
            status['JobErrorMsg'] ?? status['JobErrorCode'] ?? 'Unknown error';
        throw Exception('Generation failed: $msg');
      }

      count++;
    }
    throw TimeoutException('Generation timed out');
  }

  Future<String> _downloadImage(String url, String jobId) async {
    if (kIsWeb) return url;
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Failed to download image: ${resp.statusCode}');
    }

    final dir = Directory(path.join(_baseStoragePath, 'manga'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final filePath = path.join(dir.path, '$jobId.jpg');
    final file = File(filePath);
    await file.writeAsBytes(resp.bodyBytes);
    return filePath;
  }

  Future<String> _runOnlineTextModel(
    String prompt, {
    bool? enableThinking,
  }) async {
    final sw = Stopwatch()..start();
    final stream = _textClient.chatStream(
      userText: prompt,
      model: 'hunyuan-a13b',
      enableThinking: enableThinking,
    );
    final buffer = StringBuffer();
    await for (final chunk in stream) {
      if (chunk.isReasoning) continue;
      buffer.write(chunk.content);
    }
    final out = buffer.toString();
    if (kDebugMode) {
      debugPrint(
        '[MANGA] online_text.done thinking=$enableThinking ms=${sw.elapsedMilliseconds} outLen=${out.length}',
      );
    }
    return out;
  }

  List<_AnchorRange> _buildAnchorsByParagraphCount({
    required int paragraphCount,
    required int count,
  }) {
    if (paragraphCount <= 0 || count <= 0) {
      return const <_AnchorRange>[];
    }
    final cap = count.clamp(1, paragraphCount);
    final out = <_AnchorRange>[];
    for (int i = 0; i < cap; i++) {
      final start = ((i * paragraphCount) / cap).floor().clamp(0, paragraphCount - 1);
      int end =
          (((i + 1) * paragraphCount) / cap).floor() - 1;
      if (i == cap - 1) end = paragraphCount - 1;
      end = end.clamp(start, paragraphCount - 1);
      out.add((anchorStart: start, anchorEnd: end));
    }
    return out;
  }

  List<_AnchorRange> _buildAnchorsByWeightedLength({
    required List<String> paragraphs,
    required int count,
  }) {
    if (paragraphs.isEmpty || count <= 0) {
      return const <_AnchorRange>[];
    }
    final cap = count.clamp(1, paragraphs.length);
    
    int totalLen = 0;
    final lengths = <int>[];
    for (final p in paragraphs) {
      final len = p.length;
      lengths.add(len);
      totalLen += len;
    }

    if (totalLen == 0) {
      return _buildAnchorsByParagraphCount(paragraphCount: paragraphs.length, count: cap);
    }

    final targetLenPerChunk = totalLen / cap;
    final out = <_AnchorRange>[];
    
    int currentStart = 0;
    int currentLen = 0;
    
    for (int i = 0; i < cap; i++) {
      if (currentStart >= paragraphs.length) break;
      
      if (i == cap - 1) {
        out.add((anchorStart: currentStart, anchorEnd: paragraphs.length - 1));
        break;
      }

      int end = currentStart;
      currentLen = 0;
      
      while (end < paragraphs.length) {
        final len = lengths[end];
        
        if (currentLen + len > targetLenPerChunk && currentLen > 0) {
          final diffCurrent = (targetLenPerChunk - currentLen).abs();
          final diffNext = ((currentLen + len) - targetLenPerChunk).abs();
          
          if (diffNext < diffCurrent) {
             currentLen += len;
             end++;
          }
          break;
        }
        
        currentLen += len;
        end++;
      }
      
      if (end <= currentStart) {
        end = currentStart + 1;
      }
      
      final realEnd = (end - 1).clamp(currentStart, paragraphs.length - 1);
      out.add((anchorStart: currentStart, anchorEnd: realEnd));
      
      currentStart = realEnd + 1;
    }
    
    return out;
  }

  String _stripModelNoise(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '');
    s = s.replaceAll('```', '');
    return s.trim();
  }

  String _normalizeForPrompt(String s, {required int maxLen}) {
    var t = s.replaceAll('\u0000', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= maxLen) return t;
    return '${t.substring(0, maxLen)}…';
  }

  String _normalizeModelPrompt(String input) {
    var s = input.replaceAll('\u0000', '');
    s = s.replaceAll(RegExp(r'\\[nrt]'), ' ');
    s = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }
}
