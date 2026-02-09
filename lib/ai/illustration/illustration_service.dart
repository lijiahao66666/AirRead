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
    final cap = maxScenes.clamp(0, 5);
    if (cap <= 0) return const <SceneCard>[];

    final run = generateText ?? _runOnlineTextModel;
    final prompt = _buildScenePromptFromParagraphs(
      paragraphs: paragraphs,
      chapterTitle: chapterTitle,
      maxScenes: cap,
      forLocalSd: generateText != null,
    );
    if (kDebugMode) {
      debugPrint(
        '[ILLU][analyzeScenesFromParagraphs] start debugName=$debugName cap=$cap local=${generateText != null} paragraphs=${paragraphs.length} promptLen=${prompt.length}',
      );
    }

    String? first;
    Object? firstError;
    try {
      first = await run(prompt);
    } catch (e) {
      firstError = e;
    }
    if (firstError != null) {
      if (kDebugMode) {
        debugPrint(
          '[ILLU][analyzeScenesFromParagraphs] modelError debugName=$debugName err=$firstError',
        );
      }
      await _writeDebugSceneAnalysis(
        debugName: debugName,
        chapterTitle: chapterTitle,
        prompt: prompt,
        firstRaw: null,
        firstError: firstError.toString(),
        firstParsed: null,
        paragraphs: paragraphs,
      );
      return const <SceneCard>[];
    }
    final firstText = first ?? '';
    final firstParsed = _parseAndValidateSceneCards(
      firstText,
      chapterTitle: chapterTitle,
      paragraphs: paragraphs,
    );
    if (kDebugMode) {
      final preview = _truncateForDebug(firstText, 260) ?? '';
      debugPrint(
        '[ILLU][analyzeScenesFromParagraphs] parsed debugName=$debugName ok=${firstParsed.ok} cards=${firstParsed.cards.length} hint=${firstParsed.errorHint} rawPreview=${jsonEncode(preview)}',
      );
    }
    if (firstParsed.ok) {
      await _writeDebugSceneAnalysis(
        debugName: debugName,
        chapterTitle: chapterTitle,
        prompt: prompt,
        firstRaw: firstText,
        firstError: null,
        firstParsed: firstParsed,
        paragraphs: paragraphs,
      );
      return firstParsed.cards;
    }

    await _writeDebugSceneAnalysis(
      debugName: debugName,
      chapterTitle: chapterTitle,
      prompt: prompt,
      firstRaw: firstText,
      firstError: null,
      firstParsed: firstParsed,
      paragraphs: paragraphs,
    );
    if (firstParsed.cards.isNotEmpty) return firstParsed.cards;
    return const <SceneCard>[];
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
    String? stylePrefix,
    String resolution = '1024:1024',
  }) async {
    final prompt = card.toPrompt(stylePrefix: stylePrefix);
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
    final buffer = StringBuffer();
    buffer.writeln('你是小说分镜导演+插画提示词工程师。');
    buffer.writeln('目标：抽取0-$maxScenes个最适合插画的关键画面，画面要贴合情节且可直接用于生图。');
    buffer.writeln('约束：只允许依据下方“段落摘录”的信息，不要编造人物设定/地点道具/剧情细节。');
    buffer.writeln('硬性输出长度限制：最终JSON输出（UTF-8）总长度必须 <= 1000 字（尽量更短）。');
    buffer.writeln('输出：仅输出严格JSON数组，不要输出任何解释文字；不要缩进、不要换行、使用紧凑JSON。');
    buffer.writeln(
        '字段：title, location, time, characters, action, mood, visual_anchors, lighting, composition, palette, start_paragraph_index, end_paragraph_index');
    buffer.writeln(
        '要求：start_paragraph_index/end_paragraph_index必须是下方出现的段落索引，且连续闭区间；end_paragraph_index表示插图展示在该段落之后。');
    buffer.writeln('字段长度上限（包含标点）：');
    buffer.writeln('title<=14字；location<=18字；time<=12字；mood<=10字；');
    buffer.writeln('characters<=34字；action<=80字；visual_anchors<=80字；');
    buffer.writeln('lighting<=18字；composition<=18字；palette<=18字。');
    buffer.writeln('如果超过1024字，请优先减少场景数量，并缩短 action/visual_anchors 等字段。');
    if (forLocalSd) {
      buffer.writeln('本地生图要求：');
      buffer.writeln('1) 除 title 允许中文外，其余字段必须为英文，且不要使用中文标点。');
      buffer.writeln('2) action 作为生图场景描述词，必须英文，长度 <= 500 字符。');
      buffer.writeln('3) 为了保证总长度不超限，请尽量输出更少的场景（宁可少于上限）。');
    }
    buffer.writeln('写法：');
    buffer.writeln('1) title：8-14字，直指冲突/转折/高潮。');
    buffer.writeln('2) location/time：具体到室内外/地形/天气/时辰。');
    buffer.writeln('3) characters：人数+外观(衣着/发型/表情/姿态)+彼此位置关系。');
    buffer.writeln('4) action：用镜头语言写画面(景别/机位/动作/互动/关键物件/动态细节)。');
    buffer.writeln('5) visual_anchors：5-12个名词短语(道具/环境/纹理/标志物)。');
    buffer.writeln(
        '6) lighting/composition/palette：写成可用于生图的具体描述(光源方向/氛围/构图/色调)。');
    buffer.writeln();
    buffer.writeln(
        '章节标题：${chapterTitle.trim().isEmpty ? '正文' : chapterTitle.trim()}');
    buffer.writeln('段落摘录：');

    final n = paragraphs.length;
    final indices = <int>[];
    if (n <= 18) {
      for (int i = 0; i < n; i++) {
        indices.add(i);
      }
    } else {
      for (int i = 0; i < 6; i++) {
        indices.add(i);
      }
      final midStart = ((n - 6) ~/ 2).clamp(6, n - 12);
      for (int i = 0; i < 6; i++) {
        indices.add(midStart + i);
      }
      for (int i = n - 6; i < n; i++) {
        indices.add(i);
      }
    }
    final unique = indices.toSet().toList()..sort();
    for (final i in unique) {
      if (i < 0 || i >= n) continue;
      buffer.writeln('P$i: ${_normalizeForPrompt(paragraphs[i], maxLen: 90)}');
    }

    return buffer.toString();
  }

  ({bool ok, List<SceneCard> cards, String errorHint})
      _parseAndValidateSceneCards(
    String raw, {
    required String chapterTitle,
    required List<String> paragraphs,
  }) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) {
      return (ok: false, cards: const <SceneCard>[], errorHint: '未找到JSON数组');
    }

    final cleanJson = raw.substring(start, end + 1);
    dynamic decoded;
    try {
      decoded = jsonDecode(cleanJson);
    } catch (e) {
      return (ok: false, cards: const <SceneCard>[], errorHint: 'JSON解析失败');
    }
    if (decoded is! List) {
      return (ok: false, cards: const <SceneCard>[], errorHint: 'JSON不是数组');
    }

    final List<SceneCard> out = [];
    final List<String> errors = [];
    for (int i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map) {
        errors.add('第${i + 1}项不是对象');
        continue;
      }
      final map = item.cast<String, dynamic>();
      final dynamic startRaw = map['start_paragraph_index'];
      final dynamic endRaw = map['end_paragraph_index'];
      final int? startIdx = startRaw is int
          ? startRaw
          : (startRaw is String ? int.tryParse(startRaw) : null);
      final int? endIdx = endRaw is int
          ? endRaw
          : (endRaw is String ? int.tryParse(endRaw) : null);
      if (startIdx == null ||
          endIdx == null ||
          startIdx < 0 ||
          endIdx < 0 ||
          startIdx >= paragraphs.length ||
          endIdx >= paragraphs.length ||
          startIdx > endIdx) {
        errors.add('第${i + 1}项 段落范围无效');
        continue;
      }

      out.add(SceneCard(
        id: const Uuid().v4(),
        startParagraphIndex: startIdx,
        endParagraphIndex: endIdx,
        title: (map['title'] ?? '场景').toString(),
        location: (map['location'] ?? '未知').toString(),
        time: (map['time'] ?? '未知').toString(),
        characters: (map['characters'] ?? '未知').toString(),
        action: (map['action'] ?? '场景摘要').toString(),
        mood: (map['mood'] ?? '默认').toString(),
        visualAnchors: (map['visual_anchors'] ?? '').toString(),
        lighting: (map['lighting'] ?? '自然光').toString(),
        composition: (map['composition'] ?? '中景').toString(),
        palette: (map['palette'] ?? '默认色调').toString(),
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
