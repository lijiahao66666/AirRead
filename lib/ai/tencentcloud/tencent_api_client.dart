import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'tc3_signer.dart';
import 'tencent_cloud_exception.dart';

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
    Duration timeout = const Duration(seconds: 20),
  }) async {
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
    try {
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
        debugPrint('TencentApiClient API Error: $code - $msg (ReqId: $rid)');
        throw TencentCloudException(code: code, message: msg, requestId: rid);
      }

      return response.cast<String, dynamic>();
    } catch (e, st) {
      debugPrint('TencentApiClient Exception: $e\n$st');
      rethrow;
    }
  }
}
