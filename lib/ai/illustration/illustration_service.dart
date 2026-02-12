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
    Future<String> Function(String prompt)? run,
    void Function(List<SceneCard> cards)? onProgress,
  }) async {
    final cap = maxScenes.clamp(0, 20);
    if (cap <= 0 || paragraphs.isEmpty) return const <SceneCard>[];

    final runFn = run ?? _runOnlineTextModel;
    final n = paragraphs.length;

    const int minChunkParagraphs = 2;
    final int partitionCount = (() {
      final byMinChunk = (n / minChunkParagraphs).ceil();
      return byMinChunk.clamp(1, cap);
    })();
    if (partitionCount <= 0) return const <SceneCard>[];

    final int chunkSize = (n / partitionCount).ceil().clamp(1, n);
    final List<SceneCard> allCards = [];
    final Set<int> seenIndices = {};

    for (int i = 0; i < partitionCount; i++) {
      final int start = i * chunkSize;
      final int end = (start + chunkSize).clamp(0, n);
      if (start >= end) continue;

      // Extract paragraphs for this chunk
      final subParagraphs = paragraphs.sublist(start, end);

      // Execute sequentially to avoid native crash in local LLM
      final chunkCards = await _analyzeSingleChunk(
        run: runFn,
        allParagraphs: paragraphs,
        chunkStartIndex: start,
        chunkParagraphs: subParagraphs,
        chapterTitle: chapterTitle,
        debugName: '$debugName-chunk-$i',
      );
      var changed = false;
      for (final card in chunkCards) {
        final idx = card.endParagraphIndex;
        if (idx == null) continue;
        bool isDuplicate = false;
        for (final seen in seenIndices) {
          if ((idx - seen).abs() <= 2) {
            isDuplicate = true;
            break;
          }
        }
        if (isDuplicate) continue;
        allCards.add(card);
        seenIndices.add(idx);
        changed = true;
        if (allCards.length >= cap) break;
      }
      if (changed) {
        allCards.sort(
          (a, b) =>
              (a.endParagraphIndex ?? 0).compareTo(b.endParagraphIndex ?? 0),
        );
        onProgress?.call(List<SceneCard>.unmodifiable(allCards));
      }
      if (allCards.length >= cap) break;
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
      debugPrint(
          '[ILLU] chunk start=$chunkStartIndex len=${chunkParagraphs.length}');
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
    buffer.writeln('章节标题：$chapterTitle');
    buffer.writeln('任务：阅读下方小说片段，判断其中是否包含“强画面感、适合绘制插画”的关键场景。');
    buffer.writeln('硬性要求：');
    buffer.writeln('1) 只允许基于原文信息提炼画面；禁止新增原文未出现的人物、地点、道具、服饰细节。');
    buffer.writeln('2) 如果片段平淡无奇、缺乏可视化动作/环境，只是对话或心理描写，请直接输出 null。');
    buffer.writeln('3) 若存在画面：只提取 1 个最关键场景。');
    buffer.writeln('4) prompt 必须是“用于生图的画面描述”，不得直接复制原文句子；禁止出现原文中连续 20 个以上的原句片段。');
    buffer.writeln('输出格式：仅输出一个 JSON 对象（或 null），不要输出数组，不要包含解释文字/Markdown。');
    buffer.writeln('JSON 字段：');
    buffer.writeln('  - index (int)：场景对应的段落全局索引（必须严格对应下方每行开头的数字）。');
    buffer.writeln('  - title (string)：场景标题（简短）。');
    buffer.writeln(
        '  - prompt (string)：中文生图提示词（更细更具体），需包含：主体、动作、环境、时间/天气、镜头景别、光影、氛围、构图要点；长度 <= 280 字。');
    buffer.writeln('示例：{"index": 12, "title": "雨夜追逐", "prompt": "雨夜街巷，披斗篷的年轻人奔跑回头张望，湿漉漉石板路反光，远处路灯光晕，低角度中景，冷色调，紧张氛围，动感构图"}');

    buffer.writeln();
    buffer.writeln('小说片段（行首数字为全局索引）：');

    for (int i = 0; i < chunkParagraphs.length; i++) {
      final globalIndex = chunkStartIndex + i;
      String p = chunkParagraphs[i];
      String normalized = _normalizeForPrompt(p, maxLen: 260);
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
    final prompt =
        card.toPrompt(stylePrefix: stylePrefix, forLocalSd: forLocalSd);
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
    var t = s.replaceAll('\u0000', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    t = _trimOuterPunctuation(t);
    if (t.length <= maxLen) return t;
    return '${t.substring(0, maxLen)}…';
  }

  String _trimOuterPunctuation(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    const int maxPass = 4;
    for (int i = 0; i < maxPass; i++) {
      final before = s;
      s = s
          .replaceAll(
            RegExp('^[\\s"\'“”‘’《》〈〉「」『』【】〔〕（）()\\[\\]]+'),
            '',
          )
          .replaceAll(RegExp(r'^[,，。．、!！?？;；:：…—\-]+'), '')
          .replaceAll(
            RegExp('[\\s"\'“”‘’《》〈〉「」『』【】〔〕（）()\\[\\]]+\$'),
            '',
          )
          .replaceAll(RegExp(r'[,，。．、!！?？;；:：…—\-]+$'), '')
          .trim();
      if (s.isEmpty) return '';
      if (s == before) break;
    }
    return s;
  }

  String _normalizeModelPrompt(String input) {
    var s = input.replaceAll('\u0000', '');
    s = s.replaceAll(RegExp(r'\\[nrt]'), ' ');
    s = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
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
    final cleanedRaw = _stripModelNoise(raw);
    final start = cleanedRaw.indexOf('[');
    // If we can't find ']', we might be truncated.
    // Try to take everything from '[' to the end of string if ']' is missing
    final lastBracket = cleanedRaw.lastIndexOf(']');
    final end = (lastBracket != -1 && lastBracket > start)
        ? lastBracket
        : cleanedRaw.length - 1;

    if (start == -1 || end <= start) {
      // New logic: Allow single object or null
      final rawTrimmed = cleanedRaw.trim();
      if (rawTrimmed == 'null') {
        return (ok: true, cards: const <SceneCard>[], errorHint: '');
      }

      // Compatibility: Check if it's a single object (starts with {)
      final startObj = cleanedRaw.indexOf('{');
      final endObj = cleanedRaw.lastIndexOf('}');
      if (startObj != -1 && endObj != -1 && endObj > startObj) {
        // It is a single object
        final singleJson = cleanedRaw.substring(startObj, endObj + 1);
        try {
          final decodedSingle = jsonDecode(singleJson);
          return _parseDecodedList([decodedSingle], paragraphs);
        } catch (_) {
          return (
            ok: false,
            cards: const <SceneCard>[],
            errorHint: '未找到JSON对象'
          );
        }
      }
      return (ok: false, cards: const <SceneCard>[], errorHint: '未找到JSON对象或数组');
    }

    final maybeTruncatedJson =
        cleanedRaw.substring(start, lastBracket != -1 ? end + 1 : cleanedRaw.length);
    dynamic decoded;
    try {
      decoded = jsonDecode(maybeTruncatedJson);
    } catch (e) {
      // Try to fix common JSON errors from local models
      try {
        var fixed =
            maybeTruncatedJson.replaceAll('\n', '\\n').replaceAll('\r', '');

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
    if (decodedList is! List)
      return (ok: false, cards: const <SceneCard>[], errorHint: '无效数据');

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

      if (!map.containsKey('index') ||
          !map.containsKey('title') ||
          promptVal == null) {
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
      final String scene = _normalizeModelPrompt(promptVal ?? '');

      if (scene.isEmpty) {
        errors.add('第${i + 1}项 prompt为空');
        continue;
      }
      if (_looksLikeCopiedFromParagraph(scene, paragraphs[pIndex])) {
        errors.add('第${i + 1}项 prompt疑似直接复制原文');
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

  String _stripModelNoise(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '');
    s = s.replaceAll('```', '');
    return s.trim();
  }

  String _normalizeForCopyCheck(String s) {
    var t = s.replaceAll('\u0000', '');
    t = t.replaceAll(RegExp(r'[\r\n]+'), '');
    t = t.replaceAll(
      RegExp(r'[\s，。！？、；：,.!?\"\'（）()\[\]【】《》<>]'),
      '',
    );
    return t;
  }

  bool _looksLikeCopiedFromParagraph(String prompt, String paragraph) {
    final p = _normalizeForCopyCheck(paragraph);
    final s = _normalizeForCopyCheck(prompt);
    const minRun = 32;
    if (p.length < minRun || s.length < minRun) return false;
    final midStart = ((p.length - minRun) / 2).floor().clamp(0, p.length - minRun);
    final samples = <String>[
      p.substring(0, minRun),
      p.substring(midStart, midStart + minRun),
      p.substring(p.length - minRun),
    ];
    for (final sample in samples) {
      if (sample.trim().isEmpty) continue;
      if (s.contains(sample)) return true;
    }
    return false;
  }
}
