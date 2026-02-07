import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/reading/qa_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../providers/ai_model_provider.dart';
import '../providers/illustration_provider.dart';
import '../providers/qa_stream_provider.dart';
import '../providers/translation_provider.dart';
import 'illustration_panel.dart';

enum AiHudRoute {
  main,
  qa,
  illustration,
}

class AiHud extends StatefulWidget {
  final Color bgColor;
  final Color textColor;
  final String bookId;
  final String chapterId;
  final String chapterTitle;
  final String chapterContent;

  final AiHudRoute initialRoute;
  final String? initialQaText;
  final bool autoSendInitialQa;

  final String? initialIllustrationText;
  final bool autoGenerateIllustration;

  const AiHud({
    super.key,
    required this.bgColor,
    required this.textColor,
    required this.bookId,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterContent,
    this.initialRoute = AiHudRoute.main,
    this.initialQaText,
    this.autoSendInitialQa = false,
    this.initialIllustrationText,
    this.autoGenerateIllustration = false,
  });

  @override
  State<AiHud> createState() => _AiHudState();
}

class _AiHudState extends State<AiHud> {
  late AiHudRoute _route;
  final TextEditingController _qaController = TextEditingController();
  QAType _qaType = QAType.general;
  bool _initialQaConsumed = false;
  bool _initialIllustrationConsumed = false;

  @override
  void initState() {
    super.initState();
    _route = widget.initialRoute;
    if (widget.initialQaText != null && widget.initialQaText!.trim().isNotEmpty) {
      _qaController.text = widget.initialQaText!.trim();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_initialQaConsumed &&
          widget.autoSendInitialQa &&
          widget.initialQaText != null &&
          widget.initialQaText!.trim().isNotEmpty) {
        _initialQaConsumed = true;
        _route = AiHudRoute.qa;
        setState(() {});
        _sendQa();
      }
      if (!_initialIllustrationConsumed &&
          widget.autoGenerateIllustration &&
          widget.initialIllustrationText != null &&
          widget.initialIllustrationText!.trim().isNotEmpty) {
        _initialIllustrationConsumed = true;
        _route = AiHudRoute.illustration;
        setState(() {});
        context.read<IllustrationProvider>().generateFromSelection(
              chapterId: widget.chapterId,
              selectionText: widget.initialIllustrationText!.trim(),
            );
      }
    });
  }

  @override
  void dispose() {
    _qaController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.bgColor.computeLuminance() < 0.5;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      decoration: BoxDecoration(
        color: widget.bgColor.withOpacityCompat(0.98),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacityCompat(0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _header(isDark: isDark),
            const SizedBox(height: 12),
            Expanded(child: _body(isDark: isDark)),
          ],
        ),
      ),
    );
  }

  Widget _header({required bool isDark}) {
    final title = switch (_route) {
      AiHudRoute.main => 'AI伴读',
      AiHudRoute.qa => '问答',
      AiHudRoute.illustration => '插画灵感',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          if (_route != AiHudRoute.main)
            IconButton(
              onPressed: () => setState(() => _route = AiHudRoute.main),
              icon: Icon(Icons.keyboard_arrow_left_rounded, color: widget.textColor.withOpacityCompat(0.85), size: 28),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            )
          else
            const Icon(Icons.auto_awesome, color: AppColors.techBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: widget.textColor,
              ),
            ),
          ),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: widget.textColor.withOpacityCompat(0.15),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body({required bool isDark}) {
    return switch (_route) {
      AiHudRoute.main => _MainPanel(
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          onOpenQa: () => setState(() => _route = AiHudRoute.qa),
          onOpenIllustration: () => setState(() => _route = AiHudRoute.illustration),
        ),
      AiHudRoute.qa => _QaPanel(
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          bookId: widget.bookId,
          chapterContent: widget.chapterContent,
          controller: _qaController,
          qaType: _qaType,
          onQaTypeChanged: (t) => setState(() => _qaType = t),
          onSend: _sendQa,
        ),
      AiHudRoute.illustration => IllustrationPanel(
          isDark: isDark,
          bgColor: widget.bgColor,
          textColor: widget.textColor,
          bookId: widget.bookId,
          chapterId: widget.chapterId,
          chapterTitle: widget.chapterTitle,
          chapterContent: widget.chapterContent,
        ),
    };
  }

  void _sendQa() {
    final text = _qaController.text.trim();
    if (text.isEmpty) return;
    final aiModel = context.read<AiModelProvider>();
    final qa = context.read<QaStreamProvider>();
    final content = widget.chapterContent;
    final chapterIndex = int.tryParse(widget.chapterId) ?? 0;
    final contextService = ReadingContextService(
      chapterContentCache: {chapterIndex: content},
      currentChapterIndex: chapterIndex,
      currentPageInChapter: 0,
      chapterPageRanges: {
        chapterIndex: [TextRange(start: 0, end: content.length)],
      },
    );
    qa.start(
      bookId: widget.bookId,
      question: text,
      qaType: _qaType,
      aiModel: aiModel,
      contextService: contextService,
    );
  }
}

class _MainPanel extends StatelessWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final VoidCallback onOpenQa;
  final VoidCallback onOpenIllustration;

  const _MainPanel({
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.onOpenQa,
    required this.onOpenIllustration,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<TranslationProvider>();
    final aiModel = context.watch<AiModelProvider>();

    final cardBg = isDark ? Colors.white.withOpacityCompat(0.07) : AppColors.mistWhite;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              border: Border.all(color: textColor.withOpacityCompat(0.08), width: AppTokens.stroke),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.local_fire_department, color: AppColors.techBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '积分：${aiModel.pointsBalance}',
                    style: TextStyle(color: textColor.withOpacityCompat(0.8), fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _switchCard(
            context,
            title: '翻译',
            subtitle: tp.aiTranslateEnabled ? '已开启' : '关闭后不翻译正文',
            value: tp.aiTranslateEnabled,
            onChanged: (v) => tp.setAiTranslateEnabled(v),
            isDark: isDark,
          ),
          const SizedBox(height: 10),
          _switchCard(
            context,
            title: '朗读',
            subtitle: tp.aiReadAloudEnabled ? '已开启' : '开启后可朗读当前章节',
            value: tp.aiReadAloudEnabled,
            onChanged: (v) => tp.setAiReadAloudEnabled(v),
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _entryCard(
                  icon: Icons.question_answer,
                  title: '问答',
                  subtitle: '总结/问答',
                  onTap: onOpenQa,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _entryCard(
                  icon: Icons.palette_rounded,
                  title: '插画',
                  subtitle: '场景具象化',
                  onTap: onOpenIllustration,
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _switchCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool isDark,
  }) {
    final cardBg = isDark ? Colors.white.withOpacityCompat(0.07) : AppColors.mistWhite;
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
          color: value ? AppColors.techBlue.withOpacityCompat(0.55) : textColor.withOpacityCompat(0.08),
          width: AppTokens.stroke,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: textColor.withOpacityCompat(0.6), fontSize: 12)),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.techBlue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    final cardBg = isDark ? Colors.white.withOpacityCompat(0.07) : AppColors.mistWhite;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(color: textColor.withOpacityCompat(0.08), width: AppTokens.stroke),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.techBlue.withOpacityCompat(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: AppColors.techBlue, size: 20),
                ),
                const Spacer(),
                Icon(Icons.chevron_right, color: textColor.withOpacityCompat(0.35), size: 20),
              ],
            ),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: textColor.withOpacityCompat(0.65), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _QaPanel extends StatelessWidget {
  final bool isDark;
  final Color bgColor;
  final Color textColor;
  final String bookId;
  final String chapterContent;
  final TextEditingController controller;
  final QAType qaType;
  final ValueChanged<QAType> onQaTypeChanged;
  final VoidCallback onSend;

  const _QaPanel({
    required this.isDark,
    required this.bgColor,
    required this.textColor,
    required this.bookId,
    required this.chapterContent,
    required this.controller,
    required this.qaType,
    required this.onQaTypeChanged,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<QaStreamProvider>().stateFor(bookId);
    final cardBg = isDark ? Colors.white.withOpacityCompat(0.07) : AppColors.mistWhite;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: textColor.withOpacityCompat(0.08), width: AppTokens.stroke),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    _chip(text: '问答', active: qaType == QAType.general, onTap: () => onQaTypeChanged(QAType.general)),
                    _chip(text: '总结', active: qaType == QAType.summary, onTap: () => onQaTypeChanged(QAType.summary)),
                    _chip(text: '要点', active: qaType == QAType.keyPoints, onTap: () => onQaTypeChanged(QAType.keyPoints)),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: '输入问题或指令…',
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.send_rounded),
                      onPressed: onSend,
                      tooltip: '发送',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: textColor.withOpacityCompat(0.08), width: AppTokens.stroke),
              ),
              padding: const EdgeInsets.all(14),
              child: state == null
                  ? Text('在这里查看回答', style: TextStyle(color: textColor.withOpacityCompat(0.55)))
                  : _qaStateView(state, textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _qaStateView(QaStreamState state, Color textColor) {
    if (state.hasError) {
      return Text(state.error, style: TextStyle(color: Colors.red.withOpacityCompat(0.85)));
    }
    final answer = state.answer.trim().isEmpty && state.isStreaming ? '思考中…' : state.answer;
    return SingleChildScrollView(
      child: Text(
        answer,
        style: TextStyle(color: textColor.withOpacityCompat(0.9), height: 1.5),
      ),
    );
  }

  static Widget _chip({
    required String text,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.techBlue.withOpacityCompat(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppColors.techBlue : AppColors.deepSpace.withOpacityCompat(0.15),
            width: AppTokens.stroke,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: active ? AppColors.techBlue : AppColors.deepSpace.withOpacityCompat(0.75),
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
