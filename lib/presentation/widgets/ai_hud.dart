import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/local_llm/local_llm_client.dart';
import '../../ai/reading/reading_context_service.dart';
import '../../ai/reading/qa_service.dart';
export '../../ai/reading/qa_service.dart' show QAStreamChunk, QAType;
import '../../ai/translation/translation_types.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../providers/ai_model_provider.dart';
import '../providers/translation_provider.dart';
import 'glass_panel.dart';

enum AiHudRoute {
  main,
  qa,
  tencentSettings,
}

/// AI companion bottom sheet with in-panel navigation.
///
/// Design goals:
/// - Continuous features use unified Switch toggles.
/// - Remove the top-right close icon; sheet dismissal is handled by outside tap / drag.
/// - Each row has its own settings entry (chevron) and row-tap navigation.
class AiHud extends StatefulWidget {
  final Color bgColor;
  final Color textColor;
  final AiHudRoute initialRoute;
  final String? initialQaText;
  final bool autoSendInitialQa;

  /// Feature enabled state (controls whether quick actions should appear).
  final bool translateEnabled;

  /// Active state (controls whether translation is applied to the reader content).
  final bool translateActive;

  final ValueChanged<bool>? onTranslateChanged;

  final bool readAloudEnabled;
  final ValueChanged<bool>? onReadAloudChanged;

  /// QA scope data (per-book)
  final String bookId;

  /// Reading context for AI QA (use effective/plain text, not raw HTML)
  final Map<int, String> chapterTextCache;
  final int currentChapterIndex;
  final int currentPageInChapter;
  final Map<int, List<TextRange>> chapterPageRanges;

  const AiHud({
    super.key,
    this.bgColor = Colors.white,
    this.textColor = AppColors.deepSpace,
    this.initialRoute = AiHudRoute.main,
    this.initialQaText,
    this.autoSendInitialQa = false,
    required this.translateEnabled,
    this.translateActive = false,
    this.onTranslateChanged,
    required this.readAloudEnabled,
    this.onReadAloudChanged,
    required this.bookId,
    required this.chapterTextCache,
    required this.currentChapterIndex,
    required this.currentPageInChapter,
    required this.chapterPageRanges,
  });

  @override
  State<AiHud> createState() => _AiHudState();
}

class _AiHudState extends State<AiHud> with TickerProviderStateMixin {
  final List<AiHudRoute> _stack = [AiHudRoute.main];
  bool _initialQaConsumed = false;

  AiHudRoute get _route => _stack.isEmpty ? AiHudRoute.main : _stack.last;

  void _push(AiHudRoute next) {
    if (next == _route) return;
    setState(() {
      _stack.add(next);
    });
  }

  void _pop() {
    if (_stack.length <= 1) return;
    setState(() {
      _stack.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialRoute != AiHudRoute.main) {
      _stack.add(widget.initialRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.bgColor.computeLuminance() < 0.5;

    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_stack.length > 1) _pop();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.of(context);
          final mediaH = media.size.height;
          final availableH =
              constraints.maxHeight.isFinite ? constraints.maxHeight : mediaH;

          final bool reduceMotion =
              (media.disableAnimations) || media.accessibleNavigation;
          final bool isQa = _route == AiHudRoute.qa;

          // QA keeps the existing fixed tier: ~72% of screen height with clamp.
          final qaHeight = (availableH * 0.72).clamp(420.0, availableH);

          // Non-QA adapts to content, but should not grow beyond this cap.
          final nonQaMaxHeight = (availableH * 0.72).clamp(320.0, availableH);

          final body = AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) {
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.04, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              );
            },
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                children: [
                  ...previousChildren.map(
                      (w) => Positioned.fill(child: IgnorePointer(child: w))),
                  if (currentChild != null) currentChild,
                ],
              );
            },
            child: _buildBody(isDark: isDark),
          );

          final panel = GlassPanel.sheet(
            surfaceColor: widget.bgColor,
            opacity: AppTokens.glassOpacityDense,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                child: Column(
                  mainAxisSize: isQa ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    const SizedBox(height: 2),
                    if (isQa)
                      Expanded(child: body)
                    else
                      Flexible(
                        fit: FlexFit.loose,
                        child: body,
                      ),
                  ],
                ),
              ),
            ),
          );

          final sizedPanel = isQa
              ? SizedBox(height: qaHeight, child: panel)
              : ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: nonQaMaxHeight),
                  child: panel,
                );

          return ClipRect(
            child: AnimatedSize(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: sizedPanel,
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    final title = switch (_route) {
      AiHudRoute.main => 'AI伴读',
      AiHudRoute.qa => '问答',
      AiHudRoute.tencentSettings => 'AI设置',
    };

    return Row(
      children: [
        if (_route != AiHudRoute.main)
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: widget.textColor.withOpacity(0.8)),
            onPressed: _pop,
            tooltip: '返回',
          )
        else
          const Icon(Icons.auto_awesome, color: AppColors.techBlue),
        if (_route == AiHudRoute.main) const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: widget.textColor,
          ),
        ),
        const Spacer(),
        if (_route == AiHudRoute.main)
          IconButton(
            tooltip: 'AI设置',
            icon: Icon(Icons.tune_rounded,
                color: widget.textColor.withOpacity(0.75)),
            onPressed: () => _push(AiHudRoute.tencentSettings),
          ),
      ],
    );
  }

  Widget _buildBody({required bool isDark}) {
    return switch (_route) {
      AiHudRoute.main => _MainPanel(
          key: const ValueKey('main'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          translateEnabled: widget.translateEnabled,
          translateActive: widget.translateActive,
          onTranslateChanged: widget.onTranslateChanged,
          readAloudEnabled: widget.readAloudEnabled,
          onReadAloudChanged: widget.onReadAloudChanged,
          onOpenQa: () => _push(AiHudRoute.qa),
        ),
      AiHudRoute.qa => _QaPanel(
          key: const ValueKey('qa'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          initialQaText: _initialQaConsumed ? null : widget.initialQaText,
          autoSendInitialQa:
              _initialQaConsumed ? false : widget.autoSendInitialQa,
          onInitialQaConsumed: () {
            if (_initialQaConsumed) return;
            setState(() {
              _initialQaConsumed = true;
            });
          },
          bookId: widget.bookId,
          chapterTextCache: widget.chapterTextCache,
          currentChapterIndex: widget.currentChapterIndex,
          currentPageInChapter: widget.currentPageInChapter,
          chapterPageRanges: widget.chapterPageRanges,
        ),
      AiHudRoute.tencentSettings => _TencentHunyuanSettingsPanel(
          key: const ValueKey('tencentSettings'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
        ),
    };
  }
}

class _TencentHunyuanSettingsPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;

  const _TencentHunyuanSettingsPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
  });

  @override
  State<_TencentHunyuanSettingsPanel> createState() =>
      _TencentHunyuanSettingsPanelState();
}

class _TencentHunyuanSettingsPanelState
    extends State<_TencentHunyuanSettingsPanel> {
  int? _voiceType;
  double? _speed;

  static const Map<int, String> _ttsLargeModelVoices = {
    501000: '智斌（阅读男声）',
    501001: '智兰（资讯女声）',
    501002: '智菊（阅读女声）',
    501003: '智宇（阅读男声）',
    501004: '月华（聊天女声）',
    501005: '飞镜（聊天男声）',
    501006: '千嶂（聊天男声）',
    501007: '浅草（聊天男声）',
    501008: 'WeJames（外语男声）',
    501009: 'WeWinny（外语女声）',
    601000: '爱小溪（聊天女声）',
    601001: '爱小洛（阅读女声）',
    601002: '爱小辰（聊天男声）',
    601003: '爱小荷（阅读女声）',
    601004: '爱小树（资讯男声）',
    601005: '爱小静（聊天女声）',
    601006: '爱小耀（阅读男声）',
    601007: '爱小叶（聊天女声）',
    601008: '爱小豪（聊天男声）',
    601009: '爱小芊（聊天女声）',
    601010: '爱小娇（聊天女声）',
    601011: '爱小川（聊天男声）',
    601012: '爱小璟（特色女声）',
    601013: '爱小伊（阅读女声）',
    601014: '爱小简（聊天男声）',
    601015: '爱小童（男童声）',
    502001: '智小柔（聊天女声）',
    502003: '智小敏（聊天女声）',
    502004: '智小满（营销女声）',
    502005: '智小解（解说男声）',
    502006: '智小悟（聊天男声）',
    502007: '智小虎（聊天童声）',
    602003: '爱小悠（聊天女声）',
    602004: '暖心阿灿（聊天男声）',
    602005: '专业梓欣（聊天女声）',
    603000: '懂事少年（特色男声）',
    603001: '潇湘妹妹（特色女声）',
    603002: '软萌心心（特色男童声）',
    603003: '随和老李（聊天男声）',
    603004: '温柔小柠（聊天女声）',
    603005: '知心大林（聊天男声）',
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<TranslationProvider>();
    _voiceType ??= provider.ttsVoiceType;
    _speed ??= provider.ttsSpeed;
  }

  @override
  Widget build(BuildContext context) {
    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _modelCard(context, cardBg: cardBg),
          const SizedBox(height: 10),
          _translationSettings(context, cardBg: cardBg),
          const SizedBox(height: 10),
          _readAloudSettings(cardBg: cardBg),
          const SizedBox(height: 10),
          _qaContentScopeSettings(cardBg: cardBg),
        ],
      ),
    );
  }

  static const _langs = <String, String>{
    '': '自动',
    'zh-Hans': '中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'fr': '法语',
    'de': '德语',
    'es': '西班牙语',
    'ru': '俄语',
  };

  Widget _translationSettings(
    BuildContext context, {
    required Color cardBg,
  }) {
    final provider = context.watch<TranslationProvider>();
    final cfg = provider.config;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
            color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '翻译设置',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _dropdown(
                  label: '源语言（可选）',
                  value: cfg.sourceLang,
                  items: _langs,
                  onChanged: (v) => provider.setSourceLang(v ?? ''),
                  textColor: widget.textColor,
                  dropdownColor: cardBg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _dropdown(
                  label: '目标语言（必选）',
                  value: cfg.targetLang,
                  items: Map<String, String>.from(_langs)..remove(''),
                  onChanged: (v) => provider.setTargetLang(v ?? 'en'),
                  textColor: widget.textColor,
                  dropdownColor: cardBg,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '显示模式',
            style: TextStyle(
              color: widget.textColor,
              fontSize: 13,
              fontWeight: FontWeight.normal,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            children: [
              _chip(
                label: '仅显示译文',
                active:
                    cfg.displayMode == TranslationDisplayMode.translationOnly,
                onTap: () => provider
                    .setDisplayMode(TranslationDisplayMode.translationOnly),
                textColor: widget.textColor,
              ),
              _chip(
                label: '双语对照',
                active: cfg.displayMode == TranslationDisplayMode.bilingual,
                onTap: () =>
                    provider.setDisplayMode(TranslationDisplayMode.bilingual),
                textColor: widget.textColor,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _readAloudSettings({required Color cardBg}) {
    final provider = context.watch<TranslationProvider>();
    final voiceItems = <String, String>{
      for (final e in _ttsLargeModelVoices.entries) e.key.toString(): e.value,
    };
    final voiceValue = (_voiceType ?? provider.ttsVoiceType).toString();
    final speedValue = _speed ?? provider.ttsSpeed;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
            color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '朗读设置',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          _dropdown(
            label: '音色选择',
            value: voiceItems.containsKey(voiceValue)
                ? voiceValue
                : voiceItems.keys.first,
            items: voiceItems,
            onChanged: (v) async {
              final parsed = int.tryParse(v ?? '');
              if (parsed == null) return;
              setState(() {
                _voiceType = parsed;
              });
              await provider.setTtsVoiceType(parsed);
            },
            textColor: widget.textColor,
            dropdownColor: cardBg,
          ),
          const SizedBox(height: 12),
          Text(
            '语速',
            style: TextStyle(
              color: widget.textColor,
              fontSize: 13,
              fontWeight: FontWeight.normal,
            ),
          ),
          Slider(
            value: speedValue.clamp(0.6, 1.6),
            min: 0.6,
            max: 1.6,
            divisions: 10,
            activeColor: AppColors.techBlue,
            label: speedValue.toStringAsFixed(1),
            onChanged: (v) => setState(() => _speed = v),
            onChangeEnd: (v) => provider.setTtsSpeed(v),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
    required Color textColor,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? AppColors.techBlue.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppColors.techBlue : textColor.withOpacity(0.18),
            width: AppTokens.stroke,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color:
                    active ? AppColors.techBlue : textColor.withOpacity(0.75),
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
    required Color textColor,
    required Color dropdownColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: textColor, fontWeight: FontWeight.normal, fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: DropdownButtonFormField<String>(
            value: items.containsKey(value) ? value : items.keys.first,
            dropdownColor: dropdownColor,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: dropdownColor,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: textColor.withOpacity(0.18),
                  width: AppTokens.stroke,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: textColor.withOpacity(0.18),
                  width: AppTokens.stroke,
                ),
              ),
            ),
            items: items.entries
                .map(
                  (e) => DropdownMenuItem<String>(
                    value: e.key,
                    child: Text(e.value, style: const TextStyle(fontSize: 13)),
                  ),
                )
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _qaContentScopeSettings({
    required Color cardBg,
  }) {
    return Consumer2<AiModelProvider, TranslationProvider>(
      builder: (context, aiModel, tp, child) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
                color: widget.textColor.withOpacity(0.08),
                width: AppTokens.stroke),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '问答设置',
                style: TextStyle(
                  color: widget.textColor,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '问答内容范围',
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _scopeChip(
                    label: '当前页',
                    value: QAContentScope.currentPage,
                    groupValue: aiModel.qaContentScope,
                    onChanged: (scope) => aiModel.setQAContentScope(scope),
                  ),
                  _scopeChip(
                    label: '本章至当前',
                    value: QAContentScope.currentChapterToPage,
                    groupValue: aiModel.qaContentScope,
                    onChanged: (scope) => aiModel.setQAContentScope(scope),
                  ),
                  _scopeChip(
                    label: '前后5页',
                    value: QAContentScope.slidingWindow,
                    groupValue: aiModel.qaContentScope,
                    onChanged: (scope) => aiModel.setQAContentScope(scope),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _scopeChip({
    required String label,
    required QAContentScope value,
    required QAContentScope groupValue,
    required ValueChanged<QAContentScope> onChanged,
  }) {
    final bool active = value == groupValue;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onChanged(value),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? AppColors.techBlue.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? AppColors.techBlue
                : widget.textColor.withOpacity(0.18),
            width: AppTokens.stroke,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: active
                    ? AppColors.techBlue
                    : widget.textColor.withOpacity(0.75),
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelCard(
    BuildContext context, {
    required Color cardBg,
  }) {
    final aiModel = context.watch<AiModelProvider>();
    final source = aiModel.source;
    final enabled = source != AiModelSource.none;

    Future<void> setSource(AiModelSource value) async {
      if (value == source) return;
      await aiModel.setSource(value);
    }

    Future<void> setEnabled(bool value) async {
      if (!value) {
        await aiModel.setSource(AiModelSource.none);
        return;
      }
      if (source == AiModelSource.none) {
        await aiModel.setSource(AiModelSource.local);
      }
    }

    Widget chip(String label, AiModelSource value) {
      final active = source == value;
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? () => setSource(value) : null,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active
                ? AppColors.techBlue.withOpacity(0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? AppColors.techBlue
                  : widget.textColor.withOpacity(0.18),
              width: AppTokens.stroke,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: active
                      ? AppColors.techBlue
                      : widget.textColor.withOpacity(0.8),
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    String statusText() {
      if (!enabled) return '未启用：请先开启大模型后再使用 AI 功能';
      if (source == AiModelSource.online) return '';
      if (source == AiModelSource.local) return '';
      return '';
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
                color: widget.textColor.withOpacity(0.08),
                width: AppTokens.stroke),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '大模型',
                      style: TextStyle(
                        color: widget.textColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 24,
                    child: Transform.scale(
                      scale: 0.75,
                      child: Switch(
                        value: enabled,
                        activeColor: AppColors.techBlue,
                        onChanged: (v) => setEnabled(v),
                      ),
                    ),
                  ),
                ],
              ),
              if (enabled) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    chip('本地', AiModelSource.local),
                    chip('在线', AiModelSource.online),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              if (statusText().isNotEmpty)
                Text(
                  statusText(),
                  style: TextStyle(
                    color: widget.textColor.withOpacity(0.7),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              if (enabled && source == AiModelSource.local) ...[
                const SizedBox(height: 10),
                _localModelStatusSection(aiModel),
                if (!aiModel.localModelDownloading &&
                    !aiModel.localModelInstalling &&
                    aiModel.localModelError.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    aiModel.localModelError,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
              if (enabled && source == AiModelSource.online) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '更好的AI体验，需要购买时长后使用',
                        style: TextStyle(
                          color: widget.textColor.withOpacity(0.65),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: () {},
                      child: const Text(
                        '购买',
                        style: TextStyle(
                          color: AppColors.techBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _localModelStatusSection(AiModelProvider aiModel) {
    return Column(
      children: [
        _localModelStatusRow(
          aiModel,
          type: LocalLlmModelType.translation,
          title: 'HY-MT1.5-1.8B',
          sizeText: '860M',
          capabilityText: '翻译',
        ),
        const SizedBox(height: 10),
        _localModelStatusRow(
          aiModel,
          type: LocalLlmModelType.qa,
          title: 'Qwen3-0.6B',
          sizeText: '280M',
          capabilityText: '问答',
        ),
      ],
    );
  }

  Widget _localModelStatusRow(
    AiModelProvider aiModel, {
    required LocalLlmModelType type,
    required String title,
    required String sizeText,
    required String capabilityText,
  }) {
    String text = '$title未下载($sizeText)，下载后可在无网环境使用$capabilityText';
    Widget? action;

    if (aiModel.isLocalModelInstallingByType(type)) {
      text = '$title安装中…';
      action = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: null,
          color: AppColors.techBlue,
        ),
      );
    } else if (aiModel.isLocalModelDownloadingByType(type)) {
      text = '$title下载中，下载后可在无网环境使用$capabilityText';
      String pctText = '';
      final total = aiModel.localModelTotalBytesByType(type);
      final double progress =
          aiModel.localModelProgressByType(type).clamp(0.0, 1.0);
      if (total > 0) {
        final pct = (progress * 100).round();
        pctText = '$pct%';
      }
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: total > 0 ? progress : null,
              color: AppColors.techBlue,
            ),
          ),
          if (pctText.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              pctText,
              style: const TextStyle(
                color: AppColors.techBlue,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(width: 12),
          InkWell(
            onTap: aiModel.pauseLocalModelDownload,
            child: Text(
              '暂停',
              style: TextStyle(
                color: widget.textColor.withOpacity(0.6),
                fontSize: 13,
              ),
            ),
          ),
        ],
      );
    } else if (aiModel.isLocalModelQueuedByType(type)) {
      text = '$title已加入队列，等待下载…';
      action = Text(
        '队列中',
        style: TextStyle(
          color: widget.textColor.withOpacity(0.6),
          fontSize: 13,
        ),
      );
    } else if (aiModel.isLocalModelPausedByType(type)) {
      text = '$title下载已暂停，点击下载继续';
      String pctText = '';
      final total = aiModel.localModelTotalBytesByType(type);
      final double progress =
          aiModel.localModelProgressByType(type).clamp(0.0, 1.0);
      if (total > 0) {
        final pct = (progress * 100).round();
        pctText = '$pct%';
      }
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pctText.isNotEmpty) ...[
            Text(
              pctText,
              style: TextStyle(
                color: widget.textColor.withOpacity(0.6),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
          ],
          InkWell(
            onTap: () => aiModel.startLocalModelDownloadForType(type),
            child: const Text(
              '下载',
              style: TextStyle(
                color: AppColors.techBlue,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    } else if (aiModel.localModelExistsByType(type)) {
      text = '可在无网环境使用$capabilityText';
      action = null;
    } else {
      action = InkWell(
        onTap: () => aiModel.startLocalModelDownloadForType(type),
        child: const Text(
          '下载',
          style: TextStyle(
            color: AppColors.techBlue,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: widget.textColor.withOpacity(0.65),
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: 12),
          action,
        ],
      ],
    );
  }
}

class _MainPanel extends StatelessWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;

  final bool translateEnabled;
  final bool translateActive;
  final ValueChanged<bool>? onTranslateChanged;

  final bool readAloudEnabled;
  final ValueChanged<bool>? onReadAloudChanged;

  final VoidCallback onOpenQa;

  const _MainPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.translateEnabled,
    required this.translateActive,
    required this.onTranslateChanged,
    required this.readAloudEnabled,
    required this.onReadAloudChanged,
    required this.onOpenQa,
  });

  @override
  Widget build(BuildContext context) {
    final aiModel = context.watch<AiModelProvider>();
    final source = aiModel.source;

    final bool modelEnabled = source != AiModelSource.none;
    final bool translateReady = switch (source) {
      AiModelSource.none => false,
      AiModelSource.online => true,
      AiModelSource.local => aiModel.isLocalTranslationModelReady,
    };
    final bool qaReady = switch (source) {
      AiModelSource.none => false,
      AiModelSource.online => true,
      AiModelSource.local => aiModel.isLocalQaModelReady,
    };

    String localBlockedHintFor(LocalLlmModelType type, String modelName) {
      if (source != AiModelSource.local) return '';
      if (aiModel.isLocalModelInstallingByType(type)) return '$modelName安装中…';
      if (aiModel.isLocalModelDownloadingByType(type)) return '$modelName下载中…';
      if (aiModel.isLocalModelPausedByType(type)) return '$modelName下载已暂停';
      if (!aiModel.localModelExistsByType(type)) return '$modelName未下载，下载后可用';
      if (!aiModel.localRuntimeAvailable) return '本地推理后端未就绪';
      return '本地模型未就绪';
    }

    final translateSubtitle = !modelEnabled
        ? '请先在 AI设置 中启用大模型'
        : (source == AiModelSource.local && !translateReady)
            ? localBlockedHintFor(LocalLlmModelType.translation, '翻译模型')
            : translateEnabled
                ? (translateActive ? '翻译中' : '已暂停')
                : '开启后，自动应用到正文';

    final readAloudSubtitle = !modelEnabled
        ? '请先在 AI设置 中启用大模型'
        : source != AiModelSource.online
            ? '朗读仅支持在线模式'
            : (readAloudEnabled ? '已开启' : '开启后，可朗读当前页');

    final perfEnabled =
        source == AiModelSource.local && aiModel.localRuntimeAvailable;
    final perfSubtitle = source != AiModelSource.local
        ? '仅本地模式可用'
        : !aiModel.localRuntimeAvailable
            ? '本地推理后端未就绪'
            : '查看当前配置并跑一次小测试';

    return SingleChildScrollView(
      key: const PageStorageKey('ai_hud_main_scroll'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!modelEnabled) ...[
            _disabledHint(),
            const SizedBox(height: 10),
          ],
          _featureRow(
            context,
            icon: Icons.translate,
            title: '翻译',
            subtitle: translateSubtitle,
            value: translateEnabled,
            onChanged: translateReady ? onTranslateChanged : null,
          ),
          const SizedBox(height: 10),
          _featureRow(
            context,
            icon: Icons.volume_up,
            title: '朗读',
            subtitle: readAloudSubtitle,
            value: readAloudEnabled,
            onChanged:
                source == AiModelSource.online ? onReadAloudChanged : null,
          ),
          const SizedBox(height: 14),
          _qaEntry(
            enabled: qaReady,
            subtitle: !modelEnabled
                ? '请先在 AI设置 中启用大模型'
                : (source == AiModelSource.local && !qaReady)
                    ? localBlockedHintFor(LocalLlmModelType.qa, '本地模型')
                    : '支持问答/总结/提取要点',
            onTap: qaReady ? onOpenQa : () {},
          ),
          const SizedBox(height: 10),
          _perfEntry(
            enabled: perfEnabled,
            subtitle: perfSubtitle,
            onTap: perfEnabled ? () => _openLocalPerfCheck(context) : () {},
          ),
        ],
      ),
    );
  }

  Future<void> _openLocalPerfCheck(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var started = false;
        String report = '';
        var running = false;

        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> run() async {
              if (running) return;
              setState(() {
                running = true;
                report = '运行中…';
              });

              final aiModel = dialogContext.read<AiModelProvider>();
              final buf = StringBuffer();
              buf.writeln('time=${DateTime.now().toIso8601String()}');
              buf.writeln('platform=${defaultTargetPlatform.name}');
              buf.writeln('source=${aiModel.source.name}');
              buf.writeln(
                  'localRuntimeAvailable=${aiModel.localRuntimeAvailable}');
              buf.writeln('qaReady=${aiModel.isLocalQaModelReady}');
              buf.writeln(
                  'translationReady=${aiModel.isLocalTranslationModelReady}');
              buf.writeln();

              Future<void> dump(LocalLlmModelType type) async {
                final sw = Stopwatch()..start();
                try {
                  final client = LocalLlmClient(modelType: type);
                  final cfg = await client.dumpConfig();
                  sw.stop();
                  buf.writeln(
                      '[${type.name}] dumpConfigMs=${sw.elapsedMilliseconds}');
                  buf.writeln(cfg.trim().isEmpty ? '(empty)' : cfg.trim());
                } catch (e) {
                  sw.stop();
                  buf.writeln(
                      '[${type.name}] dumpConfigMs=${sw.elapsedMilliseconds}');
                  buf.writeln('error=${e.toString()}');
                }
                buf.writeln();
              }

              Future<void> streamTest({
                required LocalLlmModelType type,
                required String label,
                required String prompt,
              }) async {
                final client = LocalLlmClient(modelType: type);
                final swAll = Stopwatch()..start();
                final swFirst = Stopwatch()..start();
                var firstMs = -1;
                var outLen = 0;
                var chunkCount = 0;
                try {
                  await for (final chunk in client.chatStream(
                    userText: prompt,
                    maxNewTokens: 96,
                    maxInputTokens: 0,
                    temperature: 0.2,
                    topP: 0.95,
                    topK: 40,
                    repetitionPenalty: 1.02,
                    enableThinking: false,
                  )) {
                    if (chunk.isEmpty) continue;
                    chunkCount += 1;
                    outLen += chunk.length;
                    if (firstMs < 0) {
                      swFirst.stop();
                      firstMs = swFirst.elapsedMilliseconds;
                    }
                    if (outLen >= 256) break;
                  }
                  swAll.stop();
                  buf.writeln(
                      '[$label] firstChunkMs=$firstMs totalMs=${swAll.elapsedMilliseconds} chunks=$chunkCount outLen=$outLen');
                } catch (e) {
                  swAll.stop();
                  final t = firstMs < 0 ? swFirst.elapsedMilliseconds : firstMs;
                  buf.writeln(
                      '[$label] firstChunkMs=$t totalMs=${swAll.elapsedMilliseconds} error=${e.toString()}');
                }
                buf.writeln();
              }

              await dump(LocalLlmModelType.translation);
              await dump(LocalLlmModelType.qa);

              if (aiModel.source == AiModelSource.local &&
                  aiModel.localRuntimeAvailable) {
                if (aiModel.isLocalQaModelReady) {
                  await streamTest(
                    type: LocalLlmModelType.qa,
                    label: 'qa',
                    prompt: '你好，请只回复“OK”。',
                  );
                } else {
                  buf.writeln('[qa] skipped=not_ready');
                  buf.writeln();
                }

                if (aiModel.isLocalTranslationModelReady) {
                  await streamTest(
                    type: LocalLlmModelType.translation,
                    label: 'translation',
                    prompt: '将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n你好，世界。',
                  );
                } else {
                  buf.writeln('[translation] skipped=not_ready');
                  buf.writeln();
                }
              }

              setState(() {
                running = false;
                report = buf.toString().trimRight();
              });
            }

            if (!started) {
              started = true;
              scheduleMicrotask(run);
            }

            final theme = Theme.of(dialogContext);
            final isDarkBg = theme.colorScheme.surface.computeLuminance() < 0.5;
            final fg = isDarkBg ? Colors.white : AppColors.deepSpace;

            return AlertDialog(
              title: const Text('本地推理性能自检'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: SelectableText(
                    report.isEmpty ? '准备中…' : report,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: fg.withOpacity(0.9),
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: running
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: report));
                          Navigator.of(dialogContext).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制并关闭')),
                          );
                        },
                  child: const Text('复制并关闭'),
                ),
                TextButton(
                  onPressed: running ? null : run,
                  child: Text(running ? '运行中…' : '重新运行'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _disabledHint() {
    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
            color: textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: textColor.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.lock_outline_rounded,
              color: textColor.withOpacity(0.7),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '未启用大模型：请先进入 AI设置 开启后再使用',
              style: TextStyle(
                color: textColor.withOpacity(0.75),
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;
    final Color borderColor = value
        ? AppColors.techBlue.withOpacity(0.55)
        : textColor.withOpacity(0.08);

    final bool disabled = onChanged == null;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: borderColor, width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                if (disabled) return;
                onChanged(!value);
              },
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 6, 2),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: value
                            ? AppColors.techBlue.withOpacity(0.12)
                            : textColor.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        icon,
                        color: value
                            ? AppColors.techBlue
                            : textColor.withOpacity(0.8),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: textColor.withOpacity(0.65),
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Switch(
            value: value,
            activeColor: AppColors.techBlue,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _qaEntry({
    required bool enabled,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(
              color: textColor.withOpacity(0.08), width: AppTokens.stroke),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: enabled
                    ? AppColors.techBlue.withOpacity(0.12)
                    : textColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.question_answer,
                color:
                    enabled ? AppColors.techBlue : textColor.withOpacity(0.7),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '问答',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: textColor.withOpacity(0.65),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: textColor.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  Widget _perfEntry({
    required bool enabled,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(
              color: textColor.withOpacity(0.08), width: AppTokens.stroke),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: enabled
                    ? AppColors.techBlue.withOpacity(0.12)
                    : textColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.speed,
                color:
                    enabled ? AppColors.techBlue : textColor.withOpacity(0.7),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '性能自检',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: textColor.withOpacity(0.65),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: textColor.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }
}

enum _QaRole { user, assistant, divider }

class _QaMsg {
  final _QaRole role;
  final String text;
  final String reasoning;
  final bool reasoningCollapsed;
  const _QaMsg(
    this.role,
    this.text, {
    this.reasoning = '',
    this.reasoningCollapsed = true,
  });

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'text': text,
        'reasoning': reasoning,
        'reasoningCollapsed': reasoningCollapsed,
      };

  static _QaMsg fromJson(Map<String, dynamic> json) {
    final rawRole = (json['role'] ?? '').toString();
    final role = _QaRole.values.firstWhere(
      (e) => e.name == rawRole,
      orElse: () => _QaRole.assistant,
    );
    return _QaMsg(
      role,
      (json['text'] ?? '').toString(),
      reasoning: (json['reasoning'] ?? '').toString(),
      reasoningCollapsed: (json['reasoningCollapsed'] is bool)
          ? (json['reasoningCollapsed'] as bool)
          : true,
    );
  }
}

enum _MessageState {
  idle,
  thinking,
  answering,
}

class _QaPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String? initialQaText;
  final bool autoSendInitialQa;
  final VoidCallback? onInitialQaConsumed;
  final String bookId;
  final Map<int, String> chapterTextCache;
  final int currentChapterIndex;
  final int currentPageInChapter;
  final Map<int, List<TextRange>> chapterPageRanges;

  const _QaPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    this.initialQaText,
    this.autoSendInitialQa = false,
    this.onInitialQaConsumed,
    required this.bookId,
    required this.chapterTextCache,
    required this.currentChapterIndex,
    required this.currentPageInChapter,
    required this.chapterPageRanges,
  });

  @override
  State<_QaPanel> createState() => _QaPanelState();
}

class _QaPanelState extends State<_QaPanel> {
  static const String _kWelcomeMessage =
      '你好，我是Air！你的AI伴读助手。\n我可以帮你总结章节要点、解释复杂概念，或者回答任何关于这本书的问题。\n快来问我吧！';
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final List<_QaMsg> _messages = [];
  Timer? _persistTimer;
  int? _activeReplyIndex;
  _MessageState _messageState = _MessageState.idle;
  StreamSubscription<QAStreamChunk>? _streamSub;
  bool _initialQaHandled = false;

  // Throttling for web setState
  Timer? _updateTimer;
  bool _needsUiUpdate = false;
  bool _shouldScrollToBottom = false;

  bool _localInThink = false;
  String _localTagCarry = '';
  String _localRawText = '';

  void _resetLocalStreamSanitizer() {
    _localInThink = false;
    _localTagCarry = '';
    _localRawText = '';
  }

  String _sanitizeLocalDelta(String input) {
    if (input.isEmpty) return '';
    final buffer = StringBuffer();
    for (final r in input.runes) {
      if (r == 0x09 || r == 0x0A || r == 0x0D) {
        buffer.writeCharCode(r);
        continue;
      }
      if (r < 0x20 || r == 0x7F) continue;
      buffer.writeCharCode(r);
    }
    return buffer.toString();
  }

  String _sanitizeLocalFinalText(String input) {
    var s = input.trim();
    if (s.isEmpty) return '';

    const openAnswer = '<answer>';
    final answerStart = s.lastIndexOf(openAnswer);
    if (answerStart >= 0) {
      s = s.substring(answerStart + openAnswer.length);
    }

    s = s.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', multiLine: true),
      '',
    );
    s = s.replaceAll('<think>', '').replaceAll('</think>', '');
    s = s.replaceAll(openAnswer, '').replaceAll('</answer>', '');
    s = s.replaceAll('<answer>', '').replaceAll('</answer>', '');
    s = s.replaceAll(RegExp(r'</?\[[^\]]+\]>'), '');
    s = s.trim();
    return s;
  }

  ({String answer, String think}) _splitLocalDelta(String delta) {
    if (delta.isEmpty) return (answer: '', think: '');
    var input = '$_localTagCarry$delta';
    _localTagCarry = '';

    final answer = StringBuffer();
    final think = StringBuffer();

    var i = 0;
    while (i < input.length) {
      final ch = input[i];
      if (ch == '<') {
        final remaining = input.substring(i);
        const tags = <String>[
          '<think>',
          '</think>',
          '<answer>',
          '</answer>',
        ];

        bool matched = false;
        for (final tag in tags) {
          if (remaining.startsWith(tag)) {
            matched = true;
            if (tag == '<think>') _localInThink = true;
            if (tag == '</think>') _localInThink = false;
            if (tag == '<answer>') _localInThink = false;
            i += tag.length;
            break;
          }
        }
        if (matched) continue;

        final close = remaining.indexOf('>');
        if (close == -1) {
          _localTagCarry = remaining;
          break;
        }
      }

      if (_localInThink) {
        think.write(ch);
      } else {
        answer.write(ch);
      }
      i++;
    }

    return (answer: answer.toString(), think: think.toString());
  }

  String _sanitizeLocalThinkFinal(String input) {
    final s = input;
    if (s.trim().isEmpty) return '';
    final buffer = StringBuffer();

    var idx = 0;
    while (true) {
      final start = s.indexOf('<think>', idx);
      if (start < 0) break;
      final end = s.indexOf('</think>', start + 7);
      if (end < 0) break;
      final chunk = s.substring(start + 7, end);
      if (chunk.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(chunk.trim());
      }
      idx = end + 8;
    }
    return buffer.toString().trim();
  }

  String get _historyKey => 'qa_history_${widget.bookId}';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  void _applyInitialQaIfNeeded() {
    if (_initialQaHandled) return;
    final t = (widget.initialQaText ?? '').trim();
    if (t.isEmpty) return;
    _initialQaHandled = true;
    widget.onInitialQaConsumed?.call();
    _inputCtl.text = t;
    if (widget.autoSendInitialQa) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _send();
      });
    } else {
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey) ?? '';
    if (raw.trim().isNotEmpty) {
      final decoded = await Future.value(raw)
          .then((v) => jsonDecode(v))
          .catchError((_) => null);
      if (decoded is List) {
        _messages
          ..clear()
          ..addAll(decoded
              .whereType<Map>()
              .map((e) => _QaMsg.fromJson(e.cast<String, dynamic>())));
      }
    }

    if (_messages.isEmpty) {
      _messages.add(const _QaMsg(
        _QaRole.assistant,
        _kWelcomeMessage,
      ));
    }

    if (!mounted) return;
    setState(() {});
    _applyInitialQaIfNeeded();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), _persistNow);
  }

  Future<void> _persistNow() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_messages.map((e) => e.toJson()).toList());
    await prefs.setString(_historyKey, raw);
  }

  bool _isWelcomeMessage(_QaMsg msg) {
    return msg.role == _QaRole.assistant && msg.text.startsWith('你好，我是Air！');
  }

  String _buildHistoryText({int maxTurns = 6}) {
    final int lastDividerIndex =
        _messages.lastIndexWhere((m) => m.role == _QaRole.divider);

    final items = _messages
        .asMap()
        .entries
        .where((e) => e.key > lastDividerIndex)
        .map((e) => e.value)
        .where((m) => m.text.trim().isNotEmpty && !_isWelcomeMessage(m))
        .toList();

    if (items.isEmpty) return '';
    final start = (items.length - maxTurns).clamp(0, items.length);
    final recent = items.sublist(start);
    final buffer = StringBuffer();
    for (final m in recent) {
      final prefix = m.role == _QaRole.user ? '用户' : '助手';
      buffer.writeln('$prefix: ${m.text.trim()}');
    }
    return buffer.toString().trim();
  }

  void _startNewTopic() {
    if (_messageState != _MessageState.idle) return;
    setState(() {
      _messages.add(const _QaMsg(
        _QaRole.divider,
        '已开启新话题',
      ));
      _messageState = _MessageState.idle;
      _activeReplyIndex = null;
    });
    _streamSub?.cancel();
    _schedulePersist();
    _scrollToBottom();
  }

  void _throttledUpdate() {
    if (!mounted) return;
    if (_needsUiUpdate) {
      setState(() {});
      _needsUiUpdate = false;
    }
    if (_shouldScrollToBottom) {
      _scrollToBottom();
      _shouldScrollToBottom = false;
    }
  }

  /// 更新消息列表
  void _updateMessage(int index, _QaMsg message) {
    if (!mounted) return;
    _messages[index] = message;
    _needsUiUpdate = true;
    _shouldScrollToBottom = true;

    if (kIsWeb) {
      if (_updateTimer == null || !_updateTimer!.isActive) {
        _updateTimer =
            Timer(const Duration(milliseconds: 30), _throttledUpdate);
      }
    } else {
      _throttledUpdate();
    }
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _inputCtl.dispose();
    _scrollCtl.dispose();
    _streamSub?.cancel();
    super.dispose();
  }

  void _sendQuickAction(QAType qaType) async {
    if (_messageState != _MessageState.idle) return;

    final String quickText;
    switch (qaType) {
      case QAType.summary:
        quickText = '总结当前章节';
        break;
      case QAType.keyPoints:
        quickText = '提取本章要点';
        break;
      default:
        return;
    }

    setState(() {
      _messages.add(_QaMsg(_QaRole.user, quickText));
      _messageState = _MessageState.thinking;
    });
    _schedulePersist();
    _scrollToBottom();

    _performQa(quickText, qaType, '');
  }

  Future<void> _send() async {
    final text = _inputCtl.text.trim();
    if (text.isEmpty || _messageState != _MessageState.idle) return;

    if (text == '总结本章') {
      _inputCtl.clear();
      _sendQuickAction(QAType.summary);
      return;
    }
    if (text == '提取要点') {
      _inputCtl.clear();
      _sendQuickAction(QAType.keyPoints);
      return;
    }

    final historyText = _buildHistoryText();

    setState(() {
      _messages.add(_QaMsg(_QaRole.user, text));
      _messageState = _MessageState.thinking;
      _inputCtl.text = '';
    });
    _schedulePersist();
    _scrollToBottom();

    _performQa(text, QAType.general, historyText);
  }

  Future<void> _performQa(
      String question, QAType qaType, String history) async {
    try {
      final aiModel = context.read<AiModelProvider>();
      if (aiModel.source == AiModelSource.none) {
        throw Exception('请先选择本地或在线大模型');
      }
      final isLocalModel = aiModel.source == AiModelSource.local;
      if (isLocalModel) {
        _resetLocalStreamSanitizer();
      }

      final contextService = ReadingContextService(
        chapterContentCache: widget.chapterTextCache,
        currentChapterIndex: widget.currentChapterIndex,
        currentPageInChapter: widget.currentPageInChapter,
        chapterPageRanges: widget.chapterPageRanges,
      );

      final qaService = QAService(
        contextService: contextService,
        credentials: getEmbeddedPublicHunyuanCredentials(),
        contentScope: aiModel.qaContentScope,
      );

      final stream = qaService.askQuestion(
        question: question,
        isLocalModel: isLocalModel,
        qaType: qaType,
        history: history,
      );

      _streamSub?.cancel();

      _streamSub = stream.listen(
        (QAStreamChunk chunk) {
          if (!mounted) return;

          String answerDelta = '';
          String thinkDelta = '';

          if (isLocalModel) {
            final raw = _sanitizeLocalDelta(chunk.content);
            if (raw.isNotEmpty) {
              _localRawText += raw;
              if (_localRawText.length > 30000) {
                _streamSub?.cancel();
              }
            }
            final split = _splitLocalDelta(raw);
            answerDelta = split.answer;
            thinkDelta = split.think;
          } else {
            thinkDelta = (chunk.reasoningContent ?? '');
            answerDelta = chunk.content;
          }

          if (_activeReplyIndex == null) {
            final hasAny =
                thinkDelta.trim().isNotEmpty || answerDelta.trim().isNotEmpty;
            if (!hasAny) return;
            setState(() {
              _messages.add(const _QaMsg(
                _QaRole.assistant,
                '',
                reasoningCollapsed: false,
              ));
              _activeReplyIndex = _messages.length - 1;
              _messageState = answerDelta.trim().isNotEmpty
                  ? _MessageState.answering
                  : _MessageState.thinking;
            });
          }

          final replyIndex = _activeReplyIndex!;
          final current = _messages[replyIndex];

          if (thinkDelta.isNotEmpty) {
            final nextThink = current.reasoning + thinkDelta;
            _updateMessage(
              replyIndex,
              _QaMsg(
                current.role,
                current.text,
                reasoning: nextThink,
                reasoningCollapsed: false,
              ),
            );
            _messageState = _MessageState.thinking;
          }

          if (answerDelta.isNotEmpty) {
            var nextAnswer = answerDelta;
            if (isLocalModel && current.text.isEmpty) {
              nextAnswer = nextAnswer.replaceFirst(RegExp(r'^\s+'), '');
            }
            if (nextAnswer.isNotEmpty) {
              final latest = _messages[replyIndex];
              if (latest.reasoning.trim().isNotEmpty &&
                  !latest.reasoningCollapsed) {
                _updateMessage(
                  replyIndex,
                  _QaMsg(
                    latest.role,
                    latest.text,
                    reasoning: latest.reasoning,
                    reasoningCollapsed: true,
                  ),
                );
              }
              _updateMessage(
                replyIndex,
                _QaMsg(
                  current.role,
                  current.text + nextAnswer,
                  reasoning: _messages[replyIndex].reasoning,
                  reasoningCollapsed: _messages[replyIndex].reasoningCollapsed,
                ),
              );
              _messageState = _MessageState.answering;
            }
          }
        },
        onError: (error) {
          _updateTimer?.cancel();
          _throttledUpdate();
          if (!mounted) return;

          final int errorIndex = _activeReplyIndex ?? _messages.length;
          final errorMessage = _QaMsg(
            _QaRole.assistant,
            '错误: ${error.toString()}',
          );

          setState(() {
            if (_activeReplyIndex == null) {
              _messages.add(errorMessage);
            } else {
              _messages[errorIndex] = errorMessage;
            }
            _messageState = _MessageState.idle;
            _activeReplyIndex = null;
          });
          _schedulePersist();
        },
        onDone: () {
          _updateTimer?.cancel();
          _throttledUpdate();
          if (!mounted) return;

          final replyIndex = _activeReplyIndex;
          final localFinal =
              isLocalModel ? _sanitizeLocalFinalText(_localRawText) : '';
          final localThinkFinal =
              isLocalModel ? _sanitizeLocalThinkFinal(_localRawText) : '';
          setState(() {
            _messageState = _MessageState.idle;
            _activeReplyIndex = null;
            if (!isLocalModel) {
              if (replyIndex != null) {
                final m = _messages[replyIndex];
                _messages[replyIndex] = _QaMsg(
                  m.role,
                  m.text,
                  reasoning: m.reasoning,
                  reasoningCollapsed: true,
                );
              }
              return;
            }

            if (replyIndex == null) {
              if (localFinal.trim().isNotEmpty) {
                _messages.add(_QaMsg(
                  _QaRole.assistant,
                  localFinal,
                  reasoning: localThinkFinal,
                  reasoningCollapsed: true,
                ));
              }
              return;
            }

            final current = _messages[replyIndex];
            final String finalText = localFinal.trim().isNotEmpty
                ? localFinal
                : _sanitizeLocalFinalText(current.text);
            final String finalThink = localThinkFinal.trim().isNotEmpty
                ? localThinkFinal
                : current.reasoning.trim();
            _messages[replyIndex] = _QaMsg(
              current.role,
              finalText,
              reasoning: finalThink,
              reasoningCollapsed: true,
            );
          });
          _schedulePersist();
        },
      );
    } catch (e) {
      _updateTimer?.cancel();
      _throttledUpdate();
      if (!mounted) return;

      final int errorIndex = _activeReplyIndex ?? _messages.length;
      final errorMessage = _QaMsg(
        _QaRole.assistant,
        '错误: ${e.toString()}',
      );
      setState(() {
        if (_activeReplyIndex == null) {
          _messages.add(errorMessage);
        } else {
          _messages[errorIndex] = errorMessage;
        }
        _messageState = _MessageState.idle;
        _activeReplyIndex = null;
      });
      _schedulePersist();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      _scrollCtl.animateTo(
        _scrollCtl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    Widget actionChip({
      required String label,
      required VoidCallback? onTap,
    }) {
      final bool disabled = onTap == null;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: disabled
                ? AppColors.techBlue.withOpacity(0.05)
                : AppColors.techBlue.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: disabled
                  ? AppColors.techBlue.withOpacity(0.2)
                  : AppColors.techBlue.withOpacity(0.35),
              width: AppTokens.stroke,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: disabled
                      ? AppColors.techBlue.withOpacity(0.4)
                      : AppColors.techBlue,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final panelContent = SizedBox.expand(
      key: widget.key,
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(
              color: widget.textColor.withOpacity(0.08),
              width: AppTokens.stroke),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView.builder(
                key: const PageStorageKey('ai_hud_qa_list'),
                controller: _scrollCtl,
                itemCount: _messages.length,
                itemBuilder: (context, i) {
                  final m = _messages[i];

                  if (m.role == _QaRole.divider) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          Expanded(
                              child: Divider(
                                  color: widget.textColor.withOpacity(0.1))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              m.text,
                              style: TextStyle(
                                fontSize: 13,
                                color: widget.textColor.withOpacity(0.4),
                              ),
                            ),
                          ),
                          Expanded(
                              child: Divider(
                                  color: widget.textColor.withOpacity(0.1))),
                        ],
                      ),
                    );
                  }

                  final bool isUser = m.role == _QaRole.user;
                  final Color bubbleBg = isUser
                      ? AppColors.techBlue.withOpacity(0.18)
                      : widget.textColor.withOpacity(0.06);
                  final Alignment align =
                      isUser ? Alignment.centerRight : Alignment.centerLeft;
                  return Align(
                    key: ValueKey('qa_msg_${i}_${m.text.hashCode}'),
                    alignment: align,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      constraints: const BoxConstraints(maxWidth: 340),
                      decoration: BoxDecoration(
                        color: bubbleBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: widget.textColor.withOpacity(0.08),
                          width: AppTokens.stroke,
                        ),
                      ),
                      child: isUser
                          ? Text(
                              m.text,
                              style: TextStyle(
                                color: widget.textColor,
                                height: 1.35,
                                fontSize: 15,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (m.reasoning.trim().isNotEmpty) ...[
                                  InkWell(
                                    onTap: () {
                                      setState(() {
                                        final cur = _messages[i];
                                        _messages[i] = _QaMsg(
                                          cur.role,
                                          cur.text,
                                          reasoning: cur.reasoning,
                                          reasoningCollapsed:
                                              !cur.reasoningCollapsed,
                                        );
                                      });
                                      _schedulePersist();
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '深度思考',
                                          style: TextStyle(
                                            color: widget.textColor
                                                .withOpacity(0.72),
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          m.reasoningCollapsed
                                              ? Icons.expand_more
                                              : Icons.expand_less,
                                          size: 18,
                                          color: widget.textColor
                                              .withOpacity(0.55),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!m.reasoningCollapsed) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: widget.textColor.withOpacity(
                                            widget.isDark ? 0.06 : 0.035),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            maxHeight: 140),
                                        child: SingleChildScrollView(
                                          reverse: true,
                                          child: Text(
                                            m.reasoning.trim(),
                                            style: TextStyle(
                                              color: widget.textColor
                                                  .withOpacity(0.78),
                                              height: 1.35,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                ],
                                Text(
                                  m.text.isEmpty && _activeReplyIndex == i
                                      ? '...'
                                      : m.text,
                                  style: TextStyle(
                                    color: widget.textColor,
                                    height: 1.35,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
            if (_messageState == _MessageState.thinking)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text('思考中...',
                      style: TextStyle(
                          color: widget.textColor.withOpacity(0.6),
                          fontSize: 15)),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                actionChip(
                  label: '新话题',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : _startNewTopic,
                ),
                actionChip(
                  label: '总结本章',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : () => _sendQuickAction(QAType.summary),
                ),
                actionChip(
                  label: '提取要点',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : () => _sendQuickAction(QAType.keyPoints),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !ServicesBinding.instance.keyboard.logicalKeysPressed
                              .contains(LogicalKeyboardKey.shiftLeft) &&
                          !ServicesBinding.instance.keyboard.logicalKeysPressed
                              .contains(LogicalKeyboardKey.shiftRight)) {
                        _send();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _inputCtl,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        hintText: '输入你的问题…',
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.techBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: panelContent,
    );
  }
}
