import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';


import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/reading/reading_context_service.dart';
import '../../ai/reading/qa_service.dart';
export '../../ai/reading/qa_service.dart' show QAStreamChunk, QAType;
import '../../ai/translation/glossary.dart';
import '../../ai/translation/translation_types.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../providers/ai_model_provider.dart';
import '../providers/translation_provider.dart';
import 'glass_panel.dart';

enum _AiHudRoute {
  main,
  glossary,
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

  /// Feature enabled state (controls whether quick actions should appear).
  final bool translateEnabled;

  /// Active state (controls whether translation is applied to the reader content).
  final bool translateActive;

  final ValueChanged<bool>? onTranslateChanged;

  final bool readAloudEnabled;
  final ValueChanged<bool>? onReadAloudChanged;

  final bool imageTextEnabled;
  final ValueChanged<bool>? onImageTextChanged;

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
    required this.translateEnabled,
    this.translateActive = false,
    this.onTranslateChanged,
    required this.readAloudEnabled,
    this.onReadAloudChanged,
    required this.imageTextEnabled,
    this.onImageTextChanged,
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
  final List<_AiHudRoute> _stack = [_AiHudRoute.main];

  _AiHudRoute get _route => _stack.isEmpty ? _AiHudRoute.main : _stack.last;

  void _push(_AiHudRoute next) {
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
          final bool isQa = _route == _AiHudRoute.qa;

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
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Column(
                  mainAxisSize: isQa ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    const SizedBox(height: 12),
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
      _AiHudRoute.main => 'AI伴读',
      _AiHudRoute.glossary => '术语表',
      _AiHudRoute.qa => '问答',

      _AiHudRoute.tencentSettings => 'AI设置',
    };

    return Row(
      children: [
        if (_route != _AiHudRoute.main)
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: widget.textColor.withOpacity(0.8)),
            onPressed: _pop,
            tooltip: '返回',
          )
        else
          const Icon(Icons.auto_awesome, color: AppColors.techBlue),
        if (_route == _AiHudRoute.main) const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: widget.textColor,
          ),
        ),
        const Spacer(),
        if (_route == _AiHudRoute.main)
          IconButton(
            tooltip: 'AI设置',
            icon: Icon(Icons.tune_rounded,
                color: widget.textColor.withOpacity(0.75)),
            onPressed: () => _push(_AiHudRoute.tencentSettings),
          ),
      ],
    );
  }

  Widget _buildBody({required bool isDark}) {
    return switch (_route) {
      _AiHudRoute.main => _MainPanel(
          key: const ValueKey('main'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          translateEnabled: widget.translateEnabled,
          translateActive: widget.translateActive,
          onTranslateChanged: widget.onTranslateChanged,
          readAloudEnabled: widget.readAloudEnabled,
          onReadAloudChanged: widget.onReadAloudChanged,
          imageTextEnabled: widget.imageTextEnabled,
          onImageTextChanged: widget.onImageTextChanged,
          onOpenQa: () => _push(_AiHudRoute.qa),
        ),
      _AiHudRoute.glossary => _GlossaryPanel(
          key: const ValueKey('glossary'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
        ),
      _AiHudRoute.qa => _QaPanel(
          key: const ValueKey('qa'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          bookId: widget.bookId,
          chapterTextCache: widget.chapterTextCache,
          currentChapterIndex: widget.currentChapterIndex,
          currentPageInChapter: widget.currentPageInChapter,
          chapterPageRanges: widget.chapterPageRanges,
        ),

      _AiHudRoute.tencentSettings => _TencentHunyuanSettingsPanel(
          key: const ValueKey('tencentSettings'),
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          onOpenGlossary: () => _push(_AiHudRoute.glossary),
        ),
    };
  }
}

class _TencentHunyuanSettingsPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final VoidCallback onOpenGlossary;

  const _TencentHunyuanSettingsPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.onOpenGlossary,
  });

  @override
  State<_TencentHunyuanSettingsPanel> createState() =>
      _TencentHunyuanSettingsPanelState();
}

class _TencentHunyuanSettingsPanelState
    extends State<_TencentHunyuanSettingsPanel> {
  bool _autoStart = false;
  double _rate = 1.0;
  bool _showCaptions = true;
  double _density = 0.5;

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
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '显示模式',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w700,
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
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onOpenGlossary,
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('编辑术语表'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _readAloudSettings({required Color cardBg}) {
    return Container(
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
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '进入章节自动开始',
                  style: TextStyle(color: widget.textColor.withOpacity(0.8)),
                ),
              ),
              Switch(
                value: _autoStart,
                activeColor: AppColors.techBlue,
                onChanged: (v) => setState(() => _autoStart = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '语速',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          Slider(
            value: _rate,
            min: 0.6,
            max: 1.6,
            divisions: 10,
            activeColor: AppColors.techBlue,
            label: _rate.toStringAsFixed(1),
            onChanged: (v) => setState(() => _rate = v),
          ),
        ],
      ),
    );
  }

  Widget _imageTextSettings({required Color cardBg}) {
    return Container(
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
            '图文设置',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '显示图注/说明',
                  style: TextStyle(color: widget.textColor.withOpacity(0.8)),
                ),
              ),
              Switch(
                value: _showCaptions,
                activeColor: AppColors.techBlue,
                onChanged: (v) => setState(() => _showCaptions = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '图文密度',
            style: TextStyle(
              color: widget.textColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          Slider(
            value: _density,
            min: 0,
            max: 1,
            divisions: 5,
            activeColor: AppColors.techBlue,
            label: _density.toStringAsFixed(1),
            onChanged: (v) => setState(() => _density = v),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? AppColors.techBlue : textColor.withOpacity(0.75),
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
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
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: items.containsKey(value) ? value : items.keys.first,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
      ],
    );
  }

  Widget _qaContentScopeSettings({
    required Color cardBg,
  }) {
    return Consumer2<AiModelProvider, TranslationProvider>(
      builder: (context, aiModel, tp, child) {
        return Container(
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
                '问答设置',
                style: TextStyle(
                  color: widget.textColor,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '自动术语提取',
                      style: TextStyle(color: widget.textColor.withOpacity(0.8)),
                    ),
                  ),
                  Switch(
                    value: tp.autoGlossaryExtractionEnabled,
                    activeColor: AppColors.techBlue,
                    onChanged: (v) => tp.setAutoGlossaryExtractionEnabled(v),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '问答内容范围',
                style: TextStyle(
                  color: widget.textColor,
                  fontWeight: FontWeight.w700,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.techBlue.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppColors.techBlue : widget.textColor.withOpacity(0.18),
            width: AppTokens.stroke,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.check_circle : Icons.circle_outlined,
              size: 16,
              color: active ? AppColors.techBlue : widget.textColor.withOpacity(0.6),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? AppColors.techBlue : widget.textColor.withOpacity(0.75),
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppColors.techBlue.withOpacity(0.12) : cardBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? AppColors.techBlue
                  : widget.textColor.withOpacity(0.18),
              width: AppTokens.stroke,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: active
                  ? AppColors.techBlue
                  : widget.textColor.withOpacity(0.8),
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            ),
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '大模型',
                      style: TextStyle(
                        color: widget.textColor,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Switch(
                    value: enabled,
                    activeColor: AppColors.techBlue,
                    onChanged: (v) => setEnabled(v),
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
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              if (enabled && source == AiModelSource.local) ...[
                const SizedBox(height: 10),
                _localModelStatusRow(aiModel),
                if (!aiModel.localModelDownloading &&
                    !aiModel.localModelExists) ...[
                  if (aiModel.localModelError.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      aiModel.localModelError,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ],
              if (enabled && source == AiModelSource.online && kIsWeb) ...[
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        _qaContentScopeSettings(cardBg: cardBg),
      ],
    );
  }

  Widget _localModelStatusRow(AiModelProvider aiModel) {
    String text = '模型未下载，下载后可在无网环境使用AI功能';
    Widget? action;

    if (aiModel.localModelDownloading) {
      text = '模型下载中，下载后可在无网环境使用AI功能';
      String pctText = '';
      if (aiModel.localModelTotalBytes > 0) {
        final pct = (aiModel.localModelProgress.clamp(0, 1) * 100).round();
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
              value: aiModel.localModelTotalBytes > 0
                  ? aiModel.localModelProgress.clamp(0, 1)
                  : null,
              color: AppColors.techBlue,
            ),
          ),
          if (pctText.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              pctText,
              style: TextStyle(
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
    } else if (aiModel.localModelPaused) {
      text = '下载已暂停，点击下载继续';
      String pctText = '';
      if (aiModel.localModelTotalBytes > 0) {
        final pct = (aiModel.localModelProgress.clamp(0, 1) * 100).round();
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
            onTap: aiModel.startLocalModelDownload,
            child: const Text(
              '下载', // Continue
              style: TextStyle(
                color: AppColors.techBlue,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    } else if (aiModel.localModelExists) {
      text = '可在无网环境使用AI功能';
      action = null;
    } else {
      // Not downloaded
      action = InkWell(
        onTap: aiModel.startLocalModelDownload,
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
        if (text.isNotEmpty)
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: widget.textColor.withOpacity(0.65),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          )
        else
          const Spacer(),
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

  final bool imageTextEnabled;
  final ValueChanged<bool>? onImageTextChanged;

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
    required this.imageTextEnabled,
    required this.onImageTextChanged,
    required this.onOpenQa,
  });

  @override
  Widget build(BuildContext context) {
    final aiModel = context.watch<AiModelProvider>();
    final source = aiModel.source;

    final bool modelEnabled = source != AiModelSource.none;
    const bool showImageTextFeature = false;

    final translateSubtitle = !modelEnabled
        ? '请先在 AI设置 中启用大模型'
        : translateEnabled
            ? (translateActive ? '翻译中' : '已暂停')
            : '开启后，自动应用到正文';

    final readAloudSubtitle = !modelEnabled
        ? '请先在 AI设置 中启用大模型'
        : (readAloudEnabled ? '已开启' : '开启后，可朗读当前页');

    final imageTextSubtitle = !modelEnabled
        ? '请先在 AI设置 中启用大模型'
        : (imageTextEnabled ? '已开启' : '开启后，以图文方式展示');

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
            onChanged: modelEnabled ? onTranslateChanged : null,
          ),
          const SizedBox(height: 10),
          _featureRow(
            context,
            icon: Icons.volume_up,
            title: '朗读',
            subtitle: readAloudSubtitle,
            value: readAloudEnabled,
            onChanged: modelEnabled ? onReadAloudChanged : null,
          ),
          if (showImageTextFeature) ...[
            const SizedBox(height: 10),
            _featureRow(
              context,
              icon: Icons.image_outlined,
              title: '图文',
              subtitle: imageTextSubtitle,
              value: imageTextEnabled,
              onChanged: modelEnabled ? onImageTextChanged : null,
            ),
          ],
          const SizedBox(height: 14),
          _qaEntry(
            enabled: modelEnabled,
            onTap: modelEnabled ? onOpenQa : () {},
          ),
        ],
      ),
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

  Widget _qaEntry({required bool enabled, required VoidCallback onTap}) {
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
              child: const Icon(Icons.question_answer,
                  color: AppColors.techBlue, size: 20),
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
                    '支持总结/解释/提取要点',
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

class _TranslationSettingsPanel extends StatelessWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final VoidCallback onOpenGlossary;

  const _TranslationSettingsPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.onOpenGlossary,
  });

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

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TranslationProvider>();
    final cfg = provider.config;

    final Color cardBg =
        isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return SingleChildScrollView(
      key: const PageStorageKey('ai_hud_translation_scroll'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              border: Border.all(
                  color: textColor.withOpacity(0.08), width: AppTokens.stroke),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _dropdown(
                        label: '源语言（可选）',
                        value: cfg.sourceLang,
                        items: _langs,
                        onChanged: (v) => provider.setSourceLang(v ?? ''),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _dropdown(
                        label: '目标语言（必选）',
                        value: cfg.targetLang,
                        items: Map<String, String>.from(_langs)..remove(''),
                        onChanged: (v) => provider.setTargetLang(v ?? 'en'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('显示模式',
                    style: TextStyle(
                        color: textColor, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  children: [
                    _chip(
                      label: '仅显示译文',
                      active: cfg.displayMode ==
                          TranslationDisplayMode.translationOnly,
                      onTap: () => provider.setDisplayMode(
                          TranslationDisplayMode.translationOnly),
                    ),
                    _chip(
                      label: '双语对照',
                      active:
                          cfg.displayMode == TranslationDisplayMode.bilingual,
                      onTap: () => provider
                          .setDisplayMode(TranslationDisplayMode.bilingual),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onOpenGlossary,
                    icon: const Icon(Icons.auto_fix_high, size: 18),
                    label: const Text('编辑术语表'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? AppColors.techBlue : textColor.withOpacity(0.75),
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: items.containsKey(value) ? value : items.keys.first,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
      ],
    );
  }
}

class _ReadAloudSettingsPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;

  const _ReadAloudSettingsPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
  });

  @override
  State<_ReadAloudSettingsPanel> createState() =>
      _ReadAloudSettingsPanelState();
}

class _ReadAloudSettingsPanelState extends State<_ReadAloudSettingsPanel> {
  bool _autoStart = false;
  double _rate = 1.0;

  @override
  Widget build(BuildContext context) {
    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return SingleChildScrollView(
      key: const PageStorageKey('ai_hud_read_aloud_scroll'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        children: [
          Container(
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
                Text('朗读行为',
                    style: TextStyle(
                        color: widget.textColor, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text('进入章节自动开始',
                          style: TextStyle(
                              color: widget.textColor.withOpacity(0.8))),
                    ),
                    Switch(
                      value: _autoStart,
                      activeColor: AppColors.techBlue,
                      onChanged: (v) => setState(() => _autoStart = v),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('语速',
                    style: TextStyle(
                        color: widget.textColor, fontWeight: FontWeight.w700)),
                Slider(
                  value: _rate,
                  min: 0.6,
                  max: 1.6,
                  divisions: 10,
                  activeColor: AppColors.techBlue,
                  label: _rate.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _rate = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageTextSettingsPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;

  const _ImageTextSettingsPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
  });

  @override
  State<_ImageTextSettingsPanel> createState() =>
      _ImageTextSettingsPanelState();
}

class _ImageTextSettingsPanelState extends State<_ImageTextSettingsPanel> {
  bool _showCaptions = true;
  double _density = 0.5;

  @override
  Widget build(BuildContext context) {
    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    return SingleChildScrollView(
      key: const PageStorageKey('ai_hud_image_text_scroll'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        children: [
          Container(
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
                Text('图文展示',
                    style: TextStyle(
                        color: widget.textColor, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text('显示图注/说明',
                          style: TextStyle(
                              color: widget.textColor.withOpacity(0.8))),
                    ),
                    Switch(
                      value: _showCaptions,
                      activeColor: AppColors.techBlue,
                      onChanged: (v) => setState(() => _showCaptions = v),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('图文密度',
                    style: TextStyle(
                        color: widget.textColor, fontWeight: FontWeight.w700)),
                Slider(
                  value: _density,
                  min: 0,
                  max: 1,
                  divisions: 5,
                  activeColor: AppColors.techBlue,
                  label: _density.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _density = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlossaryPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;

  const _GlossaryPanel({
    super.key,
    required this.isDark,
    required this.bgColor,
    required this.textColor,
  });

  @override
  State<_GlossaryPanel> createState() => _GlossaryPanelState();
}

class _GlossaryPanelState extends State<_GlossaryPanel> {
  final TextEditingController _searchCtl = TextEditingController();
  final TextEditingController _srcCtl = TextEditingController();
  final TextEditingController _dstCtl = TextEditingController();

  GlossaryTerm? _editing;

  @override
  void dispose() {
    _searchCtl.dispose();
    _srcCtl.dispose();
    _dstCtl.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _editing = null;
      _srcCtl.text = '';
      _dstCtl.text = '';
    });
  }

  void _startEdit(GlossaryTerm term) {
    setState(() {
      _editing = term;
      _srcCtl.text = term.source;
      _dstCtl.text = term.target;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = null;
      _srcCtl.text = '';
      _dstCtl.text = '';
    });
  }

  Future<void> _save(TranslationProvider provider) async {
    final src = _srcCtl.text.trim();
    final dst = _dstCtl.text.trim();
    if (src.isEmpty || dst.isEmpty) return;

    await provider.upsertGlossaryTerm(GlossaryTerm(source: src, target: dst));
    if (!mounted) return;
    _cancelEdit();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TranslationProvider>();
    final terms = provider.glossaryTerms;

    final Color cardBg =
        widget.isDark ? Colors.white.withOpacity(0.07) : AppColors.mistWhite;

    final query = _searchCtl.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? terms
        : terms
            .where((t) =>
                t.source.toLowerCase().contains(query) ||
                t.target.toLowerCase().contains(query))
            .toList();

    Widget listBody;
    if (terms.isEmpty) {
      listBody = Center(
        child: Text(
          '暂无术语，建议从人物/地名/组织名开始添加。',
          style: TextStyle(color: widget.textColor.withOpacity(0.55)),
        ),
      );
    } else if (filtered.isEmpty) {
      listBody = Center(
        child: Text(
          '未找到匹配项',
          style: TextStyle(color: widget.textColor.withOpacity(0.55)),
        ),
      );
    } else {
      listBody = ListView.separated(
        key: const PageStorageKey('ai_hud_glossary_list'),
        shrinkWrap: true,
        itemCount: filtered.length,
        separatorBuilder: (_, __) =>
            Divider(color: widget.textColor.withOpacity(0.08)),
        itemBuilder: (context, i) {
          final t = filtered[i];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              t.source,
              style: TextStyle(
                color: widget.textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              t.target,
              style: TextStyle(
                color: widget.textColor.withOpacity(0.7),
                height: 1.3,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '编辑',
                  icon: Icon(Icons.edit,
                      color: widget.textColor.withOpacity(0.75)),
                  onPressed: () => _startEdit(t),
                ),
                IconButton(
                  tooltip: '删除',
                  icon:
                      const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () => provider.removeGlossaryTerm(t.source),
                ),
              ],
            ),
          );
        },
      );
    }

    final maxListHeight =
        (MediaQuery.of(context).size.height * 0.38).clamp(180.0, 360.0);

    return Column(
      key: widget.key,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
                color: widget.textColor.withOpacity(0.08),
                width: AppTokens.stroke),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '术语表',
                      style: TextStyle(
                          color: widget.textColor, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '用于固定专有名词译法（源术语 → 目标术语）。当前共 ${terms.length} 条。',
                      style: TextStyle(
                        color: widget.textColor.withOpacity(0.65),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _startAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.techBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
                color: widget.textColor.withOpacity(0.08),
                width: AppTokens.stroke),
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _searchCtl,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: '搜索源术语 / 目标术语',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              if (_editing != null ||
                  _srcCtl.text.isNotEmpty ||
                  _dstCtl.text.isNotEmpty) ...[
                const SizedBox(height: 10),
                _editor(provider),
              ],
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxListHeight),
                child: listBody,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _editor(TranslationProvider provider) {
    final isEditing = _editing != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.textColor.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEditing ? '编辑术语' : '新增术语',
            style:
                TextStyle(color: widget.textColor, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _srcCtl,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '源术语',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _dstCtl,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '目标术语',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cancelEdit,
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _save(provider),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.techBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                  ),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _QaRole { user, assistant }

class _QaMsg {
  final _QaRole role;
  final String text;
  final String? reasoningText;
  const _QaMsg(this.role, this.text, [this.reasoningText]);

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'text': text,
        'reasoningText': reasoningText,
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
      json['reasoningText']?.toString(),
    );
  }
}



enum _MessageState {
  idle,
  thinking,
  reasoning,
  answering,
}

class _QaPanel extends StatefulWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
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
      '你好，我是Air！你的AI伴读助手，我可以回答基于当前阅读内容的问题，来问我吧';
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final List<_QaMsg> _messages = [];
  final Set<int> _collapsedReasoning = {};
  Timer? _persistTimer;
  int? _activeReplyIndex;
  _MessageState _messageState = _MessageState.idle;
  StreamSubscription<QAStreamChunk>? _streamSub;

  // Throttling for web setState
  Timer? _updateTimer;
  bool _needsUiUpdate = false;
  bool _shouldScrollToBottom = false;

  String get _historyKey => 'qa_history_${widget.bookId}';

  @override
  void initState() {
    super.initState();
    _loadHistory();
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

    if (mounted) setState(() {});
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
    final items = _messages
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
      _messages
        ..clear()
        ..add(const _QaMsg(
          _QaRole.assistant,
          _kWelcomeMessage,
        ));
      _collapsedReasoning.clear();
      _messageState = _MessageState.idle;
      _activeReplyIndex = null;
    });
    _streamSub?.cancel();
    _schedulePersist();
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
            Timer(const Duration(milliseconds: 100), _throttledUpdate);
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

  void _fillPrompt(String prompt) {
    setState(() {
      _inputCtl.text = prompt;
      _inputCtl.selection = TextSelection.fromPosition(
        TextPosition(offset: _inputCtl.text.length),
      );
    });
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
    String reasoningBuffer = '';

    try {
      final aiModel = context.read<AiModelProvider>();
      if (aiModel.source == AiModelSource.none) {
        throw Exception('请先选择本地或在线大模型');
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
        isLocalModel: aiModel.source == AiModelSource.local,
        qaType: qaType,
        history: history,
      );

      _streamSub?.cancel();

      _streamSub = stream.listen(
        (QAStreamChunk chunk) {
          if (!mounted) return;

          if (_activeReplyIndex == null) {
            // First chunk, add assistant message
            setState(() {
              _messages.add(const _QaMsg(_QaRole.assistant, ''));
              _activeReplyIndex = _messages.length - 1;
              if (chunk.isReasoning) {
                _messageState = _MessageState.reasoning;
              } else {
                _messageState = _MessageState.answering;
              }
            });
          }
          final replyIndex = _activeReplyIndex!;

          if (chunk.isReasoning && chunk.reasoningContent != null) {
            reasoningBuffer += chunk.reasoningContent!;
            final current = _messages[replyIndex];
            _updateMessage(
                replyIndex, _QaMsg(current.role, current.text, reasoningBuffer));
          } else if (chunk.content.isNotEmpty) {
            if (_messageState != _MessageState.answering) {
              setState(() {
                _messageState = _MessageState.answering;
              });
            }
            final current = _messages[replyIndex];
            _updateMessage(
                replyIndex,
                _QaMsg(current.role, current.text + chunk.content,
                    current.reasoningText));
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
          setState(() {
            _messageState = _MessageState.idle;
            _activeReplyIndex = null;
            if (replyIndex != null && reasoningBuffer.trim().isNotEmpty) {
              _collapsedReasoning.add(replyIndex);
            }
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

    Widget _actionChip({
      required String label,
      required VoidCallback? onTap,
    }) {
      final bool disabled = onTap == null;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: disabled
                  ? AppColors.techBlue.withOpacity(0.4)
                  : AppColors.techBlue,
              fontWeight: FontWeight.w600,
            ),
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
                  final bool isUser = m.role == _QaRole.user;
                  final Color bubbleBg = isUser
                      ? AppColors.techBlue.withOpacity(0.18)
                      : widget.textColor.withOpacity(0.06);
                  final Alignment align =
                      isUser ? Alignment.centerRight : Alignment.centerLeft;

                  if (!isUser &&
                      ((m.reasoningText != null &&
                              m.reasoningText!.isNotEmpty) ||
                          (_activeReplyIndex == i &&
                              _messageState == _MessageState.reasoning))) {
                    final bool isActive = _activeReplyIndex == i;
                    final bool collapsed =
                        !isActive && _collapsedReasoning.contains(i);
                    final reasoningText = m.reasoningText ?? '';

                    Widget reasoningBox = const SizedBox.shrink();
                    if (reasoningText.isNotEmpty ||
                        (isActive &&
                            _messageState == _MessageState.reasoning)) {
                      reasoningBox = Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        constraints: const BoxConstraints(maxWidth: 340),
                        decoration: BoxDecoration(
                          color: widget.textColor.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.textColor.withOpacity(0.06),
                            width: AppTokens.stroke,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '深度思考',
                                  style: TextStyle(
                                    color: widget.textColor
                                        .withOpacity(0.75),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                if (!isActive)
                                  InkWell(
                                    onTap: () {
                                      setState(() {
                                        if (collapsed) {
                                          _collapsedReasoning.remove(i);
                                        } else {
                                          _collapsedReasoning.add(i);
                                        }
                                      });
                                    },
                                    child: Text(
                                      collapsed ? '展开' : '收起',
                                      style: TextStyle(
                                        color: AppColors.techBlue,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (collapsed)
                              Text(
                                '已折叠',
                                style: TextStyle(
                                  color: widget.textColor.withOpacity(0.55),
                                  fontSize: 12,
                                ),
                              )
                            else
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxHeight: 120),
                                child: SingleChildScrollView(
                                  child: Text(
                                    reasoningText,
                                    style: TextStyle(
                                      color: widget.textColor
                                          .withOpacity(0.75),
                                      height: 1.35,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }

                    Widget answerBox = const SizedBox.shrink();
                    if (m.text.isNotEmpty ||
                        (_activeReplyIndex == i &&
                            _messageState == _MessageState.answering)) {
                      answerBox = Container(
                        margin: const EdgeInsets.symmetric(vertical: 0),
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
                        child: Text(
                          m.text.isEmpty ? '...' : m.text,
                          style: TextStyle(
                            color: widget.textColor,
                            height: 1.35,
                            fontSize: 13,
                          ),
                        ),
                      );
                    }

                    return Align(
                      key: ValueKey(
                          'qa_msg_${i}_${m.text.hashCode}_${m.reasoningText?.hashCode ?? 0}'),
                      alignment: align,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          reasoningBox,
                          answerBox,
                        ],
                      ),
                    );
                  }

                  // Default bubble (user messages or assistant messages without reasoning)
                  return Align(
                    key: ValueKey(
                        'qa_msg_${i}_${m.text.hashCode}_${m.reasoningText?.hashCode ?? 0}'),
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
                      child: Text(
                        m.text.isEmpty && _activeReplyIndex == i
                            ? '...'
                            : m.text,
                        style: TextStyle(
                          color: widget.textColor,
                          height: 1.35,
                          fontSize: 13,
                        ),
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
                  child: Text('深度思考中...',
                      style: TextStyle(
                          color: widget.textColor.withOpacity(0.6),
                          fontSize: 13)),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _actionChip(
                  label: '新话题',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : _startNewTopic,
                ),
                _actionChip(
                  label: '总结本章',
                  onTap: _messageState != _MessageState.idle
                      ? null
                      : () => _sendQuickAction(QAType.summary),
                ),
                _actionChip(
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
                          !ServicesBinding
                              .instance.keyboard.logicalKeysPressed
                              .contains(LogicalKeyboardKey.shiftLeft) &&
                          !ServicesBinding
                              .instance.keyboard.logicalKeysPressed
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

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.transparent,
      body: panelContent,
    );
  }
}

Widget _badge(String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.techBlue.withOpacity(0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
          color: AppColors.techBlue.withOpacity(0.35), width: AppTokens.stroke),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: AppColors.techBlue,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
