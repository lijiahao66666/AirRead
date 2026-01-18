import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../widgets/glass_panel.dart';
import '../../../providers/translation_provider.dart';
import '../../../../ai/translation/translation_types.dart';

/// Translation settings sheet.
///
/// Note: In this app the "apply translation to reader" switch is controlled from
/// the AI companion main panel. This sheet focuses on configuration.
class TranslationSheet extends StatelessWidget {
  final Color bgColor;
  final Color textColor;

  const TranslationSheet({
    super.key,
    required this.bgColor,
    required this.textColor,
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

    final panelBg = bgColor;
    final panelText = textColor;

    return GlassPanel.sheet(
      surfaceColor: panelBg,
      opacity: AppTokens.glassOpacityDense,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.translate, color: AppColors.techBlue),
                    const SizedBox(width: 8),
                    Text(
                      '翻译设置',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: panelText,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon:
                          Icon(Icons.close, color: panelText.withOpacity(0.7)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildCard(
                  panelBg: panelBg,
                  panelText: panelText,
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
                              textColor: panelText,
                              dropdownColor: panelBg,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _dropdown(
                              label: '目标语言（必选）',
                              value: cfg.targetLang,
                              items: Map<String, String>.from(_langs)
                                ..remove(''),
                              onChanged: (v) =>
                                  provider.setTargetLang(v ?? 'en'),
                              textColor: panelText,
                              dropdownColor: panelBg,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '显示模式',
                        style: TextStyle(
                            color: panelText, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        children: [
                          _chip(
                            label: '仅显示译文',
                            active: cfg.displayMode ==
                                TranslationDisplayMode.translationOnly,
                            onTap: () => provider.setDisplayMode(
                                TranslationDisplayMode.translationOnly),
                            textColor: panelText,
                          ),
                          _chip(
                            label: '双语对照',
                            active: cfg.displayMode ==
                                TranslationDisplayMode.bilingual,
                            onTap: () => provider.setDisplayMode(
                                TranslationDisplayMode.bilingual),
                            textColor: panelText,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '提示：翻译是否在正文中生效，请在“AI伴读”主面板开启/关闭。',
                        style: TextStyle(
                          color: panelText.withOpacity(0.65),
                          fontSize: 12,
                          height: 1.4,
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
    );
  }

  static Widget _buildCard({
    required Color panelBg,
    required Color panelText,
    required Widget child,
  }) {
    final isDark = panelBg.computeLuminance() < 0.5;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.06) : AppColors.mistWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: panelText.withOpacity(0.06), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  static Widget _chip({
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

  static Widget _dropdown({
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
            style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SizedBox(
          height: 48,
          child: DropdownButtonFormField<String>(
            value: items.containsKey(value) ? value : items.keys.first,
            dropdownColor: dropdownColor,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
}
