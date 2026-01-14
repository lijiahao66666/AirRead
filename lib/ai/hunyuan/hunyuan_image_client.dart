import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';

class HunyuanImageClient {
  static const String _host = 'hunyuan.tencentcloudapi.com';
  static const String _service = 'hunyuan';
  static const String _version = '2023-09-01';

  final TencentApiClient _api;
  final TencentCredentials _credentials;

  HunyuanImageClient({
    TencentApiClient? api,
    required TencentCredentials credentials,
  })  : _api = api ?? TencentApiClient(),
        _credentials = credentials;

  Future<String> textToImageLite({
    required String prompt,
    String negativePrompt = '',
    String resolution = '512:512',
    int imageNum = 1,
    String rspImgType = 'url',
    int? seed,
  }) async {
    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'TextToImageLite',
      version: _version,
      region: 'ap-guangzhou',
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      payload: {
        'Prompt': prompt,
        if (negativePrompt.trim().isNotEmpty) 'NegativePrompt': negativePrompt,
        'Resolution': resolution,
        'ImageNum': imageNum,
        'RspImgType': rspImgType,
        if (seed != null) 'Seed': seed,
      },
    );

    final url = _firstUrl(resp);
    return url ?? '';
  }

  String? _firstUrl(dynamic node) {
    if (node == null) return null;
    if (node is String) {
      if (node.startsWith('http://') || node.startsWith('https://')) return node;
      return null;
    }
    if (node is List) {
      for (final v in node) {
        final hit = _firstUrl(v);
        if (hit != null) return hit;
      }
      return null;
    }
    if (node is Map) {
      for (final k in const [
        'ResultImage',
        'ResultImages',
        'ImageUrl',
        'ImageUrls',
        'Url',
        'Urls',
        'Data',
      ]) {
        final hit = _firstUrl(node[k]);
        if (hit != null) return hit;
      }
      for (final v in node.values) {
        final hit = _firstUrl(v);
        if (hit != null) return hit;
      }
    }
    return null;
  }
}

