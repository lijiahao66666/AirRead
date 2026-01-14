import 'dart:math';

import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';

class TencentTtsResult {
  final String audioBase64;
  final String requestId;

  const TencentTtsResult({
    required this.audioBase64,
    required this.requestId,
  });
}

class TencentTtsClient {
  static const String _host = 'tts.tencentcloudapi.com';
  static const String _service = 'tts';
  static const String _version = '2019-08-23';

  final TencentApiClient _api;
  final TencentCredentials _credentials;

  TencentTtsClient({
    TencentApiClient? api,
    required TencentCredentials credentials,
  })  : _api = api ?? TencentApiClient(),
        _credentials = credentials;

  Future<TencentTtsResult> textToVoice({
    required String text,
    String codec = 'mp3',
    int? voiceType,
    double? speed,
  }) async {
    final sessionId = _randomSessionId();
    final payload = <String, dynamic>{
      'Text': text,
      'SessionId': sessionId,
      'Codec': codec,
    };
    if (voiceType != null) payload['VoiceType'] = voiceType;
    if (speed != null) payload['Speed'] = speed;

    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'TextToVoice',
      version: _version,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      payload: payload,
      timeout: const Duration(seconds: 30),
    );

    return TencentTtsResult(
      audioBase64: resp['Audio']?.toString() ?? '',
      requestId: resp['RequestId']?.toString() ?? '',
    );
  }

  String _randomSessionId() {
    final r = Random();
    final t = DateTime.now().millisecondsSinceEpoch.toString();
    final n = r.nextInt(1 << 32).toRadixString(16);
    return 'airread-$t-$n';
  }
}

