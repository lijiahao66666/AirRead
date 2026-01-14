import 'dart:convert';

import 'package:crypto/crypto.dart';

class Tc3SignerResult {
  final String authorization;
  final String signedHeaders;

  const Tc3SignerResult({
    required this.authorization,
    required this.signedHeaders,
  });
}

class Tc3Signer {
  static Tc3SignerResult signJson({
    required String secretId,
    required String secretKey,
    required String service,
    required String host,
    required String action,
    required String version,
    String? region,
    required int timestampSeconds,
    required String payloadJson,
  }) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampSeconds * 1000, isUtc: true);
    final dateStr = _formatDate(date);

    final headers = <String, String>{
      'content-type': 'application/json; charset=utf-8',
      'host': host,
    };

    final signedHeaderNames = headers.keys.toList()..sort();
    final signedHeaders = signedHeaderNames.join(';');

    final canonicalHeaders = signedHeaderNames
        .map((k) => '$k:${headers[k]!.trim()}\n')
        .join();

    final canonicalRequest = [
      'POST',
      '/',
      '',
      canonicalHeaders,
      signedHeaders,
      _sha256Hex(utf8.encode(payloadJson)),
    ].join('\n');

    final credentialScope = '$dateStr/$service/tc3_request';
    final stringToSign = [
      'TC3-HMAC-SHA256',
      timestampSeconds.toString(),
      credentialScope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    final kDate = _hmacSha256(utf8.encode('TC3$secretKey'), utf8.encode(dateStr));
    final kService = _hmacSha256(kDate, utf8.encode(service));
    final kSigning = _hmacSha256(kService, utf8.encode('tc3_request'));
    final signature = _hmacSha256Hex(kSigning, utf8.encode(stringToSign));

    final authorization =
        'TC3-HMAC-SHA256 Credential=$secretId/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature';

    return Tc3SignerResult(
      authorization: authorization,
      signedHeaders: signedHeaders,
    );
  }

  static List<int> _hmacSha256(List<int> key, List<int> msg) {
    final hmac = Hmac(sha256, key);
    return hmac.convert(msg).bytes;
  }

  static String _hmacSha256Hex(List<int> key, List<int> msg) {
    final hmac = Hmac(sha256, key);
    return hmac.convert(msg).toString();
  }

  static String _sha256Hex(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  static String _formatDate(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
