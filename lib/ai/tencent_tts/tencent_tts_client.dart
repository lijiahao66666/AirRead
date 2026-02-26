import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../tencentcloud/tencent_api_client.dart';
import '../tencentcloud/tencent_credentials.dart';
import '../tencentcloud/embedded_public_hunyuan_credentials.dart';
import 'tts_ws.dart';

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

  static const String _streamHost = 'tts.cloud.tencent.com';
  static const String _streamPath = '/stream_wsv2';

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
      useProxy: !usingPersonalTencentKeys(),
      payload: payload,
      timeout: const Duration(seconds: 30),
    );

    return TencentTtsResult(
      audioBase64: resp['Audio']?.toString() ?? '',
      requestId: resp['RequestId']?.toString() ?? '',
    );
  }

  Future<Uint8List> streamTextToVoiceBytes({
    required String text,
    String codec = 'mp3',
    int? voiceType,
    double? speed,
    int sampleRate = 16000,
    bool enableSubtitle = false,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!usingPersonalTencentKeys()) {
      final res = await textToVoice(
        text: text,
        codec: codec,
        voiceType: voiceType,
        speed: speed,
      );
      final audioBase64 = res.audioBase64.trim();
      if (audioBase64.isEmpty) {
        throw StateError('腾讯语音合成返回空音频');
      }
      return base64Decode(audioBase64);
    }
    final appIdText = _credentials.appId.trim();
    if (appIdText.isEmpty) {
      throw const FormatException('缺少 AppId，无法调用流式语音合成接口');
    }
    final appId = int.tryParse(appIdText);
    if (appId == null) {
      throw const FormatException('AppId 必须为整数');
    }
    final secretId = _credentials.secretId.trim();
    final secretKey = _credentials.secretKey.trim();
    if (secretId.isEmpty || secretKey.isEmpty) {
      throw const FormatException('缺少 SecretId/SecretKey，无法调用流式语音合成接口');
    }

    final sessionId = _randomSessionId();
    final url = _buildStreamWsv2Url(
      appId: appId,
      secretId: secretId,
      secretKey: secretKey,
      sessionId: sessionId,
      codec: codec,
      voiceType: voiceType,
      speed: speed,
      sampleRate: sampleRate,
      enableSubtitle: enableSubtitle,
    );

    final audio = BytesBuilder(copy: false);
    final ready = Completer<void>();
    final finished = Completer<void>();

    TtsWebSocket? ws;
    Timer? watchdog;

    void completeError(Object error, [StackTrace? st]) {
      if (!ready.isCompleted) {
        ready.completeError(error, st);
      }
      if (!finished.isCompleted) {
        finished.completeError(error, st);
      }
    }

    try {
      ws = await connectTtsWebSocket(url);

      watchdog = Timer(timeout, () {
        completeError(TimeoutException('语音合成超时'));
        ws?.close();
      });

      ws.stream.listen(
        (data) {
          if (finished.isCompleted) return;

          if (data is String) {
            try {
              final decoded = jsonDecode(data);
              if (decoded is! Map) return;

              final code = decoded['code'];
              if (code is num && code.toInt() != 0) {
                final msg = decoded['message']?.toString() ?? 'Unknown error';
                completeError(StateError('腾讯语音合成错误($code)：$msg'));
                ws?.close();
                return;
              }

              final readyFlag = decoded['ready'];
              if (readyFlag is num && readyFlag.toInt() == 1) {
                if (!ready.isCompleted) ready.complete();
              }

              final finalFlag = decoded['final'];
              if (finalFlag is num && finalFlag.toInt() == 1) {
                if (!finished.isCompleted) finished.complete();
                ws?.close();
              }
            } catch (e, st) {
              completeError(e, st);
              ws?.close();
            }
            return;
          }

          if (data is List<int>) {
            audio.add(data);
            return;
          }
          if (data is Uint8List) {
            audio.add(data);
            return;
          }
        },
        onError: (e, st) => completeError(e, st),
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );

      await ready.future.timeout(timeout);

      final messageId = _randomSessionId();
      ws.add(
        jsonEncode(<String, dynamic>{
          'session_id': sessionId,
          'message_id': messageId,
          'action': 'ACTION_SYNTHESIS',
          'data': text,
        }),
      );
      ws.add(
        jsonEncode(<String, dynamic>{
          'session_id': sessionId,
          'message_id': _randomSessionId(),
          'action': 'ACTION_COMPLETE',
          'data': '',
        }),
      );

      await finished.future.timeout(timeout);
      watchdog.cancel();

      return audio.takeBytes();
    } catch (e, st) {
      final wd = watchdog;
      if (wd != null) wd.cancel();
      if (e is TimeoutException) rethrow;
      if (e is FormatException) rethrow;
      completeError(e, st);
      rethrow;
    } finally {
      final wd = watchdog;
      if (wd != null) wd.cancel();
      try {
        final socket = ws;
        if (socket != null) {
          await socket.close();
        }
      } catch (_) {}
    }
  }

  String _randomSessionId() {
    final r = Random();
    final t = DateTime.now().millisecondsSinceEpoch.toString();
    final high = r.nextInt(1 << 16);
    final low = r.nextInt(1 << 16);
    final n = ((high << 16) | low).toRadixString(16);
    return 'airread-$t-$n';
  }

  String _buildStreamWsv2Url({
    required int appId,
    required String secretId,
    required String secretKey,
    required String sessionId,
    required String codec,
    int? voiceType,
    double? speed,
    int sampleRate = 16000,
    bool enableSubtitle = false,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired = timestamp + 24 * 60 * 60;

    final params = <String, String>{
      'Action': 'TextToStreamAudioWSv2',
      'AppId': appId.toString(),
      'Codec': codec,
      'EnableSubtitle': enableSubtitle ? 'True' : 'False',
      'Expired': expired.toString(),
      'SampleRate': sampleRate.toString(),
      'SecretId': secretId,
      'SessionId': sessionId,
      'Timestamp': timestamp.toString(),
      'Volume': '0',
    };

    if (voiceType != null) {
      params['VoiceType'] = voiceType.toString();
    }
    if (speed != null) {
      params['Speed'] = speed.toString();
    }

    final keys = params.keys.toList()..sort();
    final canonicalQuery = keys
        .map((k) =>
            '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(params[k] ?? '')}')
        .join('&');

    final signText = 'GET$_streamHost$_streamPath?$canonicalQuery';
    final hmacSha1 = Hmac(sha1, utf8.encode(secretKey));
    final signature =
        base64Encode(hmacSha1.convert(utf8.encode(signText)).bytes);

    final fullQuery =
        '$canonicalQuery&Signature=${Uri.encodeQueryComponent(signature)}';
    return 'wss://$_streamHost$_streamPath?$fullQuery';
  }
}
