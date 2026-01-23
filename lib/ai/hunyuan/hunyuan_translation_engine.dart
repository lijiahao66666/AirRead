import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import '../tencentcloud/tencent_cloud_exception.dart';
import '../tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../translation/engines/translation_engine.dart';

class HunyuanTranslationEngine implements TranslationEngine {
  static const String _host = 'hunyuan.tencentcloudapi.com';
  static const String _service = 'hunyuan';
  static const String _version = '2023-09-01';
  static const String _region = 'ap-guangzhou';

  final TencentApiClient _api;
  final TencentCredentials _credentials;
  final String model;

  HunyuanTranslationEngine({
    TencentApiClient? api,
    required TencentCredentials credentials,
    this.model = 'hunyuan-translation',
  })  : _api = api ?? TencentApiClient(),
        _credentials = credentials;

  @override
  String get id => 'hunyuan_translation';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) async {
    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'ChatTranslations',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      useScfProxy: !usingPersonalTencentKeys(),
      payload: {
        'Model': model,
        'Stream': false,
        'Text': text,
        if (sourceLang.trim().isNotEmpty) 'Source': _normalizeLang(sourceLang),
        if (targetLang.trim().isNotEmpty) 'Target': _normalizeLang(targetLang),
      },
    );

    return _extractText(resp);
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
  }) async {
    final out = <String>[];
    for (final t in texts) {
      out.add(await translate(
        text: t,
        sourceLang: sourceLang,
        targetLang: targetLang,
        contextSources: const [],
      ));
    }
    return out;
  }

  String _normalizeLang(String lang) {
    final v = lang.trim();
    if (v == 'zh') return 'zh';
    if (v == 'zh-TR') return 'zh-TR';
    if (v == 'zh-Hans') return 'zh';
    if (v == 'zh-Hant') return 'zh-TR';
    if (v == 'zh-TW') return 'zh-TR';
    return v;
  }

  String _extractText(Map<String, dynamic> resp) {
    final choices = resp['Choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final msg = first['Message'];
        if (msg is Map) {
          final c = msg['Content']?.toString();
          if (c != null) return c;
        }
        final delta = first['Delta'];
        if (delta is Map) {
          final c = delta['Content']?.toString();
          if (c != null) return c;
        }
        final content = first['Content']?.toString();
        if (content != null) return content;
      }
    }

    final err = resp['ErrorMsg'];
    if (err is Map) {
      throw TencentCloudException(
        code: err['Code']?.toString() ?? 'TencentCloudError',
        message: err['Message']?.toString() ?? 'Unknown error',
      );
    }

    return '';
  }
}
