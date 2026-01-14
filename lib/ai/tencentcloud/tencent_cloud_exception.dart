class TencentCloudException implements Exception {
  final String code;
  final String message;
  final String? requestId;

  TencentCloudException({
    required this.code,
    required this.message,
    this.requestId,
  });

  @override
  String toString() {
    final rid = requestId == null || requestId!.isEmpty ? '' : ' ($requestId)';
    return '$code: $message$rid';
  }
}

