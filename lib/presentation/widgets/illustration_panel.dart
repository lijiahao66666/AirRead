import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ai/illustration/illustration_item.dart' as ill;
import '../../ai/tencentcloud/tencent_cloud_exception.dart';
import '../../ai/config/auth_service.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/local_llm/model_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../models/ai_chat_model_choice.dart';
import '../providers/ai_model_provider.dart';
import '../providers/illustration_provider.dart';
import '../providers/translation_provider.dart';
import 'scene_image.dart';
import 'points_wallet.dart';
import 'ai_inference_top_row.dart';

class IllustrationPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String bookId;
  final Map<int, String> chapterTextCache;
  final int currentChapterIndex;
  final String? chapterIdSuffix;
  final ValueChanged<int>? onChapterIllustrationsGenerated;
  final void Function(String, {bool isError})? onShowTopMessage;

  const IllustrationPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.bookId,
    required this.chapterTextCache,
    required this.currentChapterIndex,
    this.chapterIdSuffix,
    this.onChapterIllustrationsGenerated,
    this.onShowTopMessage,
  });

  @override
  State<IllustrationPanel> createState() => _IllustrationPanelState();
}

class _IllustrationPanelState extends State<IllustrationPanel> {
  static const int _imageCostPoints = 20000;
  static const String _kIllustrationModelChoice =
      'illustration_model_choice_v1';
  static const String _kIllustrationThinkingEnabled =
      'illustration_thinking_enabled_v1';

  String _styleKey = '国风';
  String _ratioKey = '1:1';
  AiChatModelChoice _modelChoice = AiChatModelChoice.onlineHunyuan;
  bool _thinkingEnabled = true;
  final Set<String> _pendingGenerateIds = {};

  String _toastText = '';
  bool _toastIsError = true;
  Timer? _toastTimer;

  String _panelPopupText = '';
  Timer? _panelPopupTimer;

  static const Map<String, String> _stylePrompts = {
    '国风': '国风插画，细腻画风，电影感光影，无文字无水印',
    '水墨': '水墨国风插画，留白，柔和光影，无文字无水印',
    '厚涂': '厚涂插画，电影感光影，高细节，无文字无水印',
    '日漫': '日系插画，线条清晰，柔和光影，无文字无水印',
    '写实': '写实风格插画，电影级光影，高细节，无文字无水印',
  };

  static const Map<String, String> _ratioToResolution = {
    '1:1': '1024:1024',
    '3:4': '768:1024',
    '4:3': '1024:768',
    '9:16': '768:1280',
    '16:9': '1280:768',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    String raw = (prefs.getString(_kIllustrationModelChoice) ?? '').trim();
    if (raw.isEmpty) {
      final legacyA =
          (prefs.getString('storybook_model_choice_v1') ?? '').trim();
      final legacyB = (prefs.getString('manga_model_choice_v1') ?? '').trim();
      final legacy = legacyA.isNotEmpty ? legacyA : legacyB;
      if (legacy.isNotEmpty) {
        raw = legacy;
        await prefs.setString(_kIllustrationModelChoice, legacy);
        await prefs.remove('storybook_model_choice_v1');
        await prefs.remove('manga_model_choice_v1');
      }
    }

    final choice =
        AiChatModelChoice.values.cast<AiChatModelChoice?>().firstWhere(
              (e) => e?.name == raw,
              orElse: () => null,
            );

    bool? thinking = prefs.getBool(_kIllustrationThinkingEnabled);
    if (thinking == null) {
      final legacyA = prefs.getBool('storybook_thinking_enabled_v1');
      final legacyB = prefs.getBool('manga_thinking_enabled_v1');
      final legacy = legacyA ?? legacyB;
      if (legacy != null) {
        thinking = legacy;
        await prefs.setBool(_kIllustrationThinkingEnabled, legacy);
        await prefs.remove('storybook_thinking_enabled_v1');
        await prefs.remove('manga_thinking_enabled_v1');
      }
    }

    final resolvedChoice = (!kIsWeb && Platform.isIOS &&
            (choice == AiChatModelChoice.localHunyuan18b ||
                choice == AiChatModelChoice.localMiniCpm05b))
        ? AiChatModelChoice.localHunyuan05b
        : choice;

    if (!mounted) return;
    final effectiveChoice = resolvedChoice ?? AiChatModelChoice.onlineHunyuan;
    setState(() {
      _modelChoice = effectiveChoice;
      _thinkingEnabled = thinking ?? true;
    });

    // 面板打开时，若在线模型且积分不足，提示登录
    if (effectiveChoice.isOnline) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final aiModel = context.read<AiModelProvider>();
        final tp = context.read<TranslationProvider>();
        final usingPersonal = tp.usingPersonalTencentKeys &&
            getEmbeddedPublicHunyuanCredentials().isUsable;
        if (!usingPersonal && aiModel.pointsBalance <= 0) {
          _showToast('积分不足，无法使用在线插画');
        }
      });
    }
  }

  Future<void> _setModelChoice(AiChatModelChoice value) async {
    if (_modelChoice == value) return;
    final aiModel = context.read<AiModelProvider>();
    final prevChoice = _modelChoice;
    if (value.isLocal) {
      final localModelId = switch (value) {
        AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
        AiChatModelChoice.localMiniCpm05b => ModelManager.minicpm4_0_5b,
        AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
        _ => ModelManager.hunyuan_1_8b,
      };
      if (aiModel.loaded && aiModel.activeLocalModelId != localModelId) {
        await aiModel.unloadLocalModel(reason: 'illustration_switch_local');
      }
    } else if (prevChoice.isLocal && aiModel.loaded) {
      await aiModel.unloadLocalModel(reason: 'illustration_switch_online');
    }
    setState(() => _modelChoice = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIllustrationModelChoice, value.name);
  }

  Future<void> _setThinkingEnabled(bool value) async {
    if (_thinkingEnabled == value) return;
    setState(() => _thinkingEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kIllustrationThinkingEnabled, value);
  }

  void _showToast(String msg, {bool isError = true}) {
    final t = msg.trim();
    if (t.isEmpty) return;
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _toastText = t;
      _toastIsError = isError;
    });
    widget.onShowTopMessage?.call(t, isError: isError);
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      setState(() => _toastText = '');
    });
  }

  void _showPanelPopup(String msg) {
    final t = msg.trim();
    if (t.isEmpty) return;
    if (!mounted) return;
    _panelPopupTimer?.cancel();
    setState(() => _panelPopupText = t);
    _panelPopupTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() => _panelPopupText = '');
    });
  }

  String _friendlyErrorMessage(Object e) {
    if (e is TimeoutException) {
      return '生成提示词超时，请检查网络后重试';
    }
    if (e is TencentCloudException) {
      if (e.code == 'PointsInsufficient' ||
          e.message.contains('PointsInsufficient') ||
          e.message.contains('HTTP 402') ||
          e.message.contains('积分不足')) {
        return '积分不足';
      }
      if (e.code == 'NoProxyUrl') {
        return '在线提示词服务未配置，请在 AI 设置中填写个人密钥，或配置服务端地址';
      }
      if (e.code == 'MissingCredentials') {
        return '已开启个人密钥，但未填写 SecretId/SecretKey';
      }
      if (e.code == 'HttpError') {
        final m = e.message;
        if (m.contains('HTTP 402') ||
            m.contains('PointsInsufficient') ||
            m.contains('积分不足')) {
          return '积分不足';
        }
        if (m.contains('HTTP 401') || m.contains('HTTP 403')) {
          return '鉴权失败，请检查积分状态或个人密钥是否正确';
        }
        if (m.contains('HTTP 429')) {
          return '请求过于频繁，请稍后重试';
        }
        return '在线服务异常，请稍后重试';
      }
      return '${e.code}：${e.message}';
    }
    final s = e.toString();
    if (s.contains('PointsInsufficient') ||
        s.contains('HTTP 402') ||
        s.contains('积分不足')) {
      return '积分不足';
    }
    if (s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('XMLHttpRequest error')) {
      return '网络连接失败，请检查网络后重试';
    }
    return e.toString();
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

  String _chapterId() {
    final suffix = (widget.chapterIdSuffix ?? '').trim();
    if (suffix.isEmpty)
      return '${widget.bookId}::${widget.currentChapterIndex}';
    return '${widget.bookId}::${widget.currentChapterIndex}::$suffix';
  }

  String _chapterText() {
    return (widget.chapterTextCache[widget.currentChapterIndex] ?? '').trim();
  }

  Future<bool> _confirmRegenerate() async {
    final isSelectionMode =
        (widget.chapterIdSuffix ?? '').trim().startsWith('sel_');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            isSelectionMode ? '重新生成选中文本插画提示词？' : '重新生成插画提示词？',
            style: TextStyle(
              fontSize: 16,
              color: widget.textColor,
            ),
          ),
          content: const Text('将覆盖当前提示词与已生成图片。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新生成'),
            ),
          ],
        );
      },
    );
    return ok ?? false;
  }

  Future<void> _generateScript({
    required IllustrationProvider provider,
    required AiModelProvider aiModel,
    required TranslationProvider tp,
    required bool force,
  }) async {
    final content = _chapterText();
    if (content.isEmpty) {
      _showToast('章节内容为空');
      return;
    }
    final isSelectionMode =
        (widget.chapterIdSuffix ?? '').trim().startsWith('sel_');
    final usingPersonal = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;
    final onlineEntitled = aiModel.pointsBalance > 0 || usingPersonal;

    Future<String> Function(String prompt)? generateText;
    bool thinkingForOnline = false;
    final modelKey = _modelChoice.name;
    final localModelId = switch (_modelChoice) {
      AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
      AiChatModelChoice.localMiniCpm05b => ModelManager.minicpm4_0_5b,
      AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
      _ => ModelManager.hunyuan_1_8b,
    };
    final thinkingSupported = _modelChoice != AiChatModelChoice.localMiniCpm05b;
    final effectiveThinkingEnabled =
        thinkingSupported ? _thinkingEnabled : false;

    if (_modelChoice.isLocal) {
      final installed = aiModel.installStatusFor(localModelId) ==
          ModelInstallStatus.installed;
      if (!installed) {
        _showToast('本地模型未下载，请先在 AI 设置中下载');
        return;
      }
      generateText = (prompt) => aiModel.generate(
            prompt: effectiveThinkingEnabled
                ? prompt
                : (thinkingSupported ? '/no_think\n$prompt' : prompt),
            maxTokens: 1536,
            modelId: localModelId,
          );
    } else {
      if (!onlineEntitled) {
        _showToast('积分不足，无法使用在线插画');
        return;
      }
      thinkingForOnline = _thinkingEnabled;
    }

    final chapterId = _chapterId();
    final stylePrefix = _stylePrompts[_styleKey] ?? _stylePrompts['国风']!;
    final resolution =
        _ratioToResolution[_ratioKey] ?? _ratioToResolution['1:1']!;

    try {
      await provider.generateChapterIllustrations(
        chapterId: chapterId,
        chapterTitle: '第${widget.currentChapterIndex + 1}章',
        content: content,
        modelKey: modelKey,
        thinkingEnabled: effectiveThinkingEnabled,
        count: isSelectionMode ? 1 : aiModel.illustrationCount,
        styleKey: _styleKey,
        ratioKey: _ratioKey,
        stylePrefix: stylePrefix,
        resolution: resolution,
        useLocalModel: _modelChoice.isLocal,
        generateText: generateText,
        thinkingForOnline: thinkingForOnline,
        force: force,
      );
      widget.onChapterIllustrationsGenerated?.call(widget.currentChapterIndex);
    } catch (e) {
      _showToast(_friendlyErrorMessage(e));
    }
  }

  Future<void> _generateImageWithPoints({
    required IllustrationProvider provider,
    required AiModelProvider aiModel,
    required TranslationProvider tp,
    required String cacheKey,
    required ill.IllustrationItem item,
  }) async {
    if (item.status == ill.IllustrationStatus.generating) return;
    if (_pendingGenerateIds.contains(item.id)) return;
    if (provider.isAnyGenerating) {
      _showPanelPopup('正在出图，请等待上一张完成');
      return;
    }
    _pendingGenerateIds.add(item.id);

    try {
      final usingPersonal = tp.usingPersonalTencentKeys &&
          getEmbeddedPublicHunyuanCredentials().isUsable;
      // TODO: SMS配好后取消注释，强制登录
      // if (!usingPersonal && !AuthService.isLoggedIn) {
      //   _showToast('请先登录后使用在线生图');
      //   return;
      // }
      if (!usingPersonal) {
        if (aiModel.pointsBalance < _imageCostPoints) {
          _showToast('积分不足，无法出图');
          return;
        }
      }

      await provider.generateImage(
        cacheKey: cacheKey,
        itemId: item.id,
      );
      if (!usingPersonal &&
          item.status == ill.IllustrationStatus.completed &&
          item.chargedAtMs == null) {
        await aiModel.addPoints(-_imageCostPoints);
        provider.markImageCharged(
          cacheKey: cacheKey,
          itemId: item.id,
          chargedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      _showToast(_friendlyErrorMessage(e));
    } finally {
      _pendingGenerateIds.remove(item.id);
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _panelPopupTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<IllustrationProvider>();
    final aiModel = context.watch<AiModelProvider>();
    final tp = context.watch<TranslationProvider>();

    final isSelectionMode =
        (widget.chapterIdSuffix ?? '').trim().startsWith('sel_');
    final effectiveCount = isSelectionMode ? 1 : aiModel.illustrationCount;

    final cardBg = widget.isDark
        ? Colors.white.withOpacityCompat(0.07)
        : AppColors.mistWhite;
    final thinkingSupported = _modelChoice != AiChatModelChoice.localMiniCpm05b;
    final effectiveThinkingEnabled =
        thinkingSupported ? _thinkingEnabled : false;
    final cacheModelKey = _modelChoice.name;
    final cacheKey = provider.buildCacheKey(
      chapterId: _chapterId(),
      modelKey: cacheModelKey,
      thinkingEnabled: effectiveThinkingEnabled,
      count: effectiveCount,
      styleKey: _styleKey,
      ratioKey: _ratioKey,
    );
    final items = provider.getItems(cacheKey);
    final analyzing = provider.isAnalyzing(cacheKey);

    final usingPersonal = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;
    final canGenerate =
        usingPersonal || aiModel.pointsBalance >= _imageCostPoints;
    final canGenerateScript = _modelChoice.isOnline
        ? (aiModel.pointsBalance > 0 || usingPersonal)
        : (aiModel.installStatusFor(switch (_modelChoice) {
              AiChatModelChoice.localHunyuan05b => ModelManager.hunyuan_0_5b,
              AiChatModelChoice.localMiniCpm05b => ModelManager.minicpm4_0_5b,
              AiChatModelChoice.localHunyuan18b => ModelManager.hunyuan_1_8b,
              _ => ModelManager.hunyuan_1_8b,
            }) ==
            ModelInstallStatus.installed);
    final aspect = _ratioKeyToAspect(_ratioKey);

    return Stack(
      children: [
        SingleChildScrollView(
          key: const PageStorageKey('ai_hud_illustration_scroll'),
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
                      localMiniInstalled: aiModel.installStatusFor(
                            ModelManager.minicpm4_0_5b,
                          ) ==
                          ModelInstallStatus.installed,
                      local18Installed:
                          aiModel.installStatusFor(ModelManager.hunyuan_1_8b) ==
                              ModelInstallStatus.installed,
                      onModelChoiceChanged: (choice) async {
                        final prev = _modelChoice;
                        if (prev == choice) return;
                        if (choice.isLocal) {
                          final localModelId = switch (choice) {
                            AiChatModelChoice.localHunyuan05b =>
                              ModelManager.hunyuan_0_5b,
                            AiChatModelChoice.localMiniCpm05b =>
                              ModelManager.minicpm4_0_5b,
                            AiChatModelChoice.localHunyuan18b =>
                              ModelManager.hunyuan_1_8b,
                            _ => ModelManager.hunyuan_1_8b,
                          };
                          final installed =
                              aiModel.installStatusFor(localModelId) ==
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
                      thinkingEnabled: effectiveThinkingEnabled,
                      onThinkingChanged: _setThinkingEnabled,
                      thinkingSupported: thinkingSupported,
                    ),
                    const SizedBox(height: 12),
                    PointsWallet(
                      isDark: widget.isDark,
                      textColor: widget.textColor,
                      cardBg: widget.isDark
                          ? Colors.white.withOpacityCompat(0.06)
                          : Colors.white,
                      hintText: '选择的模型用于生成插画提示词，在线模型需要积分或个人密钥；本地模型免费，但效果不如在线；生图固定使用在线生图（2万积分/张）',
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
                        onPressed: analyzing || !canGenerateScript
                            ? null
                            : () async {
                                final hasItems = items.isNotEmpty;
                                if (hasItems) {
                                  final ok = await _confirmRegenerate();
                                  if (!ok) return;
                                  provider.clearChapter(_chapterId());
                                  if (!mounted) return;
                                }
                                await _generateScript(
                                  provider: provider,
                                  aiModel: aiModel,
                                  tp: tp,
                                  force: hasItems,
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
                            Text(
                              analyzing
                                  ? '提示词生成中...'
                                  : (isSelectionMode
                                      ? '生成选中文本插画提示词'
                                      : '生成章节插画提示词'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
                  child: Text(
                    isSelectionMode
                        ? '点击“生成选中文本插画提示词”生成画面描述，然后点选卡片出图。'
                        : '点击“生成插画提示词”提取画面场景，然后点选卡片出图。',
                    style: TextStyle(
                      fontSize: 13,
                      color: widget.textColor.withOpacityCompat(0.7),
                    ),
                  ),
                )
              else
                _IllustrationList(
                  items: items,
                  cardBg: cardBg,
                  canGenerate: canGenerate,
                  aspect: aspect,
                  onGenerate: (item) => _generateImageWithPoints(
                    provider: provider,
                    aiModel: aiModel,
                    tp: tp,
                    cacheKey: cacheKey,
                    item: item,
                  ),
                  onUpdatePrompt: (item, prompt) async {
                    provider.updatePrompt(
                      cacheKey: cacheKey,
                      itemId: item.id,
                      prompt: prompt,
                    );
                  },
                ),
              if (_toastText.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: widget.isDark
                          ? Colors.white.withOpacityCompat(0.06)
                          : Colors.black.withOpacityCompat(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: widget.textColor.withOpacityCompat(0.08),
                        width: AppTokens.stroke,
                      ),
                    ),
                    child: Text(
                      _toastText,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: _toastIsError
                            ? Colors.red
                                .withOpacityCompat(widget.isDark ? 0.9 : 0.8)
                            : widget.textColor.withOpacityCompat(0.78),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_panelPopupText.trim().isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: AnimatedOpacity(
                  opacity: _panelPopupText.trim().isNotEmpty ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.7,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacityCompat(0.72),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _panelPopupText,
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
            ),
          ),
      ],
    );
  }

  Widget _settingsArea({
    required Color cardBg,
    required AiModelProvider aiModel,
  }) {
    final isSelectionMode =
        (widget.chapterIdSuffix ?? '').trim().startsWith('sel_');
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
          if (!isSelectionMode) ...[
            Builder(
              builder: (context) {
                const allowed = [0, 4, 8, 12];
                final idx = allowed.indexOf(aiModel.illustrationCount);
                final safeIdx = idx < 0 ? 0 : idx;
                final value = allowed[safeIdx];
                final valueStr = value == 0 ? '自动' : '$value张';
                return _stepperRow(
                  title: '插画数量',
                  subtitle: '自动推荐或固定数量',
                  valueText: valueStr,
                  canDecrement: safeIdx > 0,
                  canIncrement: safeIdx < allowed.length - 1,
                  onDecrement: () =>
                      aiModel.setIllustrationCount(allowed[safeIdx - 1]),
                  onIncrement: () =>
                      aiModel.setIllustrationCount(allowed[safeIdx + 1]),
                );
              },
            ),
            const SizedBox(height: 12),
          ],
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
                    width: 50,
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
    final bg =
        widget.isDark ? Colors.white.withOpacityCompat(0.06) : Colors.white;
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
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: widget.textColor.withOpacityCompat(0.7),
          ),
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

class _IllustrationList extends StatelessWidget {
  final List<ill.IllustrationItem> items;
  final Color cardBg;
  final bool canGenerate;
  final double aspect;
  final Future<void> Function(ill.IllustrationItem item) onGenerate;
  final Future<void> Function(ill.IllustrationItem item, String prompt)
      onUpdatePrompt;

  const _IllustrationList({
    required this.items,
    required this.cardBg,
    required this.canGenerate,
    required this.aspect,
    required this.onGenerate,
    required this.onUpdatePrompt,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: items.map((p) {
        return _IllustrationCard(
          key: ValueKey(p.id),
          item: p,
          cardBg: cardBg,
          canGenerate: canGenerate,
          aspect: aspect,
          onGenerate: () => onGenerate(p),
          onUpdatePrompt: (prompt) => onUpdatePrompt(p, prompt),
        );
      }).toList(),
    );
  }
}

class _IllustrationCard extends StatelessWidget {
  final ill.IllustrationItem item;
  final Color cardBg;
  final bool canGenerate;
  final double aspect;
  final Future<void> Function() onGenerate;
  final Future<void> Function(String prompt) onUpdatePrompt;

  const _IllustrationCard({
    super.key,
    required this.item,
    required this.cardBg,
    required this.canGenerate,
    required this.aspect,
    required this.onGenerate,
    required this.onUpdatePrompt,
  });

  Future<void> _editPrompt(BuildContext context, String initial) async {
    final controller = TextEditingController(text: initial);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: '输入插画提示词（用于文生图）',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (saved == null) return;
    final v = saved.trim();
    if (v.isEmpty) return;
    await onUpdatePrompt(v);
  }

  Future<void> _openImagePreview(BuildContext context, String path) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacityCompat(0.7),
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: Center(
                      child: buildSceneImage(path, fit: BoxFit.contain),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    tooltip: '关闭',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textColor = cs.onSurface;
    final border = Border.all(
      color: textColor.withOpacityCompat(0.08),
      width: AppTokens.stroke,
    );

    final isCompleted = item.status == ill.IllustrationStatus.completed;
    final isGenerating = item.status == ill.IllustrationStatus.generating;
    final promptText = (item.prompt ?? '').trim();
    final imagePath = (item.localImagePath ?? '').trim();
    final canTapPreview = isCompleted && imagePath.isNotEmpty;
    final canPressGenerate = !isGenerating && canGenerate;

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
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: aspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isCompleted)
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: canTapPreview
                              ? () => _openImagePreview(context, imagePath)
                              : null,
                          child: _media(item: item, textColor: textColor),
                        ),
                      )
                    else
                      Material(
                        color: textColor.withOpacityCompat(0.03),
                        child: Center(
                          child: isGenerating
                              ? const _BrushLoading()
                              : Icon(
                                  Icons.image_outlined,
                                  size: 30,
                                  color: textColor.withOpacityCompat(0.48),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _PromptWithEditIcon(
                    text: promptText.isEmpty ? '...' : promptText,
                    textColor: textColor,
                    maxLines: 4,
                    onEdit: () => _editPrompt(context, promptText),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: canPressGenerate
                      ? () async {
                          await onGenerate();
                        }
                      : null,
                  style: ButtonStyle(
                    foregroundColor:
                        MaterialStateProperty.resolveWith((states) {
                      if (states.contains(MaterialState.disabled)) {
                        return textColor.withOpacityCompat(0.38);
                      }
                      return AppColors.techBlue;
                    }),
                    backgroundColor:
                        MaterialStateProperty.resolveWith((states) {
                      if (states.contains(MaterialState.disabled)) {
                        return textColor.withOpacityCompat(0.04);
                      }
                      return AppColors.techBlue.withOpacityCompat(0.08);
                    }),
                    side: MaterialStateProperty.resolveWith((states) {
                      if (states.contains(MaterialState.disabled)) {
                        return BorderSide(
                          color: textColor.withOpacityCompat(0.12),
                          width: AppTokens.stroke,
                        );
                      }
                      return BorderSide(
                        color: AppColors.techBlue.withOpacityCompat(0.18),
                        width: AppTokens.stroke,
                      );
                    }),
                    elevation: const MaterialStatePropertyAll(0),
                    padding: const MaterialStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                    shape: MaterialStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.brush_rounded, size: 15),
                  label: Text(
                    switch (item.status) {
                      ill.IllustrationStatus.generating => '生成中',
                      _ => '生成',
                    },
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            if (item.status == ill.IllustrationStatus.failed &&
                (item.errorMsg ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                item.errorMsg!,
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

  Widget _media(
      {required ill.IllustrationItem item, required Color textColor}) {
    if (item.status != ill.IllustrationStatus.completed) {
      return const SizedBox.shrink();
    }
    final p = item.localImagePath;
    if (p != null && p.trim().isNotEmpty) {
      return buildSceneImage(p, fit: BoxFit.cover);
    }
    return const Center(child: Icon(Icons.broken_image));
  }
}

class _BrushLoading extends StatefulWidget {
  const _BrushLoading();

  @override
  State<_BrushLoading> createState() => _BrushLoadingState();
}

class _BrushLoadingState extends State<_BrushLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        const baseAngle = math.pi * 7 / 4;
        final angle = baseAngle + (t - 0.5) * 0.2;
        final dx = (t - 0.5) * 2.4;
        final dy = (0.5 - (t - 0.5).abs()) * 1.8;
        final opacity = 0.78 + 0.22 * (1 - (t - 0.5).abs() * 2);

        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(dx, dy),
            child: Transform.rotate(
              angle: angle,
              child: Icon(
                Icons.brush_rounded,
                size: 22,
                color: AppColors.techBlue.withOpacityCompat(0.9),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PromptWithEditIcon extends StatelessWidget {
  final String text;
  final Color textColor;
  final int maxLines;
  final VoidCallback onEdit;

  const _PromptWithEditIcon({
    required this.text,
    required this.textColor,
    required this.maxLines,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    const iconSize = 16.0;
    const iconPadL = 4.0;
    const iconPadV = 2.0;
    final style = TextStyle(
      fontSize: 13,
      height: 1.5,
      color: textColor.withOpacityCompat(0.72),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final reserved = iconSize + iconPadL + iconPadV * 2;
        final maxTextWidth =
            (constraints.maxWidth - reserved).clamp(0.0, constraints.maxWidth);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: maxTextWidth);

        final wouldOverflow = painter.didExceedMaxLines;
        final icon = InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.only(
                left: iconPadL, top: iconPadV, bottom: iconPadV),
            child: Icon(
              Icons.edit_rounded,
              size: iconSize,
              color: textColor.withOpacityCompat(0.42),
            ),
          ),
        );

        if (!wouldOverflow) {
          return Text.rich(
            TextSpan(
              text: text,
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: icon,
                ),
              ],
            ),
            style: style,
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                text,
                style: style,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            icon,
          ],
        );
      },
    );
  }
}
