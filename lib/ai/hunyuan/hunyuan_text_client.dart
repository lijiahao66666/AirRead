import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';

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

  Future<String> chatOnce({
    required String userText,
    String model = 'hunyuan-turbos-latest',
  }) async {
    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'ChatCompletions',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      payload: {
        'Model': model,
        'Stream': false,
        'Messages': [
          {'Role': 'user', 'Content': userText},
        ],
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
}
