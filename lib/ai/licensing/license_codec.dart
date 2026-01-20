import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

class LicensePayload {
  final int issuedAtMs;
  final int expiryAtMs;
  final int days;
  final String nonce;

  const LicensePayload({
    required this.issuedAtMs,
    required this.expiryAtMs,
    required this.days,
    required this.nonce,
  });
}

class LicenseException implements Exception {
  final String message;
  const LicenseException(this.message);
  @override
  String toString() => message;
}

class LicenseCodec {
  static const String _prefix = 'AR1';
  static const Set<int> _allowedDays = {1, 7, 15, 30, 60, 180, 360};

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

    final parts = raw.split('.');
    if (parts.length != 3) throw const LicenseException('卡密格式错误');
    if (parts[0] != _prefix) throw const LicenseException('卡密版本不支持');

    late final List<int> payloadBytes;
    late final List<int> sigBytes;
    try {
      payloadBytes = base64Url.decode(_padB64(parts[1]));
      sigBytes = base64Url.decode(_padB64(parts[2]));
    } catch (_) {
      throw const LicenseException('卡密内容无法解析');
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const LicenseException('卡密内容无效');
    }

    final issuedAtMs = _asInt(payload['iat']);
    final expiryAtMs = _asInt(payload['exp']);
    final days = _asInt(payload['days']);
    final nonce = (payload['nonce'] ?? '').toString();

    if (issuedAtMs <= 0 || expiryAtMs <= 0) {
      throw const LicenseException('卡密内容缺失');
    }
    if (!_allowedDays.contains(days)) {
      throw const LicenseException('卡密时长不支持');
    }
    if (nonce.trim().isEmpty) {
      throw const LicenseException('卡密内容缺失');
    }

    final pk = _resolvePublicKey();
    final ok = await _algo.verify(
      payloadBytes,
      signature: Signature(sigBytes, publicKey: pk),
    );
    if (!ok) throw const LicenseException('卡密校验失败');

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (expiryAtMs <= nowMs) throw const LicenseException('卡密已过期');

    return LicensePayload(
      issuedAtMs: issuedAtMs,
      expiryAtMs: expiryAtMs,
      days: days,
      nonce: nonce,
    );
  }

  static Future<String> generateFromSeed({
    required String privateSeedB64,
    required int days,
    DateTime? now,
  }) async {
    final d = days;
    if (!_allowedDays.contains(d)) {
      throw const LicenseException('days not supported');
    }
    final seed = base64Decode(privateSeedB64.trim());
    final kp = await _algo.newKeyPairFromSeed(seed);
    final t = (now ?? DateTime.now()).toUtc();
    final issuedAtMs = t.millisecondsSinceEpoch;
    final expiryAtMs = t.add(const Duration(days: 3650)).millisecondsSinceEpoch;
    final nonceBytes = _randomBytes(12);
    final nonce = base64Url.encode(nonceBytes).replaceAll('=', '');

    final payloadObj = <String, dynamic>{
      'v': 1,
      'iat': issuedAtMs,
      'exp': expiryAtMs,
      'days': d,
      'nonce': nonce,
    };
    final payloadBytes = utf8.encode(jsonEncode(payloadObj));
    final sig = await _algo.sign(payloadBytes, keyPair: kp);

    final p = base64Url.encode(payloadBytes).replaceAll('=', '');
    final s = base64Url.encode(sig.bytes).replaceAll('=', '');
    return '$_prefix.$p.$s';
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? 0;
  }

  static String _padB64(String s) {
    final m = s.length % 4;
    if (m == 0) return s;
    return s + ('=' * (4 - m));
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }
}
