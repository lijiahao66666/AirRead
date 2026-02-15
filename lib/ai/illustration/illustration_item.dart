enum IllustrationStatus {
  draft,
  promptReady,
  generating,
  completed,
  failed,
}

class IllustrationItem {
  final String id;
  final int anchorStart;
  final int anchorEnd;
  final String role;
  final String title;
  final String subject;
  final String action;
  final String setting;
  final String time;
  final String weather;
  final String shot;
  final String camera;
  final String lighting;
  final String mood;
  final String composition;
  final String? caption;

  String? prompt;
  IllustrationStatus status;
  String? jobId;
  int? chargedAtMs;
  String? localImagePath;
  String? errorMsg;
  DateTime? createdAt;

  IllustrationItem({
    required this.id,
    required this.anchorStart,
    required this.anchorEnd,
    required this.role,
    required this.title,
    required this.subject,
    required this.action,
    required this.setting,
    required this.time,
    required this.weather,
    required this.shot,
    required this.camera,
    required this.lighting,
    required this.mood,
    required this.composition,
    this.caption,
    this.prompt,
    this.status = IllustrationStatus.draft,
    this.jobId,
    this.chargedAtMs,
    this.localImagePath,
    this.errorMsg,
    this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'anchorStart': anchorStart,
      'anchorEnd': anchorEnd,
      'role': role,
      'title': title,
      'subject': subject,
      'action': action,
      'setting': setting,
      'time': time,
      'weather': weather,
      'shot': shot,
      'camera': camera,
      'lighting': lighting,
      'mood': mood,
      'composition': composition,
      'caption': caption,
      'prompt': prompt,
      'status': status.index,
      'jobId': jobId,
      'chargedAtMs': chargedAtMs,
      'localImagePath': localImagePath,
      'errorMsg': errorMsg,
      'createdAt': createdAt?.millisecondsSinceEpoch,
    };
  }

  factory IllustrationItem.fromJson(Map<String, dynamic> json) {
    final start = json['anchorStart'];
    final end = json['anchorEnd'];
    final statusRaw = json['status'];
    final statusIndex =
        statusRaw is int ? statusRaw : int.tryParse(statusRaw?.toString() ?? '') ?? 0;
    return IllustrationItem(
      id: (json['id'] ?? '').toString(),
      anchorStart: start is int ? start : int.tryParse(start?.toString() ?? '') ?? 0,
      anchorEnd: end is int ? end : int.tryParse(end?.toString() ?? '') ?? 0,
      role: (json['role'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      subject: (json['subject'] ?? '').toString(),
      action: (json['action'] ?? '').toString(),
      setting: (json['setting'] ?? '').toString(),
      time: (json['time'] ?? '').toString(),
      weather: (json['weather'] ?? '').toString(),
      shot: (json['shot'] ?? '').toString(),
      camera: (json['camera'] ?? '').toString(),
      lighting: (json['lighting'] ?? '').toString(),
      mood: (json['mood'] ?? '').toString(),
      composition: (json['composition'] ?? '').toString(),
      caption: json['caption']?.toString(),
      prompt: json['prompt']?.toString(),
      status:
          IllustrationStatus.values[statusIndex.clamp(0, IllustrationStatus.values.length - 1)],
      jobId: json['jobId']?.toString(),
      chargedAtMs: json['chargedAtMs'] is int
          ? json['chargedAtMs']
          : int.tryParse(json['chargedAtMs']?.toString() ?? ''),
      localImagePath: json['localImagePath']?.toString(),
      errorMsg: json['errorMsg']?.toString(),
      createdAt:
          json['createdAt'] != null ? DateTime.fromMillisecondsSinceEpoch(json['createdAt']) : null,
    );
  }
}
