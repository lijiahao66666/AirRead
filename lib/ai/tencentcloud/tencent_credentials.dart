class TencentCredentials {
  final String appId;
  final String secretId;
  final String secretKey;

  const TencentCredentials({
    required this.appId,
    required this.secretId,
    required this.secretKey,
  });

  bool get isUsable => secretId.trim().isNotEmpty && secretKey.trim().isNotEmpty;
}

