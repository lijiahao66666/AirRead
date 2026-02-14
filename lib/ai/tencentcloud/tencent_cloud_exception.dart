class TencentCloudException implements Exception {
  final String code;
  final String message;
  final String? requestId;
  final int? httpStatus;
  final int? retryAfterMs;

  TencentCloudException({
    required this.code,
    required this.message,
    this.requestId,
    this.httpStatus,
    this.retryAfterMs,
  });

  @override
  String toString() {
    final rid = requestId == null || requestId!.isEmpty ? '' : ' ($requestId)';
    return '$code: $message$rid';
  }
}

