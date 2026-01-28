import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

class LicensePayload {
  final int points;
  const LicensePayload({required this.points});
}

class LicenseException implements Exception {
  final String message;
  const LicenseException(this.message);
  @override
  String toString() => message;
}

class LicenseCodec {
  static const String _prefixPointsV3 = 'P3';

  static const List<int> _pointsByIndex = [
    50000,
    100000,
    200000,
    500000,
    1000000,
  ];

  static const int _v3NonceLength = 4;
  static const int _v3SignatureLength = 64;

  static const String publicKeyB64 = String.fromEnvironment(
    'AIRREAD_LICENSE_PUBLIC_KEY_B64',
    defaultValue: 'Z+RpD1T+mPNA3EDYVl8jJwpCTn5oEWeXbhy+rbmObpc=',
  );

  static final Ed25519 _algo = Ed25519();

  static SimplePublicKey? publicKeyOverride;

  static SimplePublicKey _resolvePublicKey() {
    final override = publicKeyOverride;
    if (override != null) return override;
    final raw = publicKeyB64.trim();
    if (raw.isEmpty) {
      throw const LicenseException('未配置卡密公钥');
    }
    final bytes = base64Decode(raw);
    return SimplePublicKey(bytes, type: KeyPairType.ed25519);
  }

  static Future<LicensePayload> verifyAndParse(String code) async {
    final raw = code.trim();
    if (raw.isEmpty) throw const LicenseException('请输入卡密');

    if (raw.startsWith(_prefixPointsV3)) {
      return _verifyAndParsePointsV3(raw);
    } else {
      throw const LicenseException('卡密版本不支持');
    }
  }

  static Future<LicensePayload> _verifyAndParsePointsV3(String raw) async {
    final body =
        raw.substring(_prefixPointsV3.length).replaceAll(RegExp(r'\s+'), '');
    if (body.isEmpty) throw const LicenseException('卡密格式错误');
    final bytes = _base64UrlDecode(body);
    const int payloadLen = 1 + _v3NonceLength;
    const int expectedLen = payloadLen + _v3SignatureLength;
    if (bytes.length != expectedLen) {
      throw const LicenseException('卡密内容无法解析');
    }
    final payload = bytes.sublist(0, payloadLen);
    final sigBytes = bytes.sublist(payloadLen);
    final index = payload[0];

    if (index < 0 || index >= _pointsByIndex.length) {
      throw const LicenseException('卡密面额不支持');
    }
    final points = _pointsByIndex[index];

    final pk = _resolvePublicKey();
    final ok = await _algo.verify(
      payload,
      signature: Signature(sigBytes, publicKey: pk),
    );
    if (!ok) throw const LicenseException('卡密校验失败');
    return LicensePayload(points: points);
  }

  static Future<String> generateSignedPointsFromSeed({
    required String privateSeedB64,
    required int points,
    DateTime? now,
  }) async {
    final idx = _pointsByIndex.indexOf(points);
    if (idx < 0) {
      throw const LicenseException('points not supported');
    }
    final seed = base64Decode(privateSeedB64.trim());
    if (seed.length != 32) {
      throw const LicenseException('privateSeedB64长度不正确');
    }
    now?.millisecondsSinceEpoch;
    final kp = await _algo.newKeyPairFromSeed(seed);
    final nonceBytes = _randomBytes(_v3NonceLength);
    final payload = <int>[idx, ...nonceBytes];
    final sig = await _algo.sign(payload, keyPair: kp);
    final bytes = <int>[...payload, ...sig.bytes];
    final body = _base64UrlEncode(bytes);
    return '$_prefixPointsV3$body';
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static String _base64UrlEncode(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static List<int> _base64UrlDecode(String input) {
    final padded = input + ('=' * ((4 - input.length % 4) % 4));
    try {
      return base64Url.decode(padded);
    } catch (_) {
      throw const LicenseException('卡密内容无法解析');
    }
  }
}
