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
    );

    String? first;
    Object? firstError;
    try {
      first = await run(prompt);
    } catch (e) {
      firstError = e;
    }
    if (firstError != null) {
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
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是小说分镜与插画策划师。');
    buffer.writeln('请基于给定章节的“段落列表”，抽取适合插画生成的场景卡片。');
    buffer.writeln('你可以输出0到$maxScenes个场景（这是上限，不是必须输出满额）。');
    buffer.writeln('输出必须是严格 JSON 数组，且不要输出除 JSON 之外的任何文字。');
    buffer.writeln('每项必须包含字段：');
    buffer.writeln(
      'title, location, time, characters, action, mood, visual_anchors, lighting, composition, palette, start_paragraph_index, end_paragraph_index',
    );
    buffer.writeln(
        '其中 start_paragraph_index 与 end_paragraph_index 必须有效，且 start_paragraph_index <= end_paragraph_index；end_paragraph_index 表示这张插图应该展示在该段落之后。');
    buffer.writeln('每个场景对应一个连续段落范围（闭区间），请按时间顺序输出，尽量避免范围重叠。');
    buffer.writeln();
    buffer.writeln('章节标题：$chapterTitle');
    buffer.writeln('段落如下：');
    final maxTotal = 9000;
    int total = 0;
    for (int i = 0; i < paragraphs.length; i++) {
      final line = 'P$i: ${_normalizeForPrompt(paragraphs[i], maxLen: 220)}';
      total += line.length + 1;
      if (total > maxTotal) break;
      buffer.writeln(line);
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
