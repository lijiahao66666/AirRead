import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/manga/manga_panel.dart' as manga;
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/local_llm/model_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../models/ai_chat_model_choice.dart';
import '../providers/ai_model_provider.dart';
import '../providers/manga_provider.dart';
import '../providers/translation_provider.dart';
import 'scene_image.dart';
import 'points_wallet.dart';
import 'ai_inference_top_row.dart';

class MangaStoryboardPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String bookId;
  final Map<int, String> chapterTextCache;
  final int currentChapterIndex;
  final void Function(String, {bool isError})? onShowTopMessage;

  const MangaStoryboardPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.bookId,
    required this.chapterTextCache,
    required this.currentChapterIndex,
    this.onShowTopMessage,
  });

  @override
  State<MangaStoryboardPanel> createState() => _MangaStoryboardPanelState();
}

class _MangaStoryboardPanelState extends State<MangaStoryboardPanel> {
  static const int _imageCostPoints = 20000;
  static const String _kMangaModelChoice = 'manga_model_choice_v1';
  static const String _kMangaThinkingEnabled = 'manga_thinking_enabled_v1';

  static const Map<String, String> _stylePrompts = {
    '国风': '国风漫画分镜，细腻画风，电影感光影，无文字无水印',
    '水墨': '水墨国风漫画分镜，留白，柔和光影，无文字无水印',
    '厚涂': '厚涂漫画分镜，电影感光影，高细节，无文字无水印',
    '日漫': '日系漫画分镜，线条清晰，柔和光影，无文字无水印',
    '写实': '写实风格漫画分镜，电影级光影，高细节，无文字无水印',
  };

  static const Map<String, String> _ratioToResolution = {
    '1:1': '1024:1024',
    '3:4': '768:1024',
    '4:3': '1024:768',
    '9:16': '768:1280',
    '16:9': '1280:768',
  };

  String _styleKey = '国风';
  String _ratioKey = '1:1';
  AiChatModelChoice _modelChoice = AiChatModelChoice.onlineHunyuan;
  bool _thinkingEnabled = true;
  final Set<String> _pendingGeneratePanelIds = {};

  String _toastText = '';
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_kMangaModelChoice) ?? '').trim();
    final choice = AiChatModelChoice.values.cast<AiChatModelChoice?>().firstWhere(
          (e) => e?.name == raw,
          orElse: () => null,
        );
    final thinking = prefs.getBool(_kMangaThinkingEnabled);
    if (!mounted) return;
    setState(() {
      _modelChoice = choice ?? AiChatModelChoice.onlineHunyuan;
      _thinkingEnabled = thinking ?? true;
    });
  }

  Future<void> _setModelChoice(AiChatModelChoice value) async {
    if (_modelChoice == value) return;
    setState(() => _modelChoice = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMangaModelChoice, value.name);
  }

  Future<void> _setThinkingEnabled(bool value) async {
    if (_thinkingEnabled == value) return;
    setState(() => _thinkingEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMangaThinkingEnabled, value);
  }

  void _showToast(String msg, {bool isError = true}) {
    final t = msg.trim();
    if (t.isEmpty) return;
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toastText = t);
    widget.onShowTopMessage?.call(t, isError: isError);
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      setState(() => _toastText = '');
    });
  }

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

  String _chapterId() => '${widget.bookId}::${widget.currentChapterIndex}';

  String _chapterText() {
    return (widget.chapterTextCache[widget.currentChapterIndex] ?? '').trim();
  }

  String _chapterTitleFallback() => '正文';

  Future<bool> _confirmReanalyze() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('重新分析当前章节？'),
          content: const Text('将覆盖当前分镜与已生成图片。'),
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
    return ok ?? false;
  }

  Future<void> _analyze({
    required MangaProvider provider,
    required AiModelProvider aiModel,
    required TranslationProvider tp,
    required bool force,
  }) async {
    final content = _chapterText();
    if (content.isEmpty) {
      _showToast('章节内容为空');
      return;
    }
    final usingPersonal = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;
    final onlineEntitled = aiModel.pointsBalance > 0 || usingPersonal;

    Future<String> Function(String prompt)? generateText;
    bool? enableThinkingForOnline;
    final modelKey = _modelChoice.name;
    final localModelId = switch (_modelChoice) {
      AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
      AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
      _ => ModelManager.hunyuan_1_8b,
    };

    if (_modelChoice.isLocal) {
      final installed = aiModel.installStatusFor(localModelId) == ModelInstallStatus.installed;
      if (!installed) {
        _showToast('本地模型未下载，请先在 AI 设置中下载');
        return;
      }
      generateText = (prompt) => aiModel.generate(
            prompt: _thinkingEnabled ? prompt : '/no_think\n$prompt',
            maxTokens: 1536,
            modelId: localModelId,
          );
    } else {
      if (!onlineEntitled) {
        _showToast('在线大模型需要购买积分后使用');
        return;
      }
      enableThinkingForOnline = _thinkingEnabled ? null : false;
    }

    final chapterId = _chapterId();
    final stylePrefix = _stylePrompts[_styleKey] ?? _stylePrompts['国风']!;
    final resolution =
        _ratioToResolution[_ratioKey] ?? _ratioToResolution['1:1']!;

    try {
      await provider.analyzeChapter(
        chapterId: chapterId,
        chapterTitle: _chapterTitleFallback(),
        content: content,
        modelKey: modelKey,
        thinkingEnabled: _thinkingEnabled,
        panelCount: aiModel.mangaPanelCount,
        autoRenderCount: aiModel.mangaAutoRenderCount,
        styleKey: _styleKey,
        ratioKey: _ratioKey,
        stylePrefix: stylePrefix,
        resolution: resolution,
        generateText: generateText,
        enableThinkingForOnline: enableThinkingForOnline,
        force: force,
      );
    } catch (e) {
      _showToast(e.toString());
    }
  }

  Future<void> _generateWithPoints({
    required MangaProvider provider,
    required AiModelProvider aiModel,
    required TranslationProvider tp,
    required String cacheKey,
    required manga.MangaPanel panel,
  }) async {
    if (panel.status == manga.MangaPanelStatus.generating) return;
    if (_pendingGeneratePanelIds.contains(panel.id)) return;
    _pendingGeneratePanelIds.add(panel.id);
    bool deducted = false;

    final usingPersonal = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;
    if (!usingPersonal) {
      if (aiModel.pointsBalance < _imageCostPoints) {
        _pendingGeneratePanelIds.remove(panel.id);
        _showToast('积分不足，无法出图');
        return;
      }
      await aiModel.addPoints(-_imageCostPoints);
      deducted = true;
    }

    Future<String> Function(String prompt)? generateText;
    bool? enableThinkingForOnline;
    final localModelId = switch (_modelChoice) {
      AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
      AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
      _ => ModelManager.hunyuan_1_8b,
    };
    if (_modelChoice.isLocal) {
      final installed =
          aiModel.installStatusFor(localModelId) == ModelInstallStatus.installed;
      if (!installed) {
        if (deducted) await aiModel.addPoints(_imageCostPoints);
        _pendingGeneratePanelIds.remove(panel.id);
        _showToast('本地模型未下载，无法扩写提示词');
        return;
      }
      generateText = (prompt) => aiModel.generate(
            prompt: _thinkingEnabled ? prompt : '/no_think\n$prompt',
            maxTokens: 1536,
            modelId: localModelId,
          );
    } else {
      enableThinkingForOnline = _thinkingEnabled ? null : false;
    }

    try {
      await provider.generateImage(
        cacheKey: cacheKey,
        panelId: panel.id,
        generateText: generateText,
        enableThinkingForOnline: enableThinkingForOnline,
      );
      if (deducted && panel.status == manga.MangaPanelStatus.failed) {
        await aiModel.addPoints(_imageCostPoints);
      }
    } finally {
      _pendingGeneratePanelIds.remove(panel.id);
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MangaProvider>();
    final aiModel = context.watch<AiModelProvider>();
    final tp = context.watch<TranslationProvider>();

    final cardBg =
        widget.isDark ? Colors.white.withOpacityCompat(0.07) : AppColors.mistWhite;
    final cacheModelKey = _modelChoice.name;
    final cacheKey = provider.buildCacheKey(
      chapterId: _chapterId(),
      modelKey: cacheModelKey,
      thinkingEnabled: _thinkingEnabled,
      panelCount: aiModel.mangaPanelCount,
      autoRenderCount: aiModel.mangaAutoRenderCount,
      styleKey: _styleKey,
      ratioKey: _ratioKey,
    );
    final panels = provider.getPanels(cacheKey);
    final analyzing = provider.isAnalyzing(cacheKey);

    final usingPersonal =
        tp.usingPersonalTencentKeys && getEmbeddedPublicHunyuanCredentials().isUsable;
    final canGenerate = usingPersonal || aiModel.pointsBalance >= _imageCostPoints;
    final canAnalyze = _modelChoice.isOnline
        ? (aiModel.pointsBalance > 0 || usingPersonal)
        : (aiModel.installStatusFor(switch (_modelChoice) {
              AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
              AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
              _ => ModelManager.hunyuan_1_8b,
            }) ==
            ModelInstallStatus.installed);
    final aspect = _ratioKeyToAspect(_ratioKey);

    return SingleChildScrollView(
      key: const PageStorageKey('ai_hud_manga_scroll'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: widget.textColor.withOpacityCompat(0.08),
                width: AppTokens.stroke,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AiInferenceTopRow(
                  isDark: widget.isDark,
                  textColor: widget.textColor,
                  modelChoice: _modelChoice,
                  local05Installed:
                      aiModel.installStatusFor(ModelManager.hunyuan_0_5b) ==
                          ModelInstallStatus.installed,
                  local18Installed:
                      aiModel.installStatusFor(ModelManager.hunyuan_1_8b) ==
                          ModelInstallStatus.installed,
                  onModelChoiceChanged: (choice) async {
                    final prev = _modelChoice;
                    if (prev == choice) return;
                    if (choice.isLocal) {
                      final localModelId =
                          choice == AiChatModelChoice.localHunyuan05b
                              ? ModelManager.hunyuan_0_5b
                              : ModelManager.hunyuan_1_8b;
                      final installed = aiModel.installStatusFor(localModelId) ==
                          ModelInstallStatus.installed;
                      if (!installed) {
                        _showToast('本地模型未下载，请先在 AI 设置中下载');
                        return;
                      }
                      await _setModelChoice(choice);
                      try {
                        await aiModel.ensureLocalModelReady(localModelId);
                      } catch (e) {
                        _showToast(e.toString());
                      }
                      return;
                    }
                    await _setModelChoice(choice);
                  },
                  thinkingEnabled: _thinkingEnabled,
                  onThinkingChanged: _setThinkingEnabled,
                ),
                const SizedBox(height: 12),
                PointsWallet(
                  isDark: widget.isDark,
                  textColor: widget.textColor,
                  cardBg: widget.isDark
                      ? Colors.white.withOpacityCompat(0.06)
                      : Colors.white,
                  hintText: '选择的模型仅影响分析；生图固定使用在线生图（2万积分/张）',
                ),
                const SizedBox(height: 12),
                _settingsArea(
                  cardBg: widget.isDark
                      ? Colors.white.withOpacityCompat(0.06)
                      : Colors.white,
                  aiModel: aiModel,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: analyzing || !canAnalyze
                        ? null
                        : () async {
                            final hasPanels = panels.isNotEmpty;
                            if (hasPanels) {
                              final ok = await _confirmReanalyze();
                              if (!ok) return;
                              provider.clearChapter(_chapterId());
                              if (!mounted) return;
                            }
                            await _analyze(
                              provider: provider,
                              aiModel: aiModel,
                              tp: tp,
                              force: hasPanels,
                            );
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.techBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      disabledBackgroundColor:
                          AppColors.techBlue.withOpacityCompat(0.45),
                      disabledForegroundColor:
                          Colors.white.withOpacityCompat(0.75),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (analyzing)
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white.withOpacityCompat(0.92),
                            ),
                          )
                        else
                          const Icon(Icons.auto_awesome_rounded, size: 18),
                        const SizedBox(width: 8),
                        Text(analyzing ? '分析中...' : '分析当前章节'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (panels.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
              child: Text(
                '点击“分析当前章节”生成分镜网格，点选任意格可继续出图。',
                style: TextStyle(
                  fontSize: 13,
                  color: widget.textColor.withOpacityCompat(0.7),
                ),
              ),
            )
          else
            _grid(
              panels: panels,
              cardBg: cardBg,
              canGenerate: canGenerate,
              aspect: aspect,
              cacheKey: cacheKey,
              onGenerate: (panel) => _generateWithPoints(
                provider: provider,
                aiModel: aiModel,
                tp: tp,
                cacheKey: cacheKey,
                panel: panel,
              ),
            ),
          if (_toastText.trim().isNotEmpty) const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _settingsArea({
    required Color cardBg,
    required AiModelProvider aiModel,
  }) {
    final border = Border.all(
      color: widget.textColor.withOpacityCompat(0.08),
      width: AppTokens.stroke,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: border,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Builder(
            builder: (context) {
              const allowed = [6, 8, 9];
              final idx = allowed.indexOf(aiModel.mangaPanelCount);
              final safeIdx = idx < 0 ? 1 : idx;
              final value = allowed[safeIdx];
              return _stepperRow(
                title: '分镜格数',
                subtitle: '格数越多更连贯，但更慢。',
                valueText: '$value',
                canDecrement: safeIdx > 0,
                canIncrement: safeIdx < allowed.length - 1,
                onDecrement: () =>
                    aiModel.setMangaPanelCount(allowed[safeIdx - 1]),
                onIncrement: () =>
                    aiModel.setMangaPanelCount(allowed[safeIdx + 1]),
              );
            },
          ),
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              const allowed = [0, 1, 2];
              final idx = allowed.indexOf(aiModel.mangaAutoRenderCount);
              final safeIdx = idx < 0 ? 0 : idx;
              final value = allowed[safeIdx];
              return _stepperRow(
                title: '自动出图数',
                subtitle: '0 仅脚本；>0 自动出图扣积分。',
                valueText: '$value',
                canDecrement: safeIdx > 0,
                canIncrement: safeIdx < allowed.length - 1,
                onDecrement: () =>
                    aiModel.setMangaAutoRenderCount(allowed[safeIdx - 1]),
                onIncrement: () =>
                    aiModel.setMangaAutoRenderCount(allowed[safeIdx + 1]),
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _compactDropdown<String>(
                  value: _styleKey,
                  items: _stylePrompts.keys.toList(),
                  labelOf: (v) => '风格：$v',
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _styleKey = v);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _compactDropdown<String>(
                  value: _ratioKey,
                  items: _ratioToResolution.keys.toList(),
                  labelOf: (v) => '比例：$v',
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _ratioKey = v);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepperRow({
    required String title,
    required String subtitle,
    required String valueText,
    required bool canDecrement,
    required bool canIncrement,
    required VoidCallback onDecrement,
    required VoidCallback onIncrement,
  }) {
    final border = Border.all(
      color: widget.textColor.withOpacityCompat(0.08),
      width: AppTokens.stroke,
    );
    final controlBg = widget.isDark
        ? Colors.white.withOpacityCompat(0.04)
        : AppColors.mistWhite;
    final iconColor = widget.textColor.withOpacityCompat(0.7);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: widget.textColor.withOpacityCompat(0.88),
                ),
              ),
            ),
            Container(
              height: 34,
              decoration: BoxDecoration(
                color: controlBg,
                borderRadius: BorderRadius.circular(12),
                border: border,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: canDecrement ? onDecrement : null,
                    icon: const Icon(Icons.remove_rounded),
                    color: iconColor,
                    iconSize: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    constraints: const BoxConstraints(minWidth: 34),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(
                      valueText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: widget.textColor.withOpacityCompat(0.9),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: canIncrement ? onIncrement : null,
                    icon: const Icon(Icons.add_rounded),
                    color: iconColor,
                    iconSize: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    constraints: const BoxConstraints(minWidth: 34),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: widget.textColor.withOpacityCompat(0.6),
            height: 1.25,
          ),
        ),
      ],
    );
  }

  Widget _compactDropdown<T>({
    required T value,
    required List<T> items,
    required String Function(T) labelOf,
    required ValueChanged<T?> onChanged,
  }) {
    final bg = widget.isDark ? Colors.white.withOpacityCompat(0.06) : Colors.white;
    final dropdownBg = widget.isDark
        ? Colors.white.withOpacityCompat(0.04)
        : AppColors.mistWhite;
    final border = Border.all(
      color: widget.textColor.withOpacityCompat(0.08),
      width: AppTokens.stroke,
    );

    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: dropdownBg,
        borderRadius: BorderRadius.circular(12),
        border: border,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          icon: Icon(Icons.keyboard_arrow_down_rounded,
              color: widget.textColor.withOpacityCompat(0.7)),
          dropdownColor: bg,
          style: TextStyle(
            color: widget.textColor.withOpacityCompat(0.9),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          items: items
              .map(
                (e) => DropdownMenuItem<T>(
                  value: e,
                  child: Text(labelOf(e)),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _PanelGrid extends StatelessWidget {
  final List<manga.MangaPanel> panels;
  final Color cardBg;
  final bool canGenerate;
  final double aspect;
  final String cacheKey;
  final Future<void> Function(manga.MangaPanel panel) onGenerate;

  const _PanelGrid({
    required this.panels,
    required this.cardBg,
    required this.canGenerate,
    required this.aspect,
    required this.cacheKey,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: panels.map((p) {
        return _PanelCard(
          key: ValueKey(p.id),
          panel: p,
          cardBg: cardBg,
          canGenerate: canGenerate,
          aspect: aspect,
          onGenerate: () => onGenerate(p),
        );
      }).toList(),
    );
  }
}

extension on _MangaStoryboardPanelState {
  Widget _grid({
    required List<manga.MangaPanel> panels,
    required Color cardBg,
    required bool canGenerate,
    required double aspect,
    required String cacheKey,
    required Future<void> Function(manga.MangaPanel panel) onGenerate,
  }) {
    return _PanelGrid(
      panels: panels,
      cardBg: cardBg,
      canGenerate: canGenerate,
      aspect: aspect,
      cacheKey: cacheKey,
      onGenerate: onGenerate,
    );
  }
}

class _PanelCard extends StatelessWidget {
  final manga.MangaPanel panel;
  final Color cardBg;
  final bool canGenerate;
  final double aspect;
  final VoidCallback onGenerate;

  const _PanelCard({
    super.key,
    required this.panel,
    required this.cardBg,
    required this.canGenerate,
    required this.aspect,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textColor = cs.onSurface;
    final border = Border.all(
      color: textColor.withOpacityCompat(0.08),
      width: AppTokens.stroke,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: border,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    panel.title.trim().isEmpty ? '分镜' : panel.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: textColor.withOpacityCompat(0.92),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _tag(panel.narrativeRole, AppColors.techBlue),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: canGenerate &&
                          panel.status != manga.MangaPanelStatus.generating
                      ? onGenerate
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.techBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    disabledBackgroundColor:
                        AppColors.techBlue.withOpacityCompat(0.45),
                    disabledForegroundColor:
                        Colors.white.withOpacityCompat(0.75),
                  ),
                  child: Text(
                    switch (panel.status) {
                      manga.MangaPanelStatus.completed => '再出一张',
                      manga.MangaPanelStatus.generating => '生成中',
                      _ => '出图',
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: aspect,
                child: _media(panel: panel, textColor: textColor),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '镜头：${panel.shot}；${panel.camera}',
              style: TextStyle(
                fontSize: 12,
                color: textColor.withOpacityCompat(0.72),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '光影：${panel.lighting}；氛围：${panel.mood}',
              style: TextStyle(
                fontSize: 12,
                color: textColor.withOpacityCompat(0.72),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '构图：${panel.composition}',
              style: TextStyle(
                fontSize: 12,
                color: textColor.withOpacityCompat(0.72),
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if ((panel.caption ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                panel.caption!,
                style: TextStyle(
                  fontSize: 12,
                  color: textColor.withOpacityCompat(0.62),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (panel.status == manga.MangaPanelStatus.failed &&
                (panel.errorMsg ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                panel.errorMsg!,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.red,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _media({required manga.MangaPanel panel, required Color textColor}) {
    switch (panel.status) {
      case manga.MangaPanelStatus.generating:
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
      case manga.MangaPanelStatus.completed:
        final path = panel.localImagePath;
        if (path != null && path.trim().isNotEmpty) {
          return buildSceneImage(path, fit: BoxFit.cover);
        }
        return const Center(child: Icon(Icons.broken_image));
      case manga.MangaPanelStatus.failed:
        return Container(
          color: Colors.red.withOpacityCompat(0.05),
          child: const Center(
            child: Icon(Icons.error_outline, color: Colors.red),
          ),
        );
      default:
        return Container(
          color: textColor.withOpacityCompat(0.03),
          child: Center(
            child: Icon(
              Icons.image_outlined,
              size: 44,
              color: textColor.withOpacityCompat(0.12),
            ),
          ),
        );
    }
  }

  Widget _tag(String text, Color color) {
    final t = text.trim();
    if (t.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacityCompat(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withOpacityCompat(0.12),
          width: AppTokens.stroke,
        ),
      ),
      child: Text(
        t,
        style: TextStyle(
          fontSize: 11,
          color: color.withOpacityCompat(0.9),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
