import 'dart:convert';

import 'package:http/http.dart' as http;

/// Simple summarize service using Volcengine Ark (OpenAI-compatible) endpoint.
///
/// Uses env vars:
/// - VOLC_LLM_BASE_URL (default: Ark chat completions URL)
/// - VOLC_LLM_API_KEY
/// - VOLC_LLM_MODEL (default: doubao-pro-32k)
class SummarizeService {
  final http.Client _client;
  final Duration timeout;

  SummarizeService({
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  bool get isConfigured {
    final apiKey = const String.fromEnvironment('VOLC_LLM_API_KEY');
    return apiKey.trim().isNotEmpty;
  }

  Future<String> summarizeToChinese({
    required String text,
  }) async {
    final baseUrl = const String.fromEnvironment(
      'VOLC_LLM_BASE_URL',
      defaultValue: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    );
    final apiKey = const String.fromEnvironment('VOLC_LLM_API_KEY');
    final model = const String.fromEnvironment(
      'VOLC_LLM_MODEL',
      defaultValue: 'doubao-pro-32k',
    );

    if (apiKey.trim().isEmpty) {
      throw SummarizeConfigException(
        '未配置火山大模型密钥。请在启动参数中传入 VOLC_LLM_API_KEY。',
      );
    }

    final uri = Uri.parse(baseUrl);

    final prompt = '''你是一名专业的阅读助手。
请对下面的文本做“截止当前阅读进度”的总结，要求：
1) 先输出 5-8 条要点（每条不超过 20 个字），用短横线列表。
2) 再输出一段 1-2 句话的摘要。
3) 只基于原文信息，不要编造。
4) 输出中文。

文本：
$text''';

    final payload = {
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': '你是严谨的阅读总结引擎。',
        },
        {
          'role': 'user',
          'content': prompt,
        }
      ],
      'temperature': 0.2,
    };

    final resp = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SummarizeHttpException(
        'Volc summarize failed: ${resp.statusCode} ${resp.body}',
      );
    }

    final decoded = jsonDecode(resp.body);
    final choices = (decoded is Map) ? decoded['choices'] : null;
    if (choices is List && choices.isNotEmpty) {
      final msg = (choices.first as Map)['message'];
      final content = (msg is Map) ? msg['content']?.toString() : null;
      if (content != null) return content.trim();
    }

    throw SummarizeHttpException('Volc summarize invalid response');
  }
}

class SummarizeConfigException implements Exception {
  final String message;
  SummarizeConfigException(this.message);
  @override
  String toString() => message;
}

class SummarizeHttpException implements Exception {
  final String message;
  SummarizeHttpException(this.message);
  @override
  String toString() => message;
}
