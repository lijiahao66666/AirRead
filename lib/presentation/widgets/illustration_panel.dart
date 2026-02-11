import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../providers/ai_model_provider.dart';
import '../providers/illustration_provider.dart';
import '../../ai/illustration/scene_card.dart';
import 'scene_image.dart';

class IllustrationPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String bookId;
  final String chapterId;
  final String chapterTitle;
  final String chapterContent;
  final String? initialSelectionText;
  final bool autoGenerateFromSelection;
  final String? onlySceneId;

  const IllustrationPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.bookId,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterContent,
    this.initialSelectionText,
    this.autoGenerateFromSelection = false,
    this.onlySceneId,
  });

  @override
  State<IllustrationPanel> createState() => _IllustrationPanelState();
}

class _IllustrationPanelState extends State<IllustrationPanel> {
  String _styleKey = '国风';
  String _ratioKey = '1:1';
  static const int _imageCostPoints = 20000;
  final Set<String> _pendingGenerateCardIds = {};

  String _toastText = '';
  Timer? _toastTimer;

  void _showToast(String msg) {
    final t = msg.trim();
    if (t.isEmpty) return;
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _toastText = t;
    });
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      setState(() {
        _toastText = '';
      });
    });
  }

  static const Map<String, String> _stylePrompts = {
    '国风': '古代玄幻插画，国风插画，细腻画风，柔和光影，无文字无水印',
    '水墨': '古代玄幻插画，水墨国风，留白，柔和光影，无文字无水印',
    '厚涂': '古代玄幻插画，厚涂风格，电影感光影，高细节，无文字无水印',
    '日漫': '古代玄幻插画，日系动漫风格，线条清晰，柔和光影，无文字无水印',
    '写实': '古代玄幻插画，写实风格，电影级光影，高细节，无文字无水印',
  };

  static const Map<String, String> _ratioToResolution = {
    '1:1': '1024:1024',
    '3:4': '768:1024',
    '4:3': '1024:768',
    '9:16': '768:1280',
    '16:9': '1280:768',
  };

  double _ratioKeyToAspect(String k) {
    return switch (k) {
      '1:1' => 1.0,
      '3:4' => 3 / 4,
      '4:3' => 4 / 3,
      '9:16' => 9 / 16,
      '16:9' => 16 / 9,
      _ => 1.0,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<IllustrationProvider>();
      final selection = widget.initialSelectionText?.trim() ?? '';
      if (widget.autoGenerateFromSelection && selection.isNotEmpty) {
        unawaited(provider.generateFromSelection(
          chapterId: widget.chapterId,
          selectionText: selection,
        ));
      }
    });
  }

  Future<void> _generateWithPoints({
    required IllustrationProvider provider,
    required AiModelProvider aiModel,
    required bool usingPersonal,
    required SceneCard card,
    required String stylePrefix,
    required String resolution,
  }) async {
    if (card.status == SceneCardStatus.generating) return;
    if (_pendingGenerateCardIds.contains(card.id)) return;
    _pendingGenerateCardIds.add(card.id);
    bool deducted = false;
    if (!usingPersonal) {
      if (aiModel.pointsBalance < _imageCostPoints) {
        _pendingGenerateCardIds.remove(card.id);
        _showToast('积分不足，无法生成');
        return;
      }
      await aiModel.addPoints(-_imageCostPoints);
      deducted = true;
    }
    try {
      await provider.generateImage(
        widget.chapterId,
        card,
        stylePrefix: stylePrefix,
        resolution: resolution,
      );
      if (deducted && card.status == SceneCardStatus.failed) {
        await aiModel.addPoints(_imageCostPoints);
      }
    } finally {
      _pendingGenerateCardIds.remove(card.id);
    }
  }

  Future<bool> _confirmReanalyze() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('重新分析本章插图？'),
          content: const Text('将覆盖当前场景卡片，需要重新分析。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新分析'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _reanalyzeChapter({
    required IllustrationProvider provider,
    required AiModelProvider aiModel,
    required bool usingPersonal,
  }) async {
    if (provider.isAnalyzingOrQueued(widget.chapterId)) {
      _showToast('正在分析中...');
      return;
    }
    final content = widget.chapterContent.trim();
    if (content.isEmpty) {
      _showToast('章节内容为空');
      return;
    }
    if (!aiModel.illustrationEnabled) {
      _showToast('请先开启插图功能');
      return;
    }
    if (aiModel.source == AiModelSource.none) {
      _showToast('请先选择AI模型');
      return;
    }
    final ok = await _confirmReanalyze();
    if (!ok) return;

    provider.clearChapter(widget.chapterId);

    Future<String> Function(String prompt)? generateText;
    if (aiModel.source == AiModelSource.local) {
      if (!aiModel.loaded) {
        _showToast('本地模型未就绪');
        return;
      }
      generateText = (prompt) => aiModel.generate(
            prompt: prompt,
            maxTokens: 1024,
            temperature: 0.2,
          );
    }

    try {
      _showToast('开始重新分析...');
      await provider.analyzeChapter(
        chapterId: widget.chapterId,
        chapterTitle: widget.chapterTitle.trim().isEmpty
            ? '正文'
            : widget.chapterTitle.trim(),
        content: content,
        maxScenes: aiModel.maxIllustrationsPerChapter,
        force: true,
        pointsBalance: aiModel.pointsBalance,
        generateText: generateText,
      );
    } catch (e) {
      _showToast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color cardBg = widget.isDark
        ? Colors.white.withOpacityCompat(0.07)
        : AppColors.mistWhite;

    return Consumer<IllustrationProvider>(
      builder: (context, provider, child) {
        final aiModel = context.watch<AiModelProvider>();
        final usingPersonal = usingPersonalTencentKeys();
        final isLocal = aiModel.source == AiModelSource.local;
        final analyzing = provider.isAnalyzing(widget.chapterId);
        final analyzingOrQueued =
            provider.isAnalyzingOrQueued(widget.chapterId);
        final canGenerateImage = !isLocal &&
            (usingPersonal || aiModel.pointsBalance >= _imageCostPoints);
        final selectedStyle = _stylePrompts[_styleKey] ?? _stylePrompts['国风']!;
        final selectedResolution =
            _ratioToResolution[_ratioKey] ?? _ratioToResolution['1:1']!;
        final selectedAspectRatio = _ratioKeyToAspect(_ratioKey);
        final scenes = provider.getScenes(widget.chapterId);
        final visibleScenes = widget.onlySceneId == null
            ? scenes
            : scenes.where((e) => e.id == widget.onlySceneId).toList();

        return Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                border: Border.all(
                  color: widget.textColor.withOpacityCompat(0.08),
                  width: AppTokens.stroke,
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.onlySceneId == null)
                          Row(
                            children: [
                              if (analyzing)
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.textColor
                                        .withOpacityCompat(0.55),
                                  ),
                                )
                              else if (analyzingOrQueued)
                                Icon(
                                  Icons.schedule_rounded,
                                  size: 14,
                                  color:
                                      widget.textColor.withOpacityCompat(0.5),
                                ),
                              if (analyzing || analyzingOrQueued)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Text(
                                    analyzing ? '分析中' : '等待分析',
                                    style: TextStyle(
                                      color: widget.textColor
                                          .withOpacityCompat(0.6),
                                      fontSize: 12,
                                      height: 1.0,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: analyzingOrQueued
                                    ? null
                                    : () => unawaited(
                                          _reanalyzeChapter(
                                            provider: provider,
                                            aiModel: aiModel,
                                            usingPersonal: usingPersonal,
                                          ),
                                        ),
                                icon:
                                    const Icon(Icons.refresh_rounded, size: 16),
                                label: const Text('重新分析本章'),
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.techBlue,
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(0, 0),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  textStyle: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    height: 1.0,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (widget.onlySceneId == null)
                          const SizedBox(height: 8),
                        _settingsRow(
                          label: '风格',
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _stylePrompts.keys.map((k) {
                              final active = k == _styleKey;
                              return _chip(
                                label: k,
                                active: active,
                                onTap: () => setState(() => _styleKey = k),
                              );
                            }).toList(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _settingsRow(
                          label: '画幅',
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _ratioToResolution.keys.map((k) {
                              final active = k == _ratioKey;
                              return _chip(
                                label: k,
                                active: active,
                                onTap: () => setState(() => _ratioKey = k),
                              );
                            }).toList(),
                          ),
                        ),
                        if (isLocal)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              '本地模式暂不支持插图生成功能。',
                              style: TextStyle(
                                color: widget.textColor.withOpacityCompat(0.65),
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ),
                        if (!isLocal && !usingPersonal && !canGenerateImage)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '积分不足2万，无法生成插图，请先购买积分。',
                                    style: TextStyle(
                                      color: widget.textColor
                                          .withOpacityCompat(0.65),
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final uri = Uri.parse(
                                        'https://pay.ldxp.cn/item/ajnlvp');
                                    await launchUrl(uri,
                                        mode: LaunchMode.externalApplication);
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.techBlue,
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 0),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text(
                                    '购买',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visibleScenes.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.image_search_rounded,
                                  size: 48,
                                  color:
                                      widget.textColor.withOpacityCompat(0.2),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无插图',
                                  style: TextStyle(
                                    color:
                                        widget.textColor.withOpacityCompat(0.4),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  widget.onlySceneId == null
                                      ? '请在AI伴读中开启插图开关并进入章节后自动分析场景。'
                                      : '未找到该插图。',
                                  style: TextStyle(
                                    color:
                                        widget.textColor.withOpacityCompat(0.6),
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 16),
                            itemCount: visibleScenes.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 16),
                            itemBuilder: (context, index) {
                              return _SceneCardWidget(
                                card: visibleScenes[index],
                                isDark: widget.isDark,
                                textColor: widget.textColor,
                                canGenerate: canGenerateImage,
                                imageAspectRatio: selectedAspectRatio,
                                onEditPrompt: () => unawaited(
                                  _editPromptDialog(
                                    provider: provider,
                                    card: visibleScenes[index],
                                  ),
                                ),
                                onGenerate: () => unawaited(
                                  _generateWithPoints(
                                    provider: provider,
                                    aiModel: aiModel,
                                    usingPersonal: usingPersonal,
                                    card: visibleScenes[index],
                                    stylePrefix: selectedStyle,
                                    resolution: selectedResolution,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            if (_toastText.isNotEmpty)
              Center(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _toastText.isNotEmpty ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacityCompat(0.72),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _toastText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          height: 1.1,
                          decoration: TextDecoration.none,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _editPromptDialog({
    required IllustrationProvider provider,
    required SceneCard card,
  }) async {
    final controller = TextEditingController(text: card.action);
    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('编辑提示词'),
            content: TextField(
              controller: controller,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: '输入用于生图的提示词',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  provider.updateScenePrompt(
                    chapterId: widget.chapterId,
                    sceneId: card.id,
                    prompt: controller.text,
                  );
                  Navigator.of(context).pop();
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Widget _settingsRow({required String label, required Widget child}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: widget.textColor.withOpacityCompat(0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: child),
      ],
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final bg = active ? AppColors.techBlue : widget.textColor.withOpacity(0.06);
    final fg = active ? Colors.white : widget.textColor.withOpacity(0.85);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? AppColors.techBlue
                : widget.textColor.withOpacityCompat(0.08),
            width: AppTokens.stroke,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: fg,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

class _SceneCardWidget extends StatelessWidget {
  final SceneCard card;
  final bool isDark;
  final Color textColor;
  final VoidCallback onGenerate;
  final VoidCallback onEditPrompt;
  final double imageAspectRatio;
  final bool canGenerate;

  const _SceneCardWidget({
    required this.card,
    required this.isDark,
    required this.textColor,
    required this.onGenerate,
    required this.onEditPrompt,
    required this.imageAspectRatio,
    required this.canGenerate,
  });

  @override
  Widget build(BuildContext context) {
    // 卡片背景稍微深一点，与面板背景区分
    final bg = isDark ? Colors.white.withOpacityCompat(0.05) : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: textColor.withOpacityCompat(0.06),
          width: AppTokens.stroke,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态/图片区
          AspectRatio(
            aspectRatio: imageAspectRatio,
            child: _buildMediaArea(context),
          ),

          // 文本信息区
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        card.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                    ),
                    if (card.status != SceneCardStatus.generating)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: TextButton.icon(
                          onPressed: canGenerate ? onGenerate : null,
                          icon: const Icon(Icons.brush_rounded, size: 16),
                          label: Text(card.status == SceneCardStatus.draft
                              ? '生成'
                              : '重新生成'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: AppColors.techBlue,
                            backgroundColor:
                                AppColors.techBlue.withOpacityCompat(0.1),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '提示词',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: textColor.withOpacityCompat(0.7),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: onEditPrompt,
                      icon: Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: textColor.withOpacityCompat(0.65),
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: '编辑提示词',
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: onEditPrompt,
                  child: Text(
                    card.action.trim().isEmpty ? '（暂无）' : card.action,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: textColor.withOpacityCompat(0.75),
                    ),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaArea(BuildContext context) {
    switch (card.status) {
      case SceneCardStatus.draft:
        return Container(
          color: textColor.withOpacityCompat(0.03),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.image_outlined,
                size: 48,
                color: textColor.withOpacityCompat(0.1),
              ),
              Positioned(
                bottom: 16,
                child: Text(
                  '点击生成预览画面',
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor.withOpacityCompat(0.4),
                  ),
                ),
              ),
            ],
          ),
        );

      case SceneCardStatus.generating:
        return Container(
          color: textColor.withOpacityCompat(0.03),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.techBlue,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'AI 正在绘图...',
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor.withOpacityCompat(0.6),
                  ),
                ),
              ],
            ),
          ),
        );

      case SceneCardStatus.completed:
        if (card.localImagePath != null) {
          return GestureDetector(
            onTap: () =>
                _openImagePreview(context: context, path: card.localImagePath!),
            child: buildSceneImage(
              card.localImagePath!,
              fit: BoxFit.contain,
            ),
          );
        }
        return const Center(child: Text('图片文件丢失'));

      case SceneCardStatus.failed:
        return Container(
          color: Colors.red.withOpacityCompat(0.05),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 32),
                const SizedBox(height: 8),
                Text(
                  '生成失败',
                  style: TextStyle(color: Colors.red.withOpacityCompat(0.8)),
                ),
                if (card.errorMsg != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      card.errorMsg!,
                      style: const TextStyle(fontSize: 10, color: Colors.red),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: canGenerate ? onGenerate : null,
                  child: const Text('重新生成'),
                ),
              ],
            ),
          ),
        );
    }
  }

  Future<void> _openImagePreview({
    required BuildContext context,
    required String path,
  }) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacityCompat(0.92),
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Center(
                      child: buildSceneImage(
                        path,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;

  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacityCompat(0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withOpacityCompat(0.05),
          width: 0.5,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color.withOpacityCompat(0.6),
        ),
      ),
    );
  }
}
