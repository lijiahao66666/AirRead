import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'http_client_factory.dart'
    if (dart.library.js_interop) 'http_client_factory_web.dart';

import '../config/auth_service.dart';
import 'tc3_signer.dart';
import 'tencent_cloud_exception.dart';

/// 流式输出返回的数据结构
class StreamChunk {
  final String content;
  final String? reasoningContent; // 思考过程内容
  final bool isReasoning; // 是否是思考过程
  final bool isComplete; // 是否完成

  StreamChunk({
    required this.content,
    this.reasoningContent,
    this.isReasoning = false,
    this.isComplete = false,
  });
}

class _ConcurrencyGate {
  final int maxConcurrent;
  final Queue<Completer<void Function()>> _waiters = Queue();
  int _active = 0;

  _ConcurrencyGate({required this.maxConcurrent}) : assert(maxConcurrent >= 1);

  Future<void Function()> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value(_release);
    }
    final c = Completer<void Function()>();
    _waiters.addLast(c);
    return c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      next.complete(_release);
      return;
    }
    _active--;
  }
}

class _Pacer {
  final Duration interval;
  DateTime _nextAllowed = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future<void>.value();

  _Pacer({required this.interval});

  Future<void> pace() {
    _tail = _tail.then((_) async {
      final now = DateTime.now();
      final waitUntil = _nextAllowed.isAfter(now) ? _nextAllowed : now;
      final wait = waitUntil.difference(now);
      if (!wait.isNegative && wait.inMilliseconds > 0) {
        await Future<void>.delayed(wait);
      }
      _nextAllowed = waitUntil.add(interval);
    });
    return _tail;
  }
}

class TencentApiClient {
  final http.Client _client;

  TencentApiClient({http.Client? client})
      : _client = client ?? createStreamingHttpClient();

  static const String _proxyUrl =
      String.fromEnvironment('AIRREAD_API_PROXY_URL', defaultValue: '');
  static const String _apiKey =
      String.fromEnvironment('AIRREAD_API_KEY', defaultValue: '');

  static String _deviceId = '';
  static String get deviceId => _deviceId;

  static Future<void> initDeviceId() async {
    if (!kIsWeb) {
      try {
        final info = DeviceInfoPlugin();
        if (defaultTargetPlatform == TargetPlatform.android) {
          final android = await info.androidInfo;
          // ANDROID_ID: 卸载重装不变，恢复出厂才变
          _deviceId = android.id.isNotEmpty ? android.id : android.fingerprint;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          final ios = await info.iosInfo;
          // identifierForVendor: 同开发者 App 全删才变
          _deviceId = ios.identifierForVendor ?? '';
        }
      } catch (e) {
        debugPrint('[TencentApiClient] device_info_plus error: $e');
      }
    }
    // fallback (Web / desktop / 平台 API 获取失败): SharedPreferences + UUID
    if (_deviceId.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final stored = (prefs.getString('device_id') ?? '').trim();
      if (stored.isNotEmpty) {
        _deviceId = stored;
      } else {
        _deviceId = const Uuid().v4();
        await prefs.setString('device_id', _deviceId);
      }
    }
    debugPrint('[TencentApiClient] deviceId=$_deviceId');
  }

  static ValueChanged<int>? onPointsBalanceChanged;

  static bool get hasProxyUrl => _proxyUrl.trim().isNotEmpty;

  static final _ConcurrencyGate _chatTranslationsGate =
      _ConcurrencyGate(maxConcurrent: 3);
  static final _Pacer _chatTranslationsPacer =
      _Pacer(interval: const Duration(milliseconds: 50));
  static final _ConcurrencyGate _chatCompletionsGate =
      _ConcurrencyGate(maxConcurrent: 5);

  static const String _kPointsBalance = 'points_balance';
  Future<void> _syncPointsFromResponse(Map<String, dynamic> response) async {
    if (response['PointsError'] != null ||
        response['InputPointsError'] != null ||
        response['OutputPointsError'] != null) {
      debugPrint(
          'PointsSyncError: ${response['PointsError'] ?? response['InputPointsError'] ?? response['OutputPointsError']}');
    }

    final balanceRaw = response['PointsBalance'];
    if (balanceRaw == null) return;
    final next = (balanceRaw is num)
        ? balanceRaw.toInt()
        : int.tryParse(balanceRaw.toString());
    if (next == null) return;
    final prefs = await SharedPreferences.getInstance();
    final fixed = next < 0 ? 0 : next;
    await prefs.setInt(_kPointsBalance, fixed);
    onPointsBalanceChanged?.call(fixed);
  }

  Future<void> _syncPointsFromBalance(dynamic balance) async {
    final next =
        (balance is num) ? balance.toInt() : int.tryParse(balance.toString());
    if (next == null) return;
    await _syncPointsFromResponse(<String, dynamic>{'PointsBalance': next});
  }

  int? _retryAfterMsFromHeaders(Map<String, String> headers) {
    String? getHeader(String key) {
      for (final e in headers.entries) {
        if (e.key.toLowerCase() == key.toLowerCase()) return e.value;
      }
      return null;
    }

    final msRaw = (getHeader('x-retry-after-ms') ?? '').trim();
    final ms = int.tryParse(msRaw);
    if (ms != null && ms > 0) return ms;

    final raRaw = (getHeader('retry-after') ?? '').trim();
    final seconds = int.tryParse(raRaw);
    if (seconds != null && seconds > 0) return seconds * 1000;
    return null;
  }

  bool _shouldRetryTencentException(TencentCloudException e) {
    if (e.code == 'QueueBusy') return true;
    final hs = e.httpStatus;
    if (hs == 429 || hs == 503) return true;
    if (e.code == 'HttpError') {
      final m = e.message;
      if (m.contains('HTTP 429') || m.contains('HTTP 503')) return true;
    }
    return _shouldRetry(e.code);
  }

  Future<Never> _throwProxyHttpError({
    required int statusCode,
    required String body,
    required Map<String, String> headers,
  }) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map) {
      final error = decoded['error']?.toString() ?? '';
      final message = decoded['message']?.toString() ?? '';
      final retryAfterMs = switch (decoded['retryAfterMs']) {
            int v => v,
            num v => v.toInt(),
            String v => int.tryParse(v),
            _ => null,
          } ??
          _retryAfterMsFromHeaders(headers);
      if (decoded.containsKey('balance')) {
        await _syncPointsFromBalance(decoded['balance']);
      }
      if (error.isNotEmpty) {
        throw TencentCloudException(
          code: error,
          message: message.isNotEmpty ? message : 'HTTP $statusCode',
          httpStatus: statusCode,
          retryAfterMs: retryAfterMs,
        );
      }
    }
    final retryAfterMs = _retryAfterMsFromHeaders(headers);
    throw TencentCloudException(
      code: 'HttpError',
      message: 'HTTP $statusCode',
      httpStatus: statusCode,
      retryAfterMs: retryAfterMs,
    );
  }

  Uri _resolveProxyUri() {
    final raw = _proxyUrl.trim();
    if (raw.isEmpty) {
      throw TencentCloudException(
        code: 'NoProxyUrl',
        message:
'API proxy URL is empty. Set AIRREAD_API_PROXY_URL or provide personal keys.',
      );
    }
    return Uri.parse(raw);
  }

  Map<String, dynamic> _normalizeProxyJsonResponse(dynamic decoded) {
    dynamic obj = decoded;
    if (obj is Map && obj['body'] is String) {
      final body = (obj['body'] as String).trim();
      if (body.isNotEmpty) {
        try {
          obj = jsonDecode(body);
        } catch (_) {
          obj = decoded;
        }
      }
    }

    if (obj is! Map) {
      throw TencentCloudException(
        code: 'InvalidResponse',
        message: 'Response is not a JSON object',
      );
    }

    final rawResponse =
        obj['Response'] ?? obj['response'] ?? obj['data'] ?? obj['result'];

    Map<String, dynamic> result;
    if (rawResponse is Map) {
      result = rawResponse.cast<String, dynamic>();
    } else {
      result = obj.cast<String, dynamic>();
    }

    // Preserve PointsBalance if it exists in the root object but not in the result
    if (obj['PointsBalance'] != null && !result.containsKey('PointsBalance')) {
      // Create a mutable copy to add PointsBalance
      result = Map<String, dynamic>.from(result);
      result['PointsBalance'] = obj['PointsBalance'];
    }

    return result;
  }

  void _throwIfTencentError(Map<String, dynamic> response) {
    final err = response['Error'];
    if (err is Map) {
      final code = err['Code']?.toString() ?? 'TencentCloudError';
      final msg = err['Message']?.toString() ?? 'Unknown error';
      final rid = response['RequestId']?.toString();
      throw TencentCloudException(code: code, message: msg, requestId: rid);
    }
  }

  Stream<StreamChunk> _singleShotStreamFromResponse(
    Map<String, dynamic> response,
  ) async* {
    String reasoning = '';
    String content = '';

    final choices = response['Choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final msg = first['Message'];
        if (msg is Map) {
          reasoning = msg['ReasoningContent']?.toString() ?? '';
          content = msg['Content']?.toString() ?? '';
        } else {
          final delta = first['Delta'];
          if (delta is Map) {
            reasoning = delta['ReasoningContent']?.toString() ?? '';
            content = delta['Content']?.toString() ?? '';
          } else {
            content = first['Content']?.toString() ?? '';
          }
        }
      }
    }

    if (reasoning.trim().isNotEmpty) {
      yield StreamChunk(
        content: '',
        reasoningContent: reasoning,
        isReasoning: true,
        isComplete: false,
      );
    }
    if (content.trim().isNotEmpty) {
      yield StreamChunk(
        content: content,
        reasoningContent: null,
        isReasoning: false,
        isComplete: false,
      );
    }
    yield StreamChunk(content: '', isComplete: true);
  }

  Future<Map<String, dynamic>> postJson({
    required String host,
    required String service,
    required String action,
    required String version,
    String? region,
    required String secretId,
    required String secretKey,
    required Map<String, dynamic> payload,
    bool useProxy = false,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 3,
  }) async {
    int retryCount = 0;

    while (true) {
      void Function()? release;
      try {
        if (action == 'ChatTranslations') {
          release = await _chatTranslationsGate.acquire();
          await _chatTranslationsPacer.pace();
        } else if (action == 'ChatCompletions') {
          release = await _chatCompletionsGate.acquire();
        }

        final usingProxy = useProxy;
        if (!usingProxy &&
            (secretId.trim().isEmpty || secretKey.trim().isEmpty)) {
          throw TencentCloudException(
            code: 'MissingCredentials',
            message: '已开启个人密钥，但未填写 SecretId/SecretKey',
          );
        }

        final now = DateTime.now().toUtc();
        final ts = now.millisecondsSinceEpoch ~/ 1000;
        final payloadJson = jsonEncode(payload);

        if (usingProxy) {
          final uri = _resolveProxyUri();
          final headers = <String, String>{
            'Content-Type': 'application/json; charset=utf-8',
          };
          final key = _apiKey.trim();
          if (key.isNotEmpty) headers['X-Api-Key'] = key;
          if (_deviceId.isNotEmpty) headers['X-Device-Id'] = _deviceId;
          if (AuthService.isLoggedIn && AuthService.token.isNotEmpty) {
            headers['X-Auth-Token'] = AuthService.token;
          }
          final proxyPayload = jsonEncode(<String, dynamic>{
            'host': host,
            'service': service,
            'action': action,
            'version': version,
            if (region != null && region.trim().isNotEmpty) 'region': region,
            'payload': payload,
            'stream': false,
            'timestamp': ts,
          });

          final resp = await _client
              .post(
                uri,
                headers: headers,
                body: proxyPayload,
              )
              .timeout(timeout);

          if (resp.statusCode < 200 || resp.statusCode >= 300) {
            await _throwProxyHttpError(
              statusCode: resp.statusCode,
              body: utf8.decode(resp.bodyBytes),
              headers: resp.headers,
            );
          }

          final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
          final response = _normalizeProxyJsonResponse(decoded);
          await _syncPointsFromResponse(response);
          final err = response['Error'];
          if (err is Map) {
            final code = err['Code']?.toString() ?? 'TencentCloudError';
            final msg = err['Message']?.toString() ?? 'Unknown error';
            final rid = response['RequestId']?.toString();
            if (_shouldRetry(code) && retryCount < maxRetries) {
              retryCount++;
              final delay = Duration(milliseconds: 200 * (1 << retryCount));
              await Future.delayed(delay);
              continue;
            }
            throw TencentCloudException(
                code: code, message: msg, requestId: rid);
          }
          return response;
        }

        final signer = Tc3Signer.signJson(
          secretId: secretId.trim(),
          secretKey: secretKey.trim(),
          service: service,
          host: host,
          action: action,
          version: version,
          region: region,
          timestampSeconds: ts,
          payloadJson: payloadJson,
        );

        final headers = <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
          if (!kIsWeb) 'Host': host,
          'X-TC-Action': action,
          'X-TC-Version': version,
          'X-TC-Timestamp': ts.toString(),
          if (region != null && region.trim().isNotEmpty)
            'X-TC-Region': region.trim(),
          'Authorization': signer.authorization,
        };

        final uri = Uri.https(host, '/');
        final resp = await _client
            .post(uri, headers: headers, body: payloadJson)
            .timeout(timeout);

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          debugPrint(
              'TencentApiClient Error: HTTP ${resp.statusCode} - ${resp.body}');
          throw TencentCloudException(
            code: 'HttpError',
            message: 'HTTP ${resp.statusCode}: ${resp.body}',
            httpStatus: resp.statusCode,
            retryAfterMs: _retryAfterMsFromHeaders(resp.headers),
          );
        }

        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is! Map) {
          debugPrint('TencentApiClient Error: Invalid JSON response');
          throw TencentCloudException(
              code: 'InvalidResponse',
              message: 'Response is not a JSON object');
        }

        final response = decoded['Response'];
        if (response is! Map) {
          debugPrint('TencentApiClient Error: Missing Response field in JSON');
          throw TencentCloudException(
              code: 'InvalidResponse', message: 'Missing Response field');
        }

        final err = response['Error'];
        if (err is Map) {
          final code = err['Code']?.toString() ?? 'TencentCloudError';
          final msg = err['Message']?.toString() ?? 'Unknown error';
          final rid = response['RequestId']?.toString();

          // 检查是否需要重试的错误码
          if (_shouldRetry(code) && retryCount < maxRetries) {
            retryCount++;
            debugPrint(
                'TencentApiClient retry $retryCount/$maxRetries for error: $code - $msg');

            // 指数退避延迟
            final delay = Duration(milliseconds: 200 * (1 << retryCount));
            await Future.delayed(delay);
            continue;
          }

          debugPrint('TencentApiClient API Error: $code - $msg (ReqId: $rid)');
          throw TencentCloudException(code: code, message: msg, requestId: rid);
        }

        return response.cast<String, dynamic>();
      } catch (e, st) {
        if (e is TencentCloudException) {
          if (_shouldRetryTencentException(e) && retryCount < maxRetries) {
            retryCount++;
            final ms = (e.retryAfterMs ?? (200 * (1 << retryCount)))
                .clamp(200, 5000);
            await Future<void>.delayed(Duration(milliseconds: ms));
            continue;
          }
          rethrow;
        }

        // 网络错误等也需要重试
        // XMLHttpRequest error usually means CORS or network unreachable.
        // If it's CORS (often "XMLHttpRequest error"), retrying won't help.
        final isXmlHttpError = e.toString().contains('XMLHttpRequest error');
        if (isXmlHttpError) {
          debugPrint(
              'TencentApiClient: Aborting retry for XMLHttpRequest error (likely CORS): $e');
          rethrow;
        }

        if (retryCount < maxRetries) {
          retryCount++;
          debugPrint(
              'TencentApiClient retry $retryCount/$maxRetries for exception: $e');

          final delay = Duration(milliseconds: 200 * (1 << retryCount));
          await Future.delayed(delay);
          continue;
        }

        debugPrint('TencentApiClient Exception: $e\n$st');
        rethrow;
      } finally {
        release?.call();
      }
    }
  }

  bool _shouldRetry(String errorCode) {
    // 需要重试的错误码
    final retryableCodes = {
      'RequestLimitExceeded', // 请求频率超限
      'RateLimitExceeded', // 频率限制
      'InternalError', // 内部错误
      'ServiceUnavailable', // 服务不可用
      'RequestTimeout', // 请求超时
    };
    return retryableCodes.contains(errorCode);
  }

  Stream<StreamChunk> _processSseLine(String line) async* {
    if (line.isEmpty) return;

    String jsonStr;
    if (line.startsWith('data: ')) {
      jsonStr = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      jsonStr = line.substring(5).trim();
    } else {
      return;
    }

    if (jsonStr == '[DONE]') {
      yield StreamChunk(content: '', isComplete: true);
      return;
    }

    try {
      final json = jsonDecode(jsonStr);
      if (json is! Map) return;

      if (json['PointsBalance'] != null) {
        await _syncPointsFromResponse(json.cast<String, dynamic>());
      }

      if (json['Response'] != null && json['Response'] is Map) {
        final inner = json['Response'] as Map<String, dynamic>;
        if (inner['PointsBalance'] != null) {
          await _syncPointsFromResponse(inner);
        }
      }

      final choices = json['Choices'];
      if (choices is! List || choices.isEmpty) {
        return;
      }

      final choice = choices.first;
      if (choice is! Map) return;

      final delta = choice['Delta'];
      if (delta is! Map) return;

      final reasoningContent = delta['ReasoningContent'];
      if (reasoningContent != null && reasoningContent.toString().isNotEmpty) {
        yield StreamChunk(
          content: '',
          reasoningContent: reasoningContent.toString(),
          isReasoning: true,
          isComplete: false,
        );
      }

      final content = delta['Content'];
      if (content != null && content.toString().isNotEmpty) {
        yield StreamChunk(
          content: content.toString(),
          isReasoning: false,
          isComplete: false,
        );
      }

      final finishReason = choice['FinishReason'];
      if (finishReason != null &&
          finishReason.toString().isNotEmpty &&
          finishReason.toString() != 'null') {
        yield StreamChunk(content: '', isComplete: true);
      }
    } catch (_) {}
  }

  Stream<StreamChunk> postStream({
    required String host,
    required String service,
    required String action,
    required String version,
    String? region,
    required String secretId,
    required String secretKey,
    required Map<String, dynamic> payload,
    bool useProxy = false,
    Duration? timeout,
    int maxRetries = 3,
  }) async* {
    int retryCount = 0;
    while (true) {
      void Function()? release;
      try {
        if (action == 'ChatTranslations') {
          release = await _chatTranslationsGate.acquire();
          await _chatTranslationsPacer.pace();
        } else if (action == 'ChatCompletions') {
          release = await _chatCompletionsGate.acquire();
        }
        final now = DateTime.now().toUtc();
        final ts = now.millisecondsSinceEpoch ~/ 1000;
        final payloadJson = jsonEncode(payload);

        final usingProxy = useProxy;
        if (!usingProxy &&
            (secretId.trim().isEmpty || secretKey.trim().isEmpty)) {
          throw TencentCloudException(
            code: 'MissingCredentials',
            message: '已开启个人密钥，但未填写 SecretId/SecretKey',
          );
        }

        if (usingProxy) {
          final uri = _resolveProxyUri();
          final request = http.Request('POST', uri);
          request.headers.addAll(<String, String>{
            'Content-Type': 'application/json; charset=utf-8',
            'Accept': 'text/event-stream',
          });
          final key = _apiKey.trim();
          if (key.isNotEmpty) request.headers['X-Api-Key'] = key;
          if (_deviceId.isNotEmpty) request.headers['X-Device-Id'] = _deviceId;
          if (AuthService.isLoggedIn && AuthService.token.isNotEmpty) {
            request.headers['X-Auth-Token'] = AuthService.token;
          }
          request.body = jsonEncode(<String, dynamic>{
            'host': host,
            'service': service,
            'action': action,
            'version': version,
            if (region != null && region.trim().isNotEmpty) 'region': region,
            'payload': payload,
            'stream': true,
            'timestamp': ts,
          });

          final streamedResponse = timeout != null
              ? await _client.send(request).timeout(timeout)
              : await _client.send(request);

          if (streamedResponse.statusCode < 200 ||
              streamedResponse.statusCode >= 300) {
            final content = await streamedResponse.stream.toBytes();
            final body = utf8.decode(content);
            await _throwProxyHttpError(
              statusCode: streamedResponse.statusCode,
              body: body,
              headers: streamedResponse.headers,
            );
          }

          final contentType =
              streamedResponse.headers['content-type']?.toLowerCase() ?? '';
          if (contentType.contains('text/event-stream')) {
            final transformer = utf8.decoder;
            String buffer = '';

            await for (final chunk
                in streamedResponse.stream.transform(transformer)) {
              buffer += chunk;

              while (true) {
                final lineIndex = buffer.indexOf('\n');
                if (lineIndex == -1) break;

                final line = buffer.substring(0, lineIndex).trim();
                buffer = buffer.substring(lineIndex + 1);
                if (line.isEmpty) continue;

                await for (final chunk in _processSseLine(line)) {
                  yield chunk;
                }
              }
            }

            if (buffer.trim().isNotEmpty) {
              await for (final chunk in _processSseLine(buffer.trim())) {
                yield chunk;
              }
            }

            yield StreamChunk(content: '', isComplete: true);
            return;
          }

          final content = await streamedResponse.stream.toBytes();
          final body = utf8.decode(content);
          final decoded = jsonDecode(body);
          final response = _normalizeProxyJsonResponse(decoded);
          await _syncPointsFromResponse(response);
          _throwIfTencentError(response);
          yield* _singleShotStreamFromResponse(response);
          return;
        }

        final signer = Tc3Signer.signJson(
          secretId: secretId.trim(),
          secretKey: secretKey.trim(),
          service: service,
          host: host,
          action: action,
          version: version,
          region: region,
          timestampSeconds: ts,
          payloadJson: payloadJson,
        );

        final headers = <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
          if (!kIsWeb) 'Host': host,
          'X-TC-Action': action,
          'X-TC-Version': version,
          'X-TC-Timestamp': ts.toString(),
          if (region != null && region.trim().isNotEmpty)
            'X-TC-Region': region.trim(),
          'Authorization': signer.authorization,
        };

        final uri = Uri.https(host, '/');
        final request = http.Request('POST', uri);
        request.headers.addAll(headers);
        request.body = payloadJson;

        final streamedResponse = timeout != null
            ? await _client.send(request).timeout(timeout)
            : await _client.send(request);

        if (streamedResponse.statusCode < 200 ||
            streamedResponse.statusCode >= 300) {
          final content = await streamedResponse.stream.toBytes();
          final body = utf8.decode(content);
          debugPrint(
              'TencentApiClient Stream Error: HTTP ${streamedResponse.statusCode} - $body');
          throw TencentCloudException(
            code: 'HttpError',
            message: 'HTTP ${streamedResponse.statusCode}: $body',
            httpStatus: streamedResponse.statusCode,
            retryAfterMs: _retryAfterMsFromHeaders(streamedResponse.headers),
          );
        }

        final transformer = utf8.decoder;
        String buffer = '';

        await for (final chunk
            in streamedResponse.stream.transform(transformer)) {
          buffer += chunk;

          while (true) {
            final lineIndex = buffer.indexOf('\n');
            if (lineIndex == -1) break;

            final line = buffer.substring(0, lineIndex).trim();
            buffer = buffer.substring(lineIndex + 1);
            if (line.isEmpty) continue;

            await for (final chunk in _processSseLine(line)) {
              yield chunk;
            }
          }
        }

        if (buffer.trim().isNotEmpty) {
          await for (final chunk in _processSseLine(buffer.trim())) {
            yield chunk;
          }
        }

        yield StreamChunk(content: '', isComplete: true);
        return;
      } catch (e) {
        if (e is TencentCloudException &&
            _shouldRetryTencentException(e) &&
            retryCount < maxRetries) {
          retryCount++;
          final ms = (e.retryAfterMs ?? (250 * (1 << retryCount))).clamp(200, 6000);
          await Future<void>.delayed(Duration(milliseconds: ms));
          continue;
        }
        rethrow;
      } finally {
        release?.call();
      }
    }
  }
}
