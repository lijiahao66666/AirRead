enum MangaPanelStatus {
  draft,
  promptReady,
  generating,
  completed,
  failed,
}

class MangaPanel {
  final String id;
  final int anchorStart;
  final int anchorEnd;
  final String narrativeRole;
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

  String? expandedPrompt;
  MangaPanelStatus status;
  String? jobId;
  String? localImagePath;
  String? errorMsg;
  DateTime? createdAt;

  MangaPanel({
    required this.id,
    required this.anchorStart,
    required this.anchorEnd,
    required this.narrativeRole,
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
    this.expandedPrompt,
    this.status = MangaPanelStatus.draft,
    this.jobId,
    this.localImagePath,
    this.errorMsg,
    this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'anchorStart': anchorStart,
      'anchorEnd': anchorEnd,
      'narrativeRole': narrativeRole,
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
      'expandedPrompt': expandedPrompt,
      'status': status.index,
      'jobId': jobId,
      'localImagePath': localImagePath,
      'errorMsg': errorMsg,
      'createdAt': createdAt?.millisecondsSinceEpoch,
    };
  }

  factory MangaPanel.fromJson(Map<String, dynamic> json) {
    final start = json['anchorStart'];
    final end = json['anchorEnd'];
    final statusRaw = json['status'];
    final statusIndex = statusRaw is int
        ? statusRaw
        : int.tryParse(statusRaw?.toString() ?? '') ?? 0;
    return MangaPanel(
      id: (json['id'] ?? '').toString(),
      anchorStart: start is int ? start : int.tryParse(start?.toString() ?? '') ?? 0,
      anchorEnd: end is int ? end : int.tryParse(end?.toString() ?? '') ?? 0,
      narrativeRole: (json['narrativeRole'] ?? '').toString(),
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
      expandedPrompt: json['expandedPrompt']?.toString(),
      status: MangaPanelStatus.values[statusIndex.clamp(0, MangaPanelStatus.values.length - 1)],
      jobId: json['jobId']?.toString(),
      localImagePath: json['localImagePath']?.toString(),
      errorMsg: json['errorMsg']?.toString(),
      createdAt: json['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'])
          : null,
    );
  }
}
