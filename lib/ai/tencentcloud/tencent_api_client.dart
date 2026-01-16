import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

class TencentApiClient {
  final http.Client _client;

  TencentApiClient({http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> postJson({
    required String host,
    required String service,
    required String action,
    required String version,
    String? region,
    required String secretId,
    required String secretKey,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 5,
  }) async {
    int retryCount = 0;
    
    while (true) {
      try {
        final now = DateTime.now().toUtc();
        final ts = now.millisecondsSinceEpoch ~/ 1000;
        final payloadJson = jsonEncode(payload);

        final signer = Tc3Signer.signJson(
          secretId: secretId,
          secretKey: secretKey,
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
          );
        }

        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is! Map) {
          debugPrint('TencentApiClient Error: Invalid JSON response');
          throw TencentCloudException(
              code: 'InvalidResponse', message: 'Response is not a JSON object');
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
            debugPrint('TencentApiClient retry $retryCount/$maxRetries for error: $code - $msg');
            
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
          rethrow;
        }
        
        // 网络错误等也需要重试
        if (retryCount < maxRetries) {
          retryCount++;
          debugPrint('TencentApiClient retry $retryCount/$maxRetries for exception: $e');
          
          final delay = Duration(milliseconds: 200 * (1 << retryCount));
          await Future.delayed(delay);
          continue;
        }
        
        debugPrint('TencentApiClient Exception: $e\n$st');
        rethrow;
      }
    }
  }
  
  bool _shouldRetry(String errorCode) {
    // 需要重试的错误码
    final retryableCodes = {
      'RequestLimitExceeded', // 请求频率超限
      'RateLimitExceeded',    // 频率限制
      'InternalError',        // 内部错误
      'ServiceUnavailable',   // 服务不可用
      'RequestTimeout',       // 请求超时
    };
    return retryableCodes.contains(errorCode);
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
    Duration? timeout,
  }) async* {
    final now = DateTime.now().toUtc();
    final ts = now.millisecondsSinceEpoch ~/ 1000;
    final payloadJson = jsonEncode(payload);

    final signer = Tc3Signer.signJson(
      secretId: secretId,
      secretKey: secretKey,
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
      );
    }

    // 持续读取流式响应，直到连接关闭或收到[DONE]
    final transformer = utf8.decoder;
    String buffer = '';
    int chunkCount = 0;

    await for (final chunk in streamedResponse.stream.transform(transformer)) {
      buffer += chunk;
      
      // 处理buffer中的所有完整行
      while (true) {
        final lineIndex = buffer.indexOf('\n');
        if (lineIndex == -1) break;
        
        final line = buffer.substring(0, lineIndex).trim();
        buffer = buffer.substring(lineIndex + 1);
        
        if (line.startsWith('data: ')) {
          chunkCount++;
          final jsonStr = line.substring(6);

          if (jsonStr == '[DONE]') {
            return; // 流式响应结束
          }

          try {
            final json = jsonDecode(jsonStr);

            if (json is Map) {
              // 直接解析顶层Choices字段
              final choices = json['Choices'];

              if (choices is List && choices.isNotEmpty) {
                final choice = choices[0];
                final delta = choice['Delta'];

                if (delta is Map) {
                  // 检查是否有思考过程内容
                  final reasoningContent = delta['ReasoningContent'];
                  if (reasoningContent != null && reasoningContent.toString().isNotEmpty) {
                    yield StreamChunk(
                      content: '',
                      reasoningContent: reasoningContent.toString(),
                      isReasoning: true,
                      isComplete: false,
                    );
                  }

                  // 检查是否有回答内容
                  final content = delta['Content'];
                  if (content != null && content.toString().isNotEmpty) {
                    yield StreamChunk(
                      content: content.toString(),
                      isReasoning: false,
                      isComplete: false,
                    );
                  }
                }
              }
            }
          } catch (e) {
            // 继续处理下一行，不要中断流
          }
        }
      }
    }
    
    // 连接关闭，检查是否有剩余数据
    if (buffer.trim().isNotEmpty) {
      // 处理剩余数据
    }
  }
}
