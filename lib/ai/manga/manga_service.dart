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

  Future<List<MangaPanel>> generateStoryboard({
    required List<String> paragraphs,
    required String chapterTitle,
    required int panelCount,
    Future<String> Function(String prompt)? run,
    bool? enableThinking,
    String? debugName,
  }) async {
    final cap = panelCount.clamp(1, 12);
    if (paragraphs.isEmpty) return const <MangaPanel>[];
    final runFn = run ?? ((p) => _runOnlineTextModel(p, enableThinking: enableThinking));

    final prompt = _buildStoryboardPrompt(
      chapterTitle: chapterTitle,
      paragraphs: paragraphs,
      panelCount: cap,
    );
    final response = await runFn(prompt);
    var parsed = _parseAndValidateStoryboard(
      response,
      paragraphs: paragraphs,
      expectedCount: cap,
    );
    if (!parsed.ok) {
      final repairPrompt = _buildStoryboardRepairPrompt(
        chapterTitle: chapterTitle,
        paragraphs: paragraphs,
        panelCount: cap,
        rawOutput: response,
        errorHint: parsed.errorHint,
      );
      final repaired = await runFn(repairPrompt);
      parsed = _parseAndValidateStoryboard(
        repaired,
        paragraphs: paragraphs,
        expectedCount: cap,
      );
    }

    if (kDebugMode) {
      debugPrint(
        '[MANGA] storyboard debugName=$debugName ok=${parsed.ok} panels=${parsed.panels.length} hint=${parsed.errorHint}',
      );
    }

    return parsed.panels;
  }

  Future<String> expandPanelPrompt({
    required MangaPanel panel,
    required List<String> paragraphs,
    required String chapterTitle,
    required String stylePrefix,
    Future<String> Function(String prompt)? run,
    bool? enableThinking,
  }) async {
    final runFn = run ?? ((p) => _runOnlineTextModel(p, enableThinking: enableThinking));
    final start = panel.anchorStart.clamp(0, paragraphs.length - 1);
    final end = panel.anchorEnd.clamp(start, paragraphs.length - 1);
    final anchorText = paragraphs.sublist(start, end + 1).join('\n\n');

    final prompt = _buildExpandPrompt(
      chapterTitle: chapterTitle,
      panel: panel,
      anchorText: anchorText,
      stylePrefix: stylePrefix,
    );
    final response = await runFn(prompt);
    final parsed = _parseExpandedPrompt(
      response,
      anchorParagraphs: paragraphs.sublist(start, end + 1),
    );
    if (!parsed.ok) {
      final repair = _buildExpandRepairPrompt(
        chapterTitle: chapterTitle,
        panel: panel,
        anchorText: anchorText,
        stylePrefix: stylePrefix,
        rawOutput: response,
        errorHint: parsed.errorHint,
      );
      final repaired = await runFn(repair);
      final parsed2 = _parseExpandedPrompt(
        repaired,
        anchorParagraphs: paragraphs.sublist(start, end + 1),
      );
      if (!parsed2.ok) {
        throw StateError(parsed2.errorHint.isEmpty ? '提示词扩写失败' : parsed2.errorHint);
      }
      return parsed2.prompt;
    }
    return parsed.prompt;
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
    return buffer.toString();
  }

  String _buildStoryboardPrompt({
    required String chapterTitle,
    required List<String> paragraphs,
    required int panelCount,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是漫画导演。');
    buffer.writeln('章节标题：$chapterTitle');
    buffer.writeln('任务：把章节改编为“章节分镜脚本”，输出固定数量的分镜格子。');
    buffer.writeln('硬性规则：');
    buffer.writeln('1) 严禁新增剧情事实；严禁新增原文未出现的人物/地点/组织/道具。');
    buffer.writeln('2) 允许补充导演信息：景别/机位/镜头运动、光影、氛围、构图、速度线等。');
    buffer.writeln('3) 每格必须锚定原文段落索引范围 anchorStart/anchorEnd（闭区间）。');
    buffer.writeln('4) 每格必须包含：narrativeRole、subject、action、setting、time、weather、shot、camera、lighting、mood、composition。');
    buffer.writeln('5) 输出仅 JSON 数组，不要解释/Markdown。长度=$panelCount。');
    buffer.writeln('字段说明（每格对象）：');
    buffer.writeln(
        'anchorStart(int), anchorEnd(int), narrativeRole("铺垫"/"升级"/"高潮"/"收束"), title(string), subject(string), action(string), setting(string), time(string), weather(string), shot(string), camera(string), lighting(string), mood(string), composition(string), caption(string 可选)');
    buffer.writeln();
    buffer.writeln('原文段落（行首数字为全局段落索引）：');
    for (int i = 0; i < paragraphs.length; i++) {
      final normalized = _normalizeForPrompt(paragraphs[i], maxLen: 260);
      buffer.writeln('$i: $normalized');
    }
    return buffer.toString();
  }

  String _buildStoryboardRepairPrompt({
    required String chapterTitle,
    required List<String> paragraphs,
    required int panelCount,
    required String rawOutput,
    required String errorHint,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是漫画导演。你上一次输出的 JSON 不符合要求，需要修正。');
    buffer.writeln('章节标题：$chapterTitle');
    buffer.writeln('修正要求：输出仅 JSON 数组，长度=$panelCount，且每项字段齐全；anchorStart/anchorEnd 必须在合法范围内。');
    if (errorHint.trim().isNotEmpty) {
      buffer.writeln('已发现的问题：$errorHint');
    }
    buffer.writeln('上次输出（仅供参考，可能包含错误）：');
    buffer.writeln(rawOutput);
    buffer.writeln();
    buffer.writeln('原文段落（行首数字为全局段落索引）：');
    for (int i = 0; i < paragraphs.length; i++) {
      final normalized = _normalizeForPrompt(paragraphs[i], maxLen: 220);
      buffer.writeln('$i: $normalized');
    }
    buffer.writeln('现在输出最终 JSON 数组，不要解释。');
    return buffer.toString();
  }

  ({bool ok, List<MangaPanel> panels, String errorHint}) _parseAndValidateStoryboard(
    String raw, {
    required List<String> paragraphs,
    required int expectedCount,
  }) {
    final cleaned = _stripModelNoise(raw);
    final start = cleaned.indexOf('[');
    final end = cleaned.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) {
      return (ok: false, panels: const <MangaPanel>[], errorHint: '未找到JSON数组');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned.substring(start, end + 1));
    } catch (_) {
      return (ok: false, panels: const <MangaPanel>[], errorHint: 'JSON解析失败');
    }
    if (decoded is! List) {
      return (ok: false, panels: const <MangaPanel>[], errorHint: 'JSON不是数组');
    }
    final out = <MangaPanel>[];
    final errors = <String>[];

    String s(dynamic v) => _normalizeModelPrompt(v?.toString() ?? '');

    int? toInt(dynamic v) {
      if (v is int) return v;
      if (v is String) return int.tryParse(v);
      return int.tryParse(v?.toString() ?? '');
    }

    bool hasAllRequired(Map m) {
      const keys = [
        'anchorStart',
        'anchorEnd',
        'narrativeRole',
        'title',
        'subject',
        'action',
        'setting',
        'time',
        'weather',
        'shot',
        'camera',
        'lighting',
        'mood',
        'composition',
      ];
      for (final k in keys) {
        if (!m.containsKey(k)) return false;
        final val = s(m[k]);
        if (val.isEmpty) return false;
      }
      return true;
    }

    for (int i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map) {
        errors.add('第${i + 1}项不是对象');
        continue;
      }
      if (!hasAllRequired(item)) {
        errors.add('第${i + 1}项字段缺失');
        continue;
      }
      final startIdx = toInt(item['anchorStart']);
      final endIdx = toInt(item['anchorEnd']);
      if (startIdx == null || endIdx == null) {
        errors.add('第${i + 1}项 anchor 无效');
        continue;
      }
      if (startIdx < 0 || endIdx < startIdx || endIdx >= paragraphs.length) {
        errors.add('第${i + 1}项 anchor 越界');
        continue;
      }
      final role = s(item['narrativeRole']);
      final title = s(item['title']);
      final subject = s(item['subject']);
      final action = s(item['action']);
      final setting = s(item['setting']);
      final time = s(item['time']);
      final weather = s(item['weather']);
      final shot = s(item['shot']);
      final camera = s(item['camera']);
      final lighting = s(item['lighting']);
      final mood = s(item['mood']);
      final composition = s(item['composition']);
      final caption = _normalizeModelPrompt(item['caption']?.toString() ?? '');

      out.add(
        MangaPanel(
          id: const Uuid().v4(),
          anchorStart: startIdx,
          anchorEnd: endIdx,
          narrativeRole: role,
          title: title,
          subject: subject,
          action: action,
          setting: setting,
          time: time,
          weather: weather,
          shot: shot,
          camera: camera,
          lighting: lighting,
          mood: mood,
          composition: composition,
          caption: caption.isEmpty ? null : caption,
          createdAt: DateTime.now(),
        ),
      );
    }

    if (out.length != expectedCount) {
      errors.add('分镜数量不符(${out.length}/$expectedCount)');
    }
    final ok = errors.isEmpty;
    final hint = errors.isEmpty ? '' : errors.take(3).join('；');
    return (ok: ok, panels: out, errorHint: hint);
  }

  String _buildExpandPrompt({
    required String chapterTitle,
    required MangaPanel panel,
    required String anchorText,
    required String stylePrefix,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是提示词导演，负责把单格分镜蓝图扩写为文生图提示词。');
    buffer.writeln('章节标题：$chapterTitle');
    buffer.writeln('硬性规则：');
    buffer.writeln('1) 严禁新增剧情事实；严禁新增原文未出现的人物/地点/道具。');
    buffer.writeln('2) 只输出 JSON：{"prompt": "..."}，不要解释/Markdown。');
    buffer.writeln('3) prompt 不要直接复制原文句子；避免出现原文连续 20 个以上的片段。');
    buffer.writeln('4) prompt 必须信息密度高：主体/动作/环境/时间天气/镜头/光影/氛围/构图要点齐全。');
    buffer.writeln('5) 画面中禁止出现文字/水印/字幕条。');
    buffer.writeln();
    buffer.writeln('风格前缀：$stylePrefix');
    buffer.writeln();
    buffer.writeln('分镜蓝图：');
    buffer.writeln(jsonEncode(panel.toJson()));
    buffer.writeln();
    buffer.writeln('锚定原文（只作为事实来源）：');
    buffer.writeln(anchorText);
    return buffer.toString();
  }

  String _buildExpandRepairPrompt({
    required String chapterTitle,
    required MangaPanel panel,
    required String anchorText,
    required String stylePrefix,
    required String rawOutput,
    required String errorHint,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('你是提示词导演。你上一次输出不符合要求，需要修正。');
    buffer.writeln('章节标题：$chapterTitle');
    if (errorHint.trim().isNotEmpty) {
      buffer.writeln('已发现的问题：$errorHint');
    }
    buffer.writeln('上次输出：');
    buffer.writeln(rawOutput);
    buffer.writeln();
    buffer.writeln('请重新输出 JSON：{"prompt": "..."}，不要解释。');
    buffer.writeln('风格前缀：$stylePrefix');
    buffer.writeln('分镜蓝图：');
    buffer.writeln(jsonEncode(panel.toJson()));
    buffer.writeln('锚定原文（只作为事实来源）：');
    buffer.writeln(anchorText);
    return buffer.toString();
  }

  ({bool ok, String prompt, String errorHint}) _parseExpandedPrompt(
    String raw, {
    required List<String> anchorParagraphs,
  }) {
    final cleaned = _stripModelNoise(raw);
    final startObj = cleaned.indexOf('{');
    final endObj = cleaned.lastIndexOf('}');
    if (startObj == -1 || endObj == -1 || endObj <= startObj) {
      return (ok: false, prompt: '', errorHint: '未找到JSON对象');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned.substring(startObj, endObj + 1));
    } catch (_) {
      return (ok: false, prompt: '', errorHint: 'JSON解析失败');
    }
    if (decoded is! Map) {
      return (ok: false, prompt: '', errorHint: 'JSON不是对象');
    }
    final p = _normalizeModelPrompt(decoded['prompt']?.toString() ?? '');
    if (p.isEmpty) {
      return (ok: false, prompt: '', errorHint: 'prompt为空');
    }
    for (final para in anchorParagraphs) {
      if (_looksLikeCopiedFromParagraph(p, para)) {
        return (ok: false, prompt: '', errorHint: 'prompt疑似直接复制原文');
      }
    }
    return (ok: true, prompt: p, errorHint: '');
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

  String _normalizeForCopyCheck(String s) {
    var t = s.replaceAll('\u0000', '');
    t = t.replaceAll(RegExp(r'[\r\n]+'), '');
    t = t.replaceAll(
      RegExp("[\\s，。！？、；：,.!?\"'（）()\\[\\]【】《》<>]"),
      '',
    );
    return t;
  }

  bool _looksLikeCopiedFromParagraph(String prompt, String paragraph) {
    final p = _normalizeForCopyCheck(paragraph);
    final s = _normalizeForCopyCheck(prompt);
    const minRun = 32;
    if (p.length < minRun || s.length < minRun) return false;
    final midStart =
        ((p.length - minRun) / 2).floor().clamp(0, p.length - minRun);
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
