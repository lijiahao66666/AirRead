enum SceneCardStatus {
  draft, // 仅文字
  generating, // 正在生成图片
  completed, // 图片已生成并下载
  failed, // 生成失败
}

class SceneCard {
  final String id;
  final int? anchorParagraphIndex;
  final String? anchorQuote;
  final String title;
  final String location;
  final String time;
  final String characters;
  final String action;
  final String mood;
  final String visualAnchors;
  final String lighting;
  final String composition;
  final String palette;

  // 生成状态相关
  SceneCardStatus status;
  String? jobId;
  String? localImagePath; // 本地图片路径
  String? errorMsg;
  DateTime? createdAt;

  SceneCard({
    required this.id,
    this.anchorParagraphIndex,
    this.anchorQuote,
    required this.title,
    required this.location,
    required this.time,
    required this.characters,
    required this.action,
    required this.mood,
    required this.visualAnchors,
    required this.lighting,
    required this.composition,
    required this.palette,
    this.status = SceneCardStatus.draft,
    this.jobId,
    this.localImagePath,
    this.errorMsg,
    this.createdAt,
  });

  // 用于序列化存储
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'anchorParagraphIndex': anchorParagraphIndex,
      'anchorQuote': anchorQuote,
      'title': title,
      'location': location,
      'time': time,
      'characters': characters,
      'action': action,
      'mood': mood,
      'visual_anchors': visualAnchors,
      'lighting': lighting,
      'composition': composition,
      'palette': palette,
      'status': status.index,
      'jobId': jobId,
      'localImagePath': localImagePath,
      'errorMsg': errorMsg,
      'createdAt': createdAt?.millisecondsSinceEpoch,
    };
  }

  factory SceneCard.fromJson(Map<String, dynamic> json) {
    return SceneCard(
      id: json['id'] ?? '',
      anchorParagraphIndex: json['anchorParagraphIndex'],
      anchorQuote: json['anchorQuote'],
      title: json['title'] ?? '',
      location: json['location'] ?? '',
      time: json['time'] ?? '',
      characters: json['characters'] ?? '',
      action: json['action'] ?? '',
      mood: json['mood'] ?? '',
      visualAnchors: json['visual_anchors'] ?? '',
      lighting: json['lighting'] ?? '',
      composition: json['composition'] ?? '',
      palette: json['palette'] ?? '',
      status: SceneCardStatus.values[json['status'] ?? 0],
      jobId: json['jobId'],
      localImagePath: json['localImagePath'],
      errorMsg: json['errorMsg'],
      createdAt: json['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'])
          : null,
    );
  }

  // 生成提示词
  String toPrompt({String? stylePrefix}) {
    final style = (stylePrefix == null || stylePrefix.trim().isEmpty)
        ? '古代玄幻插画，国风插画，细腻画风，柔和光影，无文字无水印'
        : stylePrefix.trim();
    return '$style\n'
        '场景：$location，$time\n'
        '人物：$characters\n'
        '动作：$action\n'
        '情绪：$mood\n'
        '视觉锚点：$visualAnchors\n'
        '光影：$lighting\n'
        '色调：$palette\n'
        '构图：$composition\n'
        '避免：现代物品、文字、logo、畸形、模糊';
  }
}
