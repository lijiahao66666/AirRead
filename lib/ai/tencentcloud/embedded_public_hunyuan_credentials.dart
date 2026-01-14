import 'dart:convert';

import 'tencent_credentials.dart';

String _decodeObfuscated(String enc) {
  if (enc.isEmpty) return '';
  if (enc.startsWith('plain:')) return enc.substring('plain:'.length);
  if (!enc.startsWith('enc:')) return '';
  final raw = base64Decode(enc.substring('enc:'.length));
  final key = utf8.encode('AirRead.Hunyuan');
  final out = List<int>.generate(raw.length, (i) => raw[i] ^ key[i % key.length]);
  return utf8.decode(out, allowMalformed: true).trim();
}

const String _publicAppIdEnc = 'enc:';
const String _publicSecretIdEnc = 'enc:ACI7FlUSPBoZLwYQLVg3KgAnYCs3NWwjQic/QQlZCiJFNVcg';
const String _publicSecretKeyEnc = 'enc:Ng8zATIvVH8gHg89ERMcJSorOgEsF28NQB82HxMAFlg=';

TencentCredentials getEmbeddedPublicHunyuanCredentials() {
  final appId = _decodeObfuscated(_publicAppIdEnc);
  final secretId = _decodeObfuscated(_publicSecretIdEnc);
  final secretKey = _decodeObfuscated(_publicSecretKeyEnc);
  return TencentCredentials(appId: appId, secretId: secretId, secretKey: secretKey);
}
