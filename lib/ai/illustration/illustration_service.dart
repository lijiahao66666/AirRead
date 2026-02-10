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
  }) async {
    final cap = maxScenes.clamp(0, 20);
    if (cap <= 0 || paragraphs.isEmpty) return const <SceneCard>[];

    final run = _runOnlineTextModel;
    final n = paragraphs.length;
    
    // Adaptive Partitioning with Overlap
    // Calculate how many partitions we need based on maxScenes
    // If paragraphs count is small, we might have fewer partitions
    final int partitionCount = cap > n ? n : cap;
    if (partitionCount <= 0) return const <SceneCard>[];

    // Calculate chunk size
    final double step = n / partitionCount;
    final int overlap = 0; // Remove overlap as requested

    final List<List<SceneCard>> results = [];

    for (int i = 0; i < partitionCount; i++) {
      final int start = (i * step).floor();
      int end = ((i + 1) * step).floor() + overlap;
      if (end > n) end = n;
      if (start >= end) continue;

      // Extract paragraphs for this chunk
      final subParagraphs = paragraphs.sublist(start, end);
      
      // Execute sequentially to avoid native crash in local LLM
      final chunkCards = await _analyzeSingleChunk(
        run: run,
        allParagraphs: paragraphs,
        chunkStartIndex: start,
        chunkParagraphs: subParagraphs,
        chapterTitle: chapterTitle,
        debugName: '$debugName-chunk-$i',
      );
      results.add(chunkCards);
    }
    
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
    
    if (kDebugMode) {
      debugPrint(
        '[ILLU] aggregate debugName=$debugName partitions=$partitionCount cards=${allCards.length} indices=${allCards.map((e) => e.endParagraphIndex).toList()}',
      );
    }
    return allCards;
  }

  Future<List<SceneCard>> _analyzeSingleChunk({
    required Future<String> Function(String) run,
    required List<String> allParagraphs,
    required int chunkStartIndex,
    required List<String> chunkParagraphs,
    required String chapterTitle,
    required String? debugName,
  }) async {
    final prompt = _buildChunkPrompt(
      chunkStartIndex: chunkStartIndex,
      chunkParagraphs: chunkParagraphs,
      chapterTitle: chapterTitle,
    );

    if (kDebugMode) {
      debugPrint('[ILLU] chunk start=$chunkStartIndex len=${chunkParagraphs.length}');
      // Log full input prompt for debugging
      debugPrint('[ILLU] PROMPT_INPUT:\n$prompt');
    }

    String? response;
    try {
      response = await run(prompt);
      if (kDebugMode) {
        // Log full output response for debugging
        debugPrint('[ILLU] PROMPT_OUTPUT:\n$response');
      }
    } catch (e) {
      debugPrint('[ILLU] chunk error: $e');
      return [];
    }

    // Parse result
    final parsed = _parseAndValidateSceneCards(
      response,
      chapterTitle: chapterTitle,
      paragraphs: allParagraphs, // Use full list for validation safety
    );
    if (kDebugMode) {
      debugPrint(
        '[ILLU] parsed debugName=$debugName ok=${parsed.ok} cards=${parsed.cards.length} hint=${parsed.errorHint}',
      );
      for (final c in parsed.cards) {
        debugPrint(
          '[ILLU] card idx=${c.endParagraphIndex} title=${c.title} promptLen=${c.action.length}',
        );
      }
    }
    
    // Filter out invalid indices just in case (e.g. out of chunk range, though we validate against full doc)
    return parsed.cards;
  }

  String _buildChunkPrompt({
    required int chunkStartIndex,
    required List<String> chunkParagraphs,
    required String chapterTitle,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是一个专业的插画分镜师。');
    buffer.writeln('任务：阅读下方小说片段，判断其中是否包含**极具画面感且适合绘制插画**的关键场景。');
    buffer.writeln('要求：');
    buffer.writeln('1. 如果该片段包含精彩的画面场景，提取**1个**最关键的场景。');
    buffer.writeln('2. 警告：如果该片段平淡无奇、缺乏具体画面、只是对话或心理描写，请务必直接输出 null。');
    buffer.writeln('   不要强行生成！不要为了生成而生成！无画面感必须返回 null！');
    buffer.writeln('输出格式：');
    buffer.writeln('仅输出一个JSON对象（或 null），不要输出数组，不要包含任何解释文字。');
    buffer.writeln('JSON字段说明：');
    buffer.writeln('   - index (int): 该场景对应的段落全局唯一索引（必须严格对应下方文本行首的数字标记！）。');
    buffer.writeln('     例如：如果选中了标记为 "12: ..." 的段落，index 必须填 12。');
    buffer.writeln('   - title (string): 场景标题，简练概括画面，允许中文。');
    buffer.writeln('   - prompt (string): 中文生图提示词，描述画面内容、构图、光影等细节，长度<=150字符。');
    buffer.writeln('   - important: 仅当画面感极强时才输出对象，否则输出 null。');
    
    buffer.writeln();
    buffer.writeln('小说片段（行首数字为全局索引）：');
    
    for (int i = 0; i < chunkParagraphs.length; i++) {
      final globalIndex = chunkStartIndex + i;
      String p = chunkParagraphs[i];
      String normalized = _normalizeForPrompt(p, maxLen: 120); 
      // Remove 'P' prefix, use raw number
      buffer.writeln('$globalIndex: $normalized');
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
      // New logic: Allow single object or null
      final rawTrimmed = raw.trim();
      if (rawTrimmed == 'null') {
         return (ok: true, cards: const <SceneCard>[], errorHint: '');
      }
      
      // Compatibility: Check if it's a single object (starts with {)
      final startObj = raw.indexOf('{');
      final endObj = raw.lastIndexOf('}');
      if (startObj != -1 && endObj != -1 && endObj > startObj) {
        // It is a single object
        final singleJson = raw.substring(startObj, endObj + 1);
        try {
          final decodedSingle = jsonDecode(singleJson);
          return _parseDecodedList([decodedSingle], paragraphs);
        } catch (_) {
           return (ok: false, cards: const <SceneCard>[], errorHint: '未找到JSON对象');
        }
      }
      return (ok: false, cards: const <SceneCard>[], errorHint: '未找到JSON对象或数组');
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
      
      // Schema validation: index, title, prompt (was scene in prompt instructions, but check logic here)
      // The prompt asks for 'prompt' key, but let's check both for safety or just 'prompt'
      // Old code checked 'scene' because user requested 'scene' key in prompt.
      // Current prompt asks for 'prompt' key.
      
      String? promptVal;
      if (map.containsKey('prompt')) {
        promptVal = map['prompt']?.toString();
      } else if (map.containsKey('scene')) {
        promptVal = map['scene']?.toString();
      }
      
      if (!map.containsKey('index') || !map.containsKey('title') || promptVal == null) {
         errors.add('第${i + 1}项 缺少必要字段(index/title/prompt)');
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
      final String scene = promptVal ?? '';

      if (scene.isEmpty) {
        errors.add('第${i + 1}项 prompt为空');
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
