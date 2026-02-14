import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../hunyuan/hunyuan_image_client.dart';
import '../hunyuan/hunyuan_text_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import 'illustration_item.dart';

typedef _AnchorRange = ({
  int anchorStart,
  int anchorEnd,
});

class IllustrationService {
  final HunyuanImageClient _imageClient;
  final HunyuanTextClient _textClient;
  final String _baseStoragePath;

  static const Duration _pollInterval = Duration(seconds: 3);
  static const int _maxPollCount = 40;

  IllustrationService({
    required TencentCredentials credentials,
    required String baseStoragePath,
  })  : _imageClient = HunyuanImageClient(credentials: credentials),
        _textClient = HunyuanTextClient(credentials: credentials),
        _baseStoragePath = baseStoragePath;

  Future<List<IllustrationItem>> generateIllustrations({
    required List<String> paragraphs,
    required String chapterTitle,
    required int count,
    required bool useLocalModel,
    Future<String> Function(String prompt)? run,
    bool? enableThinking,
    String? debugName,
  }) async {
    if (paragraphs.isEmpty) return const <IllustrationItem>[];

    int effectiveCount = count;
    if (effectiveCount <= 0) {
      int totalChars = 0;
      for (final p in paragraphs) {
        totalChars += p.length;
      }
      if (totalChars <= 1800) {
        effectiveCount = 4;
      } else if (totalChars <= 4500) {
        effectiveCount = 8;
      } else {
        effectiveCount = 12;
      }
    }
    effectiveCount = effectiveCount.clamp(1, 12);
    if (effectiveCount > paragraphs.length) {
      effectiveCount = paragraphs.length;
    }

    final runFn =
        run ?? ((p) => _runOnlineTextModel(p, enableThinking: enableThinking));

    if (useLocalModel) {
      return _generateLocal(
        paragraphs: paragraphs,
        count: effectiveCount,
        chapterTitle: chapterTitle,
        runFn: runFn,
        debugName: debugName,
      );
    } else {
      return _generateOnline(
        paragraphs: paragraphs,
        count: effectiveCount,
        chapterTitle: chapterTitle,
        runFn: runFn,
        debugName: debugName,
      );
    }
  }

  Future<List<IllustrationItem>> _generateLocal({
    required List<String> paragraphs,
    required int count,
    required String chapterTitle,
    required Future<String> Function(String prompt) runFn,
    String? debugName,
  }) async {
    final anchors = _buildAnchorsByWeightedLength(
      paragraphs: paragraphs,
      count: count,
    );

    final items = <IllustrationItem>[];

    for (int i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      final text = paragraphs
          .sublist(anchor.anchorStart, anchor.anchorEnd + 1)
          .map((p) => p.trim())
          .join('\n');
      final truncatedText = _normalizeForPrompt(text, maxLen: 600);

      final prompt = '你是插画提示词助手。请把文字改写为“可画出来的一张插画画面描述”（用于文生图）。\n'
          '要求：\n'
          '1) 不新增剧情事实；不新增人物名/地名；不要出现任何文字/水印/字幕。\n'
          '2) 输出一行，用“；”分隔：主体；动作；环境；光影；氛围。\n'
          '3) 画面要具体可视，至少补充两项细节（服饰/表情/道具/景别/色调/构图任选其二），尽量精炼（建议<=120字）。\n'
          '4) 只输出答案本身，不要输出<think>或解释；如模型会输出<answer>标签，只保留<answer>内这一行。\n'
          '示例：小纸人；轻轻摇晃；木床上；清晨阳光；温馨。\n'
          '\n'
          '章节标题：$chapterTitle\n'
          '序号：第${i + 1}张\n'
          '文字：\n$truncatedText';

      if (kDebugMode) {
        debugPrint(
          '[ILLUSTRATION] local.prompt idx=$i len=${prompt.length} debugName=$debugName',
        );
      }

      String desc = await runFn(prompt);
      desc = _normalizeModelPrompt(_stripModelNoise(desc));
      desc = desc.replaceAll(RegExp(r'^\d+[\.、\s]+'), '');
      desc = desc.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
      if (desc.isEmpty) desc = '主体；动作；环境；光影；氛围（请补充具体内容）';

      items.add(
        IllustrationItem(
          id: const Uuid().v4(),
          anchorStart: anchor.anchorStart,
          anchorEnd: anchor.anchorEnd,
          role: '插画',
          title: '第${i + 1}张',
          subject: '',
          action: '',
          setting: '',
          time: '',
          weather: '',
          shot: '',
          camera: '',
          lighting: '',
          mood: '',
          composition: '',
          prompt: desc,
          status: IllustrationStatus.promptReady,
          createdAt: DateTime.now(),
        ),
      );
    }
    return items;
  }

  Future<List<IllustrationItem>> _generateOnline({
    required List<String> paragraphs,
    required int count,
    required String chapterTitle,
    required Future<String> Function(String prompt) runFn,
    String? debugName,
  }) async {
    final chunks = (count / 6).ceil().clamp(1, 3).clamp(1, paragraphs.length);
    final chunkAnchors = _buildAnchorsByWeightedLength(
      paragraphs: paragraphs,
      count: chunks,
    );
    if (chunkAnchors.isEmpty) return const <IllustrationItem>[];
    final actualChunks = chunkAnchors.length;

    final weights = <int>[];
    final caps = <int>[];
    for (final a in chunkAnchors) {
      int w = 0;
      for (int i = a.anchorStart; i <= a.anchorEnd; i++) {
        w += paragraphs[i].length;
      }
      weights.add(w);
      caps.add((a.anchorEnd - a.anchorStart + 1).clamp(1, paragraphs.length));
    }
    final chunkCounts = _allocateCountsWithCaps(
      weights: weights,
      total: count,
      minEach: 1,
      caps: caps,
    );

    final items = <IllustrationItem>[];
    int globalIndex = 0;

    for (int i = 0; i < actualChunks; i++) {
      final anchor = chunkAnchors[i];
      final chunkParagraphs =
          paragraphs.sublist(anchor.anchorStart, anchor.anchorEnd + 1);
      final chunkCap = chunkParagraphs.length.clamp(1, paragraphs.length);
      final expectedCount = chunkCounts[i].clamp(1, chunkCap);
      final chunkText = chunkParagraphs.map((p) => p.trim()).join('\n');
      final truncatedText = _normalizeForPrompt(chunkText, maxLen: 2000);

      final prompt = _buildSceneExtractionPrompt(
        chapterTitle: chapterTitle,
        text: truncatedText,
        count: expectedCount,
      );

      if (kDebugMode) {
        debugPrint(
          '[ILLUSTRATION] online.prompt chunk=$i len=${prompt.length} debugName=$debugName',
        );
      }

      final response = await runFn(prompt);
      var scenes = _parseExtraction(response, expectedCount: expectedCount);
      if (scenes.length != expectedCount) {
        final repair = _buildRepairPrompt(
          chapterTitle: chapterTitle,
          text: truncatedText,
          count: expectedCount,
          rawOutput: response,
        );
        final repaired = await runFn(repair);
        scenes = _parseExtraction(repaired, expectedCount: expectedCount);
      }
      if (scenes.length > chunkParagraphs.length) {
        scenes = scenes.take(chunkParagraphs.length).toList();
      }
      final sceneAnchors = _buildAnchorsByWeightedLength(
        paragraphs: chunkParagraphs,
        count: scenes.length,
      );

      final loopCount =
          scenes.length < sceneAnchors.length ? scenes.length : sceneAnchors.length;
      for (int k = 0; k < loopCount; k++) {
        final subAnchor = sceneAnchors[k];
        final realStart = anchor.anchorStart + subAnchor.anchorStart;
        final realEnd = anchor.anchorStart + subAnchor.anchorEnd;

        globalIndex++;
        items.add(
          IllustrationItem(
            id: const Uuid().v4(),
            anchorStart: realStart,
            anchorEnd: realEnd,
            role: '插画',
            title: '第$globalIndex张',
            subject: '',
            action: '',
            setting: '',
            time: '',
            weather: '',
            shot: '',
            camera: '',
            lighting: '',
            mood: '',
            composition: '',
            prompt: scenes[k],
            status: IllustrationStatus.promptReady,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    if (items.length > count) {
      return items.sublist(0, count);
    }
    return items;
  }

  String _buildSceneExtractionPrompt({
    required String chapterTitle,
    required String text,
    required int count,
  }) {
    return '你是插画导演。请阅读小说片段，提取最具画面感的 $count 个关键插画场景。\n'
        '要求：\n'
        '1) 输出 $count 行，按故事顺序，尽量覆盖开端/转折/高潮/结尾（不要都在同一地点）。\n'
        '2) 每行一个场景描述（<=120字），必须用“；”分隔：主体；动作；环境；光影；氛围。\n'
        '3) 场景之间不要重复；优先选择有动作与空间变化的画面；避免纯心理描写。\n'
        '4) 不新增剧情事实；不要出现人名/地名；画面中不要有文字/水印/字幕。\n'
        '5) 严格按格式：1. ...\n'
        '示例（仅示意格式）：\n'
        '1. 少女抱紧披风回头张望；快步穿过雨夜石桥；桥下灯影摇晃；冷蓝逆光与湿润反光；紧张压迫\n'
        '2. 老人把信封压在桌角；烛火旁缓慢展开纸页；木屋内尘埃与旧书堆；暖黄侧光；克制沉重\n'
        '\n'
        '章节标题：$chapterTitle\n'
        '小说片段：\n$text\n'
        '\n'
        '现在输出 $count 行：';
  }

  String _buildRepairPrompt({
    required String chapterTitle,
    required String text,
    required int count,
    required String rawOutput,
  }) {
    final cleaned = _stripModelNoise(rawOutput);
    return '你是插画导演。你上一次输出不符合要求，需要修正。\n'
        '要求：只输出 $count 行，严格按格式：1. ... 每行一个场景。\n'
        '每行必须用“；”分隔：主体；动作；环境；光影；氛围。场景之间不要重复。\n'
        '不要解释，不要Markdown，不要JSON。\n'
        '\n'
        '章节标题：$chapterTitle\n'
        '小说片段：\n$text\n'
        '\n'
        '上次输出：\n$cleaned\n'
        '\n'
        '现在按格式输出 $count 行：';
  }

  List<String> _parseExtraction(String raw, {required int expectedCount}) {
    final clean = _stripModelNoise(raw);
    final lines = clean.split('\n');
    final out = <String>[];
    final re = RegExp(r'^\s*(\d+)[\.、\s]\s*(.*)$');

    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final m = re.firstMatch(t);
      if (m == null) continue;
      final idx = int.tryParse(m.group(1) ?? '');
      if (idx == null || idx < 1) continue;
      final content = _normalizeModelPrompt(m.group(2) ?? '');
      if (content.isEmpty) continue;
      out.add(content);
      if (out.length >= expectedCount) break;
    }

    final fallback = <String>[];
    for (final line in lines) {
      final t = _normalizeModelPrompt(line);
      if (t.length < 12) continue;
      if (t.contains('要求') || t.contains('格式')) continue;
      fallback.add(t);
      if (fallback.length >= expectedCount) break;
    }

    final combined = <String>[...out, ...fallback];
    return _dedupeCandidates(combined).take(expectedCount).toList();
  }

  List<int> _allocateCountsWithCaps({
    required List<int> weights,
    required int total,
    required int minEach,
    required List<int> caps,
  }) {
    if (weights.isEmpty) return const <int>[];
    final n = weights.length;
    if (caps.length != n) {
      return _allocateCounts(weights: weights, total: total, minEach: minEach);
    }

    final out = List<int>.filled(n, 0);
    int sumCaps = 0;
    for (final c in caps) {
      sumCaps += c < 0 ? 0 : c;
    }
    final target = total.clamp(0, sumCaps);

    int baseSum = 0;
    for (int i = 0; i < n; i++) {
      final cap = caps[i] < 0 ? 0 : caps[i];
      final base = minEach.clamp(0, cap);
      out[i] = base;
      baseSum += base;
    }

    int remaining = target - baseSum;
    if (remaining < 0) {
      int over = -remaining;
      for (int i = 0; i < n && over > 0; i++) {
        final reducible = out[i];
        final dec = reducible < over ? reducible : over;
        out[i] -= dec;
        over -= dec;
      }
      return out;
    }
    if (remaining == 0) return out;

    int sumW = 0;
    for (final w in weights) {
      sumW += w <= 0 ? 1 : w;
    }
    final desired = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final w = weights[i] <= 0 ? 1 : weights[i];
      desired[i] = (w / sumW) * remaining;
    }

    final frac = <({int idx, double frac})>[];
    int used = 0;
    for (int i = 0; i < n; i++) {
      final available = (caps[i] - out[i]).clamp(0, 1 << 30);
      int add = desired[i].floor();
      if (add > available) add = available;
      out[i] += add;
      used += add;
      final f = desired[i] - desired[i].floor();
      frac.add((idx: i, frac: f));
    }

    int left = remaining - used;
    frac.sort((a, b) => b.frac.compareTo(a.frac));
    int guard = 0;
    while (left > 0 && guard < n * 4) {
      bool advanced = false;
      for (int i = 0; i < frac.length && left > 0; i++) {
        final idx = frac[i].idx;
        if (out[idx] >= caps[idx]) continue;
        out[idx] += 1;
        left -= 1;
        advanced = true;
      }
      if (!advanced) break;
      guard++;
    }

    return out;
  }

  List<String> _dedupeCandidates(List<String> inList) {
    if (inList.isEmpty) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final s in inList) {
      final t = _normalizeModelPrompt(s);
      if (t.isEmpty) continue;
      final key = t
          .replaceAll(RegExp(r'[，,。\.、；;：:\s]+'), '')
          .toLowerCase();
      if (key.isEmpty) continue;
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(t);
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

    final dir = Directory(path.join(_baseStoragePath, 'illustration'));
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
    final out = await (() async {
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
          '[ILLUSTRATION] online_text.done thinking=$enableThinking ms=${sw.elapsedMilliseconds} outLen=${out.length}',
        );
      }
      return out;
    }()).timeout(const Duration(seconds: 45));
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
      return _buildAnchorsByParagraphCount(
        paragraphCount: paragraphs.length,
        count: cap,
      );
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
      final start = ((i * paragraphCount) / cap)
          .floor()
          .clamp(0, paragraphCount - 1);
      int end = (((i + 1) * paragraphCount) / cap).floor() - 1;
      if (i == cap - 1) end = paragraphCount - 1;
      end = end.clamp(start, paragraphCount - 1);
      out.add((anchorStart: start, anchorEnd: end));
    }
    return out;
  }

  List<int> _allocateCounts({
    required List<int> weights,
    required int total,
    required int minEach,
  }) {
    if (weights.isEmpty) return const <int>[];
    final n = weights.length;
    if (total <= 0) return List<int>.filled(n, 0);
    final base = List<int>.filled(n, minEach);
    int remaining = total - (minEach * n);
    if (remaining <= 0) {
      final out = base.toList();
      while (out.reduce((a, b) => a + b) > total) {
        final idx = out.indexWhere((e) => e > 0);
        if (idx == -1) break;
        out[idx] = out[idx] - 1;
      }
      return out;
    }

    int sumW = 0;
    for (final w in weights) {
      sumW += w <= 0 ? 1 : w;
    }
    final extra = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final w = weights[i] <= 0 ? 1 : weights[i];
      extra[i] = (w / sumW) * remaining;
    }
    final out = base.toList();
    final frac = <({int idx, double frac})>[];
    int used = 0;
    for (int i = 0; i < n; i++) {
      final add = extra[i].floor();
      out[i] += add;
      used += add;
      frac.add((idx: i, frac: extra[i] - add));
    }
    int left = remaining - used;
    frac.sort((a, b) => b.frac.compareTo(a.frac));
    for (int i = 0; i < left; i++) {
      out[frac[i % n].idx] += 1;
    }
    return out;
  }

  String _stripModelNoise(String raw) {
    var s = raw;
    String? extracted;
    for (final m
        in RegExp(
          r'<answer>\s*([\s\S]*?)\s*</answer>',
          caseSensitive: false,
        ).allMatches(s)) {
      final g = m.group(1)?.trim();
      if (g != null && g.isNotEmpty) extracted = g;
    }
    if (extracted == null) {
      for (final m
          in RegExp(
            r'<final>\s*([\s\S]*?)\s*</final>',
            caseSensitive: false,
          ).allMatches(s)) {
        final g = m.group(1)?.trim();
        if (g != null && g.isNotEmpty) extracted = g;
      }
    }
    if (extracted != null) {
      s = extracted;
    }

    s = s.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
      '',
    );
    s = s.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'</?answer>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'</?final>', caseSensitive: false), '');
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
    s = s.replaceFirst(
      RegExp(r'^answer\s*[:：\-]\s*', caseSensitive: false),
      '',
    );
    s = s.replaceFirst(RegExp(r'^(答案|答复|回答)\s*[:：]\s*'), '');
    return s;
  }
}
