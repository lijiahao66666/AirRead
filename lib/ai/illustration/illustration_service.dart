import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as path;

import '../hunyuan/hunyuan_image_client.dart';
import '../hunyuan/hunyuan_text_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import 'scene_card.dart';

class IllustrationService {
  final HunyuanImageClient _imageClient;
  final HunyuanTextClient _textClient;
  final String _baseStoragePath;

  // 轮询间隔
  static const Duration _pollInterval = Duration(seconds: 3);
  // 最大轮询次数 (约 2 分钟)
  static const int _maxPollCount = 40;

  IllustrationService({
    required TencentCredentials credentials,
    required String baseStoragePath,
  })  : _imageClient = HunyuanImageClient(credentials: credentials),
        _textClient = HunyuanTextClient(credentials: credentials),
        _baseStoragePath = baseStoragePath;

  Future<List<SceneCard>> analyzeScenesFromParagraphs({
    required List<String> paragraphs,
    required String chapterTitle,
    required int maxScenes,
    String? debugName,
    Future<String> Function(String prompt)? generateText,
  }) async {
    final cap = maxScenes.clamp(0, 20);
    if (cap <= 0 || paragraphs.isEmpty) return const <SceneCard>[];

    final run = generateText ?? _runOnlineTextModel;
    final n = paragraphs.length;
    
    // Adaptive Partitioning with Overlap
    // Calculate how many partitions we need based on maxScenes
    // If paragraphs count is small, we might have fewer partitions
    final int partitionCount = cap > n ? n : cap;
    if (partitionCount <= 0) return const <SceneCard>[];

    // Calculate chunk size
    final double step = n / partitionCount;
    final int overlap = 5; // Look ahead 5 paragraphs

    final List<Future<List<SceneCard>>> futures = [];

    for (int i = 0; i < partitionCount; i++) {
      final int start = (i * step).floor();
      int end = ((i + 1) * step).floor() + overlap;
      if (end > n) end = n;
      if (start >= end) continue;

      // Extract paragraphs for this chunk
      final subParagraphs = paragraphs.sublist(start, end);
      // Map global index to local index is not needed if we provide "P{index}: content" format
      // But we need to tell the prompt the actual global indices so the output 'index' is correct.
      
      futures.add(_analyzeSingleChunk(
        run: run,
        allParagraphs: paragraphs, // Pass full list for context if needed? No, just pass chunk but use global indices in prompt
        chunkStartIndex: start,
        chunkParagraphs: subParagraphs,
        chapterTitle: chapterTitle,
        debugName: '$debugName-chunk-$i',
        forLocalSd: generateText != null,
      ));
    }

    final results = await Future.wait(futures);
    
    // Aggregate and Deduplicate
    final List<SceneCard> allCards = [];
    final Set<int> seenIndices = {};

    for (final list in results) {
      for (final card in list) {
        // Simple deduplication strategy:
        // If we already have a card at index X, and this one is at X, X-1, X+1, X+2...
        // Let's just enforce strict distance? 
        // Or since partitions are sequential, just ignore if index is already "covered".
        // Let's use exact index check for now, as partitions are distinct enough usually.
        // Actually, overlap might cause same scene to be picked in two chunks.
        // If index is within +/- 2 of an existing card, skip.
        bool isDuplicate = false;
        for (final seen in seenIndices) {
          if ((card.endParagraphIndex! - seen).abs() <= 2) {
            isDuplicate = true;
            break;
          }
        }
        
        if (!isDuplicate) {
          allCards.add(card);
          seenIndices.add(card.endParagraphIndex!);
        }
      }
    }
    
    // Sort by index
    allCards.sort((a, b) => (a.endParagraphIndex ?? 0).compareTo(b.endParagraphIndex ?? 0));
    
    return allCards;
  }

  Future<List<SceneCard>> _analyzeSingleChunk({
    required Future<String> Function(String) run,
    required List<String> allParagraphs,
    required int chunkStartIndex,
    required List<String> chunkParagraphs,
    required String chapterTitle,
    required String? debugName,
    required bool forLocalSd,
  }) async {
    final prompt = _buildChunkPrompt(
      chunkStartIndex: chunkStartIndex,
      chunkParagraphs: chunkParagraphs,
      chapterTitle: chapterTitle,
      forLocalSd: forLocalSd,
    );

    if (kDebugMode) {
      debugPrint('[ILLU] chunk start=$chunkStartIndex len=${chunkParagraphs.length}');
    }

    String? response;
    try {
      response = await run(prompt);
    } catch (e) {
      debugPrint('[ILLU] chunk error: $e');
      return [];
    }

    if (response == null) return [];

    // Parse result
    final parsed = _parseAndValidateSceneCards(
      response,
      chapterTitle: chapterTitle,
      paragraphs: allParagraphs, // Use full list for validation safety
    );
    
    // Filter out invalid indices just in case (e.g. out of chunk range, though we validate against full doc)
    return parsed.cards;
  }

  String _buildChunkPrompt({
    required int chunkStartIndex,
    required List<String> chunkParagraphs,
    required String chapterTitle,
    required bool forLocalSd,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是一个专业的插画分镜师。');
    buffer.writeln('任务：阅读下方小说片段，提取**0到1个**最适合绘制插画的关键场景。如果不适合生图，可返回空数组。');
    buffer.writeln('输出要求：');
    buffer.writeln('1. 仅输出一个标准的JSON数组。');
    buffer.writeln('2. 数组中每个元素是一个对象，包含以下字段：');
    buffer.writeln('   - index (int): 该场景对应的段落索引（必须使用下方文本中标记的 Px 索引）。');
    buffer.writeln('   - title (string): 场景标题，简练概括画面，允许中文。');
    buffer.writeln('   - prompt (string): ${forLocalSd ? "英文生图提示词" : "中文生图提示词"}，描述画面内容、构图、光影等细节，长度<=150字符。');
    buffer.writeln('3. 读者读完第index段落时，应该看到这幅插图。');
    buffer.writeln('4. 不要输出任何解释性文字，不要包含Markdown标记。');
    
    if (forLocalSd) {
      buffer.writeln('重要：prompt字段必须翻译为英文！');
    }

    buffer.writeln();
    buffer.writeln('小说片段：');
    
    for (int i = 0; i < chunkParagraphs.length; i++) {
      final globalIndex = chunkStartIndex + i;
      String p = chunkParagraphs[i];
      String normalized = _normalizeForPrompt(p, maxLen: forLocalSd ? 150 : 120); 
      buffer.writeln('P$globalIndex: $normalized');
    }
    
    return buffer.toString();
  }

  Future<String> _runOnlineTextModel(String prompt) async {
    final stream = _textClient.chatStream(
      userText: prompt,
      model: 'hunyuan-a13b',
    );
    final buffer = StringBuffer();
    await for (final chunk in stream) {
      if (chunk.isReasoning) continue;
      buffer.write(chunk.content);
    }
    return buffer.toString();
  }

  /// 提交生图任务
  Future<String> submitGeneration({
    required SceneCard card,
    required String stylePrefix,
    required bool forLocalSd,
    String resolution = '1024:1024',
  }) async {
    final prompt = card.toPrompt(stylePrefix: stylePrefix, forLocalSd: forLocalSd);
    return await _imageClient.submitTextToImageJob(
      prompt: prompt,
      resolution: resolution,
    );
  }

  /// 轮询任务状态直到完成或失败
  /// 返回本地文件路径
  Future<String> pollJobStatus(String jobId) async {
    int count = 0;
    while (count < _maxPollCount) {
      await Future.delayed(_pollInterval);
      final status = await _imageClient.queryTextToImageJob(jobId);
      final code = status['JobStatusCode'];

      if (code == '5' || code == 5) {
        // 成功
        final urls = status['ResultImage'];
        if (urls is List && urls.isNotEmpty) {
          final url = urls.first.toString();
          if (kIsWeb) return url;
          return await _downloadImage(url, jobId);
        }
        throw Exception('Success but no image url');
      }

      if (code == '4' || code == 4) {
        // 失败
        final msg =
            status['JobErrorMsg'] ?? status['JobErrorCode'] ?? 'Unknown error';
        throw Exception('Generation failed: $msg');
      }

      count++;
    }
    throw TimeoutException('Generation timed out');
  }

  /// 下载图片到本地
  Future<String> _downloadImage(String url, String jobId) async {
    if (kIsWeb) return url;
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Failed to download image: ${resp.statusCode}');
    }

    final dir = Directory(path.join(_baseStoragePath, 'illustrations'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final filePath = path.join(dir.path, '$jobId.jpg');
    final file = File(filePath);
    await file.writeAsBytes(resp.bodyBytes);
    return filePath;
  }

  String _normalizeForPrompt(String s, {required int maxLen}) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').replaceAll('\u0000', '').trim();
    if (t.length <= maxLen) return t;
    return '${t.substring(0, maxLen)}…';
  }

  String _safeFileName(String s) {
    final t = s.trim().replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (t.isEmpty) return 'untitled';
    return t.length > 80 ? t.substring(0, 80) : t;
  }

  String? _truncateForDebug(String? s, int maxLen) {
    if (s == null) return null;
    final t = s.trim();
    if (t.length <= maxLen) return t;
    return '${t.substring(0, maxLen)}…(truncated)';
  }

  Future<void> _writeDebugSceneAnalysis({
    required String? debugName,
    required String chapterTitle,
    required String prompt,
    required String? firstRaw,
    required String? firstError,
    required ({bool ok, List<SceneCard> cards, String errorHint})? firstParsed,
    required List<String> paragraphs,
  }) async {
    final resultPayload = <String, dynamic>{
      'debugName': debugName,
      'chapterTitle': chapterTitle,
      'ok': firstParsed?.ok ?? false,
      'errorHint': firstError ?? (firstParsed?.errorHint ?? ''),
      'cards': (firstParsed?.cards ?? const <SceneCard>[])
          .map((e) => e.toJson())
          .toList(),
    };
    if (kIsWeb) {
      final tag =
          '${DateTime.now().toIso8601String()}_${_safeFileName(debugName ?? chapterTitle)}';
      print(
          '[IllustrationService] scene_result $tag ${jsonEncode(resultPayload)}');
      return;
    }
    try {
      final base = _baseStoragePath.trim();
      if (base.isEmpty) {
        return;
      }
      final dir = Directory(path.join(base, 'illustrations', 'debug_scene'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final tag = _safeFileName(debugName ?? chapterTitle);
      final file = File(path.join(dir.path, '${ts}_$tag.json'));
      await file.writeAsString(jsonEncode(resultPayload));
    } catch (_) {}
  }

  String _buildScenePromptFromParagraphs({
    required List<String> paragraphs,
    required String chapterTitle,
    required int maxScenes,
    required bool forLocalSd,
  }) {
    final n = paragraphs.length;
    // Calculate total chars
    int totalChars = 0;
    for (final p in paragraphs) totalChars += p.length;
    
    // For local model:
    // Context window is 4096. 
    // We reserve ~512 for system prompt & instructions.
    // We want output to be at least enough for 'maxScenes' cards.
    // Each card is limited to 500 chars for action + other fields ~200 chars => ~700 chars per card.
    // If maxScenes=3, we need ~2100 chars output (~1500 tokens).
    // So we have ~4096 - 512 - 1500 = ~2000 tokens for input (~2500 chars).
    //
    // Dynamic calculation:
    // 1. Calculate input size (paragraphs).
    // 2. Reserve tokens for input.
    // 3. Remaining tokens are for output.
    // 4. Adjust per-scene limit based on remaining output tokens.

    final indices = <int>[];
    if (n <= 18) {
      for (int i = 0; i < n; i++) {
        indices.add(i);
      }
    } else {
      // Pick key paragraphs: beginning, middle, end
      // For local model, we might pick fewer if needed, but user requested full input if possible.
      // We'll stick to 6 for now, and rely on truncation if needed.
      const pickCount = 6;
      for (int i = 0; i < pickCount; i++) {
        indices.add(i);
      }
      final midStart = ((n - pickCount) ~/ 2).clamp(pickCount, n - pickCount * 2);
      for (int i = 0; i < pickCount; i++) {
        indices.add(midStart + i);
      }
      for (int i = n - pickCount; i < n; i++) {
        indices.add(i);
      }
    }
    final unique = indices.toSet().toList()..sort();
    
    // Construct the input paragraphs text first to measure its length
    final inputBuffer = StringBuffer();
    for (final i in unique) {
      if (i < 0 || i >= n) continue;
      String p = paragraphs[i];
      // Normalize but keep reasonable length
      String normalized = _normalizeForPrompt(p, maxLen: forLocalSd ? 150 : 120); 
      inputBuffer.writeln('P$i: $normalized');
    }
    final inputText = inputBuffer.toString();
    
    int targetScenes = maxScenes;
    int charsPerScene = 150; // Default limit for local/online

    if (forLocalSd) {
      // Dynamic constraint calculation
      // Assume 1 token ~= 1.3 chars (English/Chinese mix)
      const int maxContextTokens = 4096;
      const int systemPromptReserve = 600; // Tokens for system prompt
      final int inputTokens = (inputText.length / 1.3).ceil();
      
      if (inputTokens + systemPromptReserve > maxContextTokens) {
        throw Exception('章节内容过长，无法使用本地模型分析，请切换到在线模型');
      }

      int availableOutputTokens = maxContextTokens - systemPromptReserve - inputTokens;
      
      // Ensure minimum output capability
      if (availableOutputTokens < 100) {
         // Input is too long, we MUST truncate input to guarantee minimum output
         // Let's guarantee at least 1000 tokens for output
         // But per user request: if too long, just fail.
         // Wait, the previous check (inputTokens + systemPromptReserve > maxContextTokens) covers the total overflow.
         // But here we check if remaining output space is too small for ANY useful output.
         // If we have < 100 tokens for output, it's risky.
         throw Exception('章节内容过长(剩余输出空间不足)，无法使用本地模型分析');
      }
      
      final int maxOutputChars = (availableOutputTokens * 1.3).floor();
      // Distribute max chars among scenes
      // Reserve some chars for JSON structure overhead (~100 chars)
      // If output space is very tight, we can reduce maxScenes to ensure quality per scene
      charsPerScene = ((maxOutputChars - 100) ~/ targetScenes).clamp(50, 500);
      
      // If chars per scene is too low (< 150), reduce scene count to maintain quality
      while (charsPerScene < 150 && targetScenes > 1) {
        targetScenes--;
        charsPerScene = ((maxOutputChars - 100) ~/ targetScenes).clamp(50, 500);
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('你是一个专业的插画分镜师。');
    buffer.writeln('任务：阅读下方小说正文，提取0-$targetScenes个最适合绘制插画的关键场景。');
    buffer.writeln('输出要求：');
    buffer.writeln('1. 仅输出一个标准的JSON数组。');
    buffer.writeln('2. 数组中每个元素是一个对象，包含以下字段：');
    buffer.writeln('   - index (int): 该场景对应的段落索引（从下方文本中获取，从0开始）。');
    buffer.writeln('   - title (string): 场景标题，简练概括画面，允许中文。');
    buffer.writeln('   - scene (string): ${forLocalSd ? "英文生图提示词" : "中文生图提示词"}，描述画面内容、构图、光影等细节，长度<=$charsPerScene字符。');
    buffer.writeln('3. 读者读完第index段落时，应该看到这幅插图。');
    buffer.writeln('4. 不要输出任何解释性文字，不要包含Markdown标记。');
    
    if (forLocalSd) {
      buffer.writeln('重要：scene字段必须翻译为英文！');
    }

    buffer.writeln();
    buffer.writeln('正文内容：');
    buffer.write(inputText);
    return buffer.toString();
  }

  ({bool ok, List<SceneCard> cards, String errorHint})
      _parseAndValidateSceneCards(
    String raw, {
    required String chapterTitle,
    required List<String> paragraphs,
  }) {
    final start = raw.indexOf('[');
    // If we can't find ']', we might be truncated.
    // Try to take everything from '[' to the end of string if ']' is missing
    final lastBracket = raw.lastIndexOf(']');
    final end = (lastBracket != -1 && lastBracket > start) ? lastBracket : raw.length - 1;

    if (start == -1 || end <= start) {
      // Compatibility: Check if it's a single object (starts with {)
      final startObj = raw.indexOf('{');
      final endObj = raw.lastIndexOf('}');
      if (startObj != -1 && endObj != -1 && endObj > startObj) {
        // Wrap single object in array
        final singleJson = raw.substring(startObj, endObj + 1);
        try {
          final decodedSingle = jsonDecode(singleJson);
          return _parseDecodedList([decodedSingle], paragraphs);
        } catch (_) {
           return (ok: false, cards: const <SceneCard>[], errorHint: '未找到JSON数组或对象');
        }
      }
      return (ok: false, cards: const <SceneCard>[], errorHint: '未找到JSON数组');
    }

    final maybeTruncatedJson = raw.substring(start, lastBracket != -1 ? end + 1 : raw.length);
    dynamic decoded;
    try {
      decoded = jsonDecode(maybeTruncatedJson);
    } catch (e) {
      // Try to fix common JSON errors from local models
      try {
        var fixed = maybeTruncatedJson.replaceAll('\n', '\\n').replaceAll('\r', '');
        
        // Attempt to close truncation
        if (!fixed.trim().endsWith(']')) {
             if (fixed.trim().endsWith('}')) {
               fixed = '$fixed]';
             } else if (fixed.trim().endsWith('"')) {
               fixed = '$fixed}]';
             } else {
               fixed = '$fixed"}]';
             }
        }
        
        try {
           decoded = jsonDecode(fixed);
        } catch (_) {
           // Final fallback
           final lastValidObjEnd = fixed.lastIndexOf('},');
           if (lastValidObjEnd != -1) {
             fixed = '${fixed.substring(0, lastValidObjEnd + 1)}]';
             decoded = jsonDecode(fixed);
           } else {
             throw Exception('Repair failed');
           }
        }
      } catch (_) {
        if (kDebugMode) {
           debugPrint('[ILLU] JSON repair failed. Raw length: ${raw.length}');
        }
        return (ok: false, cards: const <SceneCard>[], errorHint: 'JSON解析失败');
      }
    }
    
    // Compatibility: If decoded is Map (single object), wrap it
    if (decoded is Map) {
      decoded = [decoded];
    }

    if (decoded is! List) {
      return (ok: false, cards: const <SceneCard>[], errorHint: 'JSON不是数组');
    }

    return _parseDecodedList(decoded, paragraphs);
  }

  ({bool ok, List<SceneCard> cards, String errorHint}) _parseDecodedList(
      dynamic decodedList, List<String> paragraphs) {
    if (decodedList is! List) return (ok: false, cards: const <SceneCard>[], errorHint: '无效数据');

    final List<SceneCard> out = [];
    final List<String> errors = [];
    
    for (int i = 0; i < decodedList.length; i++) {
      final item = decodedList[i];
      if (item is! Map) {
        errors.add('第${i + 1}项不是对象');
        continue;
      }
      final map = item.cast<String, dynamic>();
      
      // Schema validation: index, title, scene
      if (!map.containsKey('index') || !map.containsKey('title') || !map.containsKey('scene')) {
         errors.add('第${i + 1}项 缺少必要字段(index/title/scene)');
         continue;
      }

      final dynamic indexRaw = map['index'];
      final int? pIndex = indexRaw is int
          ? indexRaw
          : (indexRaw is String ? int.tryParse(indexRaw) : null);

      if (pIndex == null || pIndex < 0 || pIndex >= paragraphs.length) {
        errors.add('第${i + 1}项 索引 $pIndex 无效');
        continue;
      }
      
      final String title = (map['title'] ?? '场景').toString();
      final String scene = (map['scene'] ?? '').toString();

      if (scene.isEmpty) {
        errors.add('第${i + 1}项 scene为空');
        continue;
      }

      out.add(SceneCard(
        id: const Uuid().v4(),
        startParagraphIndex: pIndex,
        endParagraphIndex: pIndex, // Point to single paragraph
        title: title,
        location: '',
        time: '',
        characters: '',
        action: scene, // Store prompt in action field
        mood: '',
        visualAnchors: '',
        lighting: '',
        composition: '',
        palette: '',
        createdAt: DateTime.now(),
      ));
    }

    final ok = errors.isEmpty;
    final hint = errors.isEmpty ? '' : errors.take(3).join('；');
    return (
      ok: ok,
      cards: out,
      errorHint: ok ? '' : (hint.isEmpty ? '未知错误' : hint)
    );
  }
}
