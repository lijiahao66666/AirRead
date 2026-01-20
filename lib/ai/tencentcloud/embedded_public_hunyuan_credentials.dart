import 'dart:convert';

import 'tencent_credentials.dart';

TencentCredentials? _overrideCredentials;

void setTencentCredentialsOverride(TencentCredentials? credentials) {
  _overrideCredentials = credentials;
}

String _decodeObfuscated(String enc) {
  if (enc.isEmpty) return '';
  if (enc.startsWith('plain:')) return enc.substring('plain:'.length);
  if (!enc.startsWith('enc:')) return enc;
  final raw = base64Decode(enc.substring('enc:'.length));
  const salt =
      String.fromEnvironment('AIRREAD_TENCENT_XOR_SALT', defaultValue: '');
  final key = utf8.encode('AirRead.Hunyuan$salt');
  final out =
      List<int>.generate(raw.length, (i) => raw[i] ^ key[i % key.length]);
  return utf8.decode(out, allowMalformed: true).trim();
}

const String _publicAppIdEnc = '';
const String _publicSecretIdEnc = '';
const String _publicSecretKeyEnc = '';

TencentCredentials getEmbeddedPublicHunyuanCredentials() {
  final override = _overrideCredentials;
  if (override != null && override.isUsable) return override;

  const appIdEnv =
      String.fromEnvironment('AIRREAD_TENCENT_APP_ID', defaultValue: '');
  const secretIdEnv =
      String.fromEnvironment('AIRREAD_TENCENT_SECRET_ID', defaultValue: '');
  const secretKeyEnv =
      String.fromEnvironment('AIRREAD_TENCENT_SECRET_KEY', defaultValue: '');

  final appId = _decodeObfuscated(
      appIdEnv.trim().isNotEmpty ? appIdEnv : _publicAppIdEnc);
  final secretId = _decodeObfuscated(
      secretIdEnv.trim().isNotEmpty ? secretIdEnv : _publicSecretIdEnc);
  final secretKey = _decodeObfuscated(
      secretKeyEnv.trim().isNotEmpty ? secretKeyEnv : _publicSecretKeyEnc);

  return TencentCredentials(
    appId: appId,
    secretId: secretId,
    secretKey: secretKey,
  );
}
