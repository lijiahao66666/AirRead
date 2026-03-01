import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import '../tencentcloud/embedded_public_hunyuan_credentials.dart';

/// 流式输出返回的数据结构
class ChatStreamChunk {
  final String content;
  final String? reasoningContent;
  final bool isReasoning;
  final bool isComplete;

  ChatStreamChunk({
    required this.content,
    this.reasoningContent,
    this.isReasoning = false,
    this.isComplete = false,
  });
}

class HunyuanTextClient {
  static const String _host = 'hunyuan.tencentcloudapi.com';
  static const String _service = 'hunyuan';
  static const String _version = '2023-09-01';
  static const String _region = 'ap-guangzhou';

  final TencentApiClient _api;
  final TencentCredentials _credentials;

  HunyuanTextClient({
    TencentApiClient? api,
    required TencentCredentials credentials,
  })  : _api = api ?? TencentApiClient(),
        _credentials = credentials;

  static const String thinkModel = 'Tencent-HY-2.0-Think';
  static const String instructModel = 'Tencent-HY-2.0-Instruct';

  @Deprecated('Use chatStream for better UX')
  Future<String> chatOnce({
    required String userText,
    String model = instructModel,
  }) async {
    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'ChatCompletions',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      useProxy: !usingPersonalTencentKeys(),
      payload: {
        'Model': model,
        'Stream': false,
        'Messages': [
          {'Role': 'user', 'Content': userText},
        ],
        'EnableEnhancement': true,
        'ForceSearchEnhancement': true,
      },
    );

    final choices = resp['Choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final msg = first['Message'];
        if (msg is Map) {
          return msg['Content']?.toString() ?? '';
        }
      }
    }
    return '';
  }

  Stream<ChatStreamChunk> chatStream({
    required String userText,
    String model = instructModel,
    List<Map<String, String>>? messages,
  }) async* {
    final stream = _api.postStream(
      host: _host,
      service: _service,
      action: 'ChatCompletions',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      useProxy: !usingPersonalTencentKeys(),
      timeout: null,
      payload: {
        'Model': model,
        'Stream': true,
        'Messages': messages ??
            [
              {'Role': 'user', 'Content': userText},
            ],
        'EnableEnhancement': true,
        'ForceSearchEnhancement': true,
      },
    );

    await for (final chunk in stream) {
      yield ChatStreamChunk(
        content: chunk.content,
        reasoningContent: chunk.reasoningContent,
        isReasoning: chunk.isReasoning,
        isComplete: chunk.isComplete,
      );
    }
  }
}
