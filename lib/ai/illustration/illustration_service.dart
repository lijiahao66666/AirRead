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

  /// 使用 LLM 分析文本生成场景卡片
  Future<List<SceneCard>> analyzeScenes({
    required String chapterText,
    required String chapterTitle,
    int maxScenes = 3,
  }) async {
    // 截取前 4000 字符避免 token 溢出
    final safeText = chapterText.length > 4000
        ? chapterText.substring(0, 4000)
        : chapterText;

    final prompt = _buildScenePrompt(safeText, maxScenes);

    // 使用非流式调用获取 JSON
    // 注意：这里复用了 HunyuanTextClient 的 chatOnce 逻辑（或需改为流式拼接）
    // 为了简单，这里假设 HunyuanTextClient 支持 chatStream 聚合
    final stream = _textClient.chatStream(
      userText: prompt,
      model: 'hunyuan-standard', // 使用标准版即可，省钱且够用
    );

    final buffer = StringBuffer();
    await for (final chunk in stream) {
      buffer.write(chunk.content);
    }

    final content = buffer.toString();
    return _parseSceneCards(content, chapterTitle);
  }

  /// 提交生图任务
  Future<String> submitGeneration(SceneCard card) async {
    final prompt = card.toPrompt();
    return await _imageClient.submitTextToImageJob(prompt: prompt);
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

  String _buildScenePrompt(String text, int maxScenes) {
    return "你是小说分镜与插画策划师。\n"
        "请基于以下章节内容，抽取可用于插画生成的场景卡片。\n"
        "插画风格：古代玄幻插画\n"
        "场景数量：$maxScenes 个\n"
        "输出格式：严格 JSON 数组，每项包含字段：\n"
        "title, location, time, characters, action, mood, visual_anchors, lighting, composition, palette\n"
        "不要输出除 JSON 之外的任何文字。\n\n"
        "章节内容如下：\n"
        "$text\n";
  }

  List<SceneCard> _parseSceneCards(String jsonStr, String chapterTitle) {
    final start = jsonStr.indexOf('[');
    final end = jsonStr.lastIndexOf(']');
    if (start == -1 || end == -1) return [];

    final cleanJson = jsonStr.substring(start, end + 1);
    try {
      final List<dynamic> list = jsonDecode(cleanJson);
      return list
          .map((item) => SceneCard(
                id: const Uuid().v4(),
                title: item['title'] ?? '场景',
                location: item['location'] ?? '未知',
                time: item['time'] ?? '未知',
                characters: item['characters'] ?? '未知',
                action: item['action'] ?? '场景摘要',
                mood: item['mood'] ?? '默认',
                visualAnchors: item['visual_anchors'] ?? '',
                lighting: item['lighting'] ?? '自然光',
                composition: item['composition'] ?? '中景',
                palette: item['palette'] ?? '默认色调',
              ))
          .toList();
    } catch (e) {
      debugPrint('Parse scene cards error: $e');
      return [];
    }
  }
}
