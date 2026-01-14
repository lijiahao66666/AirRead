import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../providers/translation_provider.dart';
import '../../../widgets/glass_panel.dart';
import '../../../../ai/translation/translation_types.dart';

class AiSettingsSheet extends StatelessWidget {
  final Color bgColor;
  final Color textColor;

  final VoidCallback onOpenTranslationSettings;

  const AiSettingsSheet({
    super.key,
    required this.bgColor,
    required this.textColor,
    required this.onOpenTranslationSettings,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TranslationProvider>();
    final cfg = provider.config;

    String displayModeLabel(TranslationDisplayMode mode) {
      switch (mode) {
        case TranslationDisplayMode.translationOnly:
          return '仅译文';
        case TranslationDisplayMode.bilingual:
          return '双语';
      }
    }

    final subtitle = '${cfg.targetLang} · ${displayModeLabel(cfg.displayMode)}';

    return GlassPanel.sheet(
      surfaceColor: bgColor,
      opacity: AppTokens.glassOpacityDense,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.62,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, color: AppColors.techBlue),
                    const SizedBox(width: 8),
                    Text(
                      'AI设置',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: textColor.withOpacity(0.7)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                _sectionTitle('翻译'),
                const SizedBox(height: 8),
                _tile(
                  context,
                  title: '翻译设置',
                  subtitle: subtitle,
                  trailing: Icon(Icons.chevron_right, color: textColor.withOpacity(0.6)),
                  onTap: () {
                    Navigator.pop(context);
                    onOpenTranslationSettings();
                  },
                ),


                const SizedBox(height: 16),
                _sectionTitle('总结'),
                const SizedBox(height: 8),
                _tile(
                  context,
                  title: '总结范围',
                  subtitle: '本章开头 → 当前阅读位置',
                  trailing: Icon(Icons.info_outline, color: textColor.withOpacity(0.45)),
                  onTap: null,
                ),

                const SizedBox(height: 16),
                _sectionTitle('图文 / 朗读 / 问答'),
                const SizedBox(height: 8),
                _tile(
                  context,
                  title: '图文设置',
                  subtitle: '占位版：先做结构与样式，后续接入生图',
                  trailing: Icon(Icons.lock_outline, color: textColor.withOpacity(0.35)),
                  onTap: null,
                ),
                _tile(
                  context,
                  title: '朗读设置',
                  subtitle: '音色/语速等（待接入）',
                  trailing: Icon(Icons.lock_outline, color: textColor.withOpacity(0.35)),
                  onTap: null,
                ),

                const Spacer(),
                Text(
                  '提示：翻译开关请在 AI 伴读主面板控制。',
                  style: TextStyle(color: textColor.withOpacity(0.6), fontSize: 12),
                )

              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        color: textColor.withOpacity(0.7),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: (bgColor.computeLuminance() < 0.5)
              ? Colors.white.withOpacity(0.06)
              : AppColors.mistWhite,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          border: Border.all(
            color: textColor.withOpacity(0.06),
            width: AppTokens.stroke,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: textColor.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }
}
