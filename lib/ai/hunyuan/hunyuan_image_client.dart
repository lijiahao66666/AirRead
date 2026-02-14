import 'dart:convert';
import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import '../tencentcloud/embedded_public_hunyuan_credentials.dart';

class HunyuanImageClient {
  static const String _host = 'aiart.tencentcloudapi.com';
  static const String _service = 'aiart';
  static const String _version = '2022-12-29';
  static const String _region = 'ap-guangzhou';

  final TencentApiClient _api;
  final TencentCredentials _credentials;

  HunyuanImageClient({
    TencentApiClient? api,
    required TencentCredentials credentials,
  })  : _api = api ?? TencentApiClient(),
        _credentials = credentials;

  String _truncateUtf8(String s, {required int maxBytes}) {
    if (maxBytes <= 0) return '';
    final raw = s.trim();
    final rawBytes = utf8.encode(raw);
    if (rawBytes.length <= maxBytes) return raw;

    final out = StringBuffer();
    int used = 0;
    for (final r in raw.runes) {
      final ch = String.fromCharCode(r);
      final b = utf8.encode(ch).length;
      if (used + b > maxBytes) break;
      out.write(ch);
      used += b;
    }
    return out.toString().trimRight();
  }

  /// 提交文生图任务
  /// 返回 JobId
  Future<String> submitTextToImageJob({
    required String prompt,
    String resolution = '1024:1024',
    int revise = 1,
    int styles =
        201, // 201: 日系动漫, 202: 3D, 203: 水墨, 204: 油画, ... (这里先给个默认值，后续可扩展)
  }) async {
    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'SubmitTextToImageJob',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      useScfProxy: !usingPersonalTencentKeys(),
      timeout: const Duration(seconds: 60),
      maxRetries: 120,
      payload: {
        'Prompt': _truncateUtf8(prompt, maxBytes: 1024),
        'Resolution': resolution,
        'Revise': revise,
        // 'Styles': [styles.toString()], // 可选，暂时不传，由 prompt 控制
      },
    );

    final jobId = resp['JobId'];
    if (jobId == null || jobId.toString().isEmpty) {
      throw Exception('Failed to get JobId from response: $resp');
    }
    return jobId.toString();
  }

  /// 查询任务状态
  /// 返回包含 JobStatusCode, ResultImage 等字段的 Map
  /// JobStatusCode:
  /// 1: 初始化
  /// 2: 处理中
  /// 3: 生成中
  /// 4: 失败
  /// 5: 成功
  Future<Map<String, dynamic>> queryTextToImageJob(String jobId) async {
    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'QueryTextToImageJob',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      useScfProxy: !usingPersonalTencentKeys(),
      timeout: const Duration(seconds: 60),
      maxRetries: 120,
      payload: {
        'JobId': jobId,
      },
    );
    return resp;
  }
}
