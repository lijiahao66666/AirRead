import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../widgets/glass_panel.dart';
import '../../../providers/translation_provider.dart';
import '../../../../ai/translation/glossary.dart';
import '../../../../ai/translation/translation_types.dart';

class TranslationSheet extends StatefulWidget {
  final Color bgColor;
  final Color textColor;

  /// Paragraphs to translate for current page: paragraphIndex -> text.
  final Map<int, String> paragraphsByIndex;

  const TranslationSheet({
    super.key,
    required this.bgColor,
    required this.textColor,
    required this.paragraphsByIndex,
  });

  @override
  State<TranslationSheet> createState() => _TranslationSheetState();
}

class _TranslationSheetState extends State<TranslationSheet> {
  Map<int, String>? _results;
  String? _error;
  bool _isTranslating = false;

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

    final panelBg = widget.bgColor;
    final panelText = widget.textColor;

    return GlassPanel.sheet(
      surfaceColor: panelBg,
      opacity: AppTokens.glassOpacityDense,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.78,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.translate, color: AppColors.techBlue),
                    const SizedBox(width: 8),
                    Text(
                      '翻译',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: panelText,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: panelText.withOpacity(0.7)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildCard(
                  color: panelBg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '翻译引擎',
                        style: TextStyle(color: panelText, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        children: [
                          _chip(
                            label: '机器翻译',
                            active: cfg.engineType == TranslationEngineType.machine,
                            onTap: () => provider.setEngineType(TranslationEngineType.machine),
                            textColor: panelText,
                          ),
                          _chip(
                            label: 'AI 大模型',
                            active: cfg.engineType == TranslationEngineType.ai,
                            onTap: () => provider.setEngineType(TranslationEngineType.ai),
                            textColor: panelText,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _dropdown(
                              label: '源语言（可选）',
                              value: cfg.sourceLang,
                              items: _langs,
                              onChanged: (v) => provider.setSourceLang(v ?? ''),
                              textColor: panelText,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _dropdown(
                              label: '目标语言（必选）',
                              value: cfg.targetLang,
                              items: Map<String, String>.from(_langs)..remove(''),
                              onChanged: (v) => provider.setTargetLang(v ?? 'en'),
                              textColor: panelText,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '显示模式',
                        style: TextStyle(color: panelText, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        children: [
                          _chip(
                            label: '仅显示译文',
                            active: cfg.displayMode == TranslationDisplayMode.translationOnly,
                            onTap: () => provider.setDisplayMode(TranslationDisplayMode.translationOnly),
                            textColor: panelText,
                          ),
                          _chip(
                            label: '双语对照',
                            active: cfg.displayMode == TranslationDisplayMode.bilingual,
                            onTap: () => provider.setDisplayMode(TranslationDisplayMode.bilingual),
                            textColor: panelText,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '在阅读正文中显示',
                              style: TextStyle(color: panelText.withOpacity(0.85)),
                            ),
                          ),
                          Switch(
                            value: provider.applyToReader,
                            activeColor: AppColors.techBlue,
                            onChanged: (v) => provider.setApplyToReader(v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _openGlossaryEditor(context, provider),
                              icon: const Icon(Icons.auto_fix_high, size: 18),
                              label: const Text('术语表'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isTranslating ? null : () => _translateNow(provider),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.techBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              icon: _isTranslating
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.play_arrow, size: 18),
                              label: Text(_isTranslating ? '翻译中…' : '翻译当前页'),
                            ),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (_results != null) ...[
                  Expanded(
                    child: _buildResults(panelBg: panelBg, panelText: panelText, cfg: cfg),
                  ),
                ] else ...[
                  Expanded(
                    child: Center(
                      child: Text(
                        '点击“翻译当前页”生成结果',
                        style: TextStyle(color: panelText.withOpacity(0.5)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResults({
    required Color panelBg,
    required Color panelText,
    required TranslationConfig cfg,
  }) {
    final results = _results!;
    final orderedKeys = results.keys.toList()..sort();

    return _buildCard(
      color: panelBg,
      child: ListView.separated(
        itemCount: orderedKeys.length,
        separatorBuilder: (_, __) => Divider(color: panelText.withOpacity(0.08)),
        itemBuilder: (context, i) {
          final idx = orderedKeys[i];
          final src = widget.paragraphsByIndex[idx] ?? '';
          final dst = results[idx] ?? '';

          if (cfg.displayMode == TranslationDisplayMode.translationOnly) {
            return Text(dst, style: TextStyle(color: panelText, height: 1.7));
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(src, style: TextStyle(color: panelText, height: 1.7)),
              const SizedBox(height: 8),
              Text(
                dst,
                style: TextStyle(
                  color: panelText.withOpacity(0.75),
                  height: 1.7,
                  fontSize: 14,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _translateNow(TranslationProvider provider) async {
    setState(() {
      _error = null;
      _isTranslating = true;
    });

    try {
      final res = await provider.translateParagraphsByIndex(widget.paragraphsByIndex);
      if (!mounted) return;
      setState(() {
        _results = res;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isTranslating = false;
        });
      }
    }
  }

  Widget _buildCard({required Color color, required Widget child}) {
    final isDark = color.computeLuminance() < 0.5;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.06) : AppColors.mistWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withOpacity(0.03)),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
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
          color: active ? AppColors.techBlue.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppColors.techBlue : textColor.withOpacity(0.18),
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
        Text(label, style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: items.containsKey(value) ? value : items.keys.first,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

  Future<void> _openGlossaryEditor(BuildContext context, TranslationProvider provider) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (_) => _GlossaryEditor(
        bgColor: widget.bgColor,
        textColor: widget.textColor,
      ),
    );
  }
}

class _GlossaryEditor extends StatelessWidget {
  final Color bgColor;
  final Color textColor;

  const _GlossaryEditor({
    required this.bgColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TranslationProvider>();
    final terms = provider.glossaryTerms;

    return GlassPanel.sheet(
      surfaceColor: bgColor,
      opacity: AppTokens.glassOpacityDense,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.78,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_fix_high, color: AppColors.techBlue),
                    const SizedBox(width: 8),
                    Text(
                      '术语表',
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '为保证术语一致性，建议添加专有名词映射（源术语 -> 目标术语）。',
                        style: TextStyle(
                          color: textColor.withOpacity(0.65),
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () => _addOrEdit(context, provider, null),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新增'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.techBlue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (terms.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('暂无术语', style: TextStyle(color: textColor.withOpacity(0.5))),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: terms.length,
                      separatorBuilder: (_, __) => Divider(color: textColor.withOpacity(0.08)),
                      itemBuilder: (context, i) {
                        final t = terms[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${t.source}  →  ${t.target}', style: TextStyle(color: textColor)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(Icons.edit, color: textColor.withOpacity(0.7)),
                                onPressed: () => _addOrEdit(context, provider, t),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () => provider.removeGlossaryTerm(t.source),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _addOrEdit(
    BuildContext context,
    TranslationProvider provider,
    GlossaryTerm? existing,
  ) async {
    final srcCtl = TextEditingController(text: existing?.source ?? '');
    final dstCtl = TextEditingController(text: existing?.target ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(existing == null ? '新增术语' : '编辑术语'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: srcCtl,
                decoration: const InputDecoration(labelText: '源术语'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: dstCtl,
                decoration: const InputDecoration(labelText: '目标术语'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (ok == true) {
      final src = srcCtl.text.trim();
      final dst = dstCtl.text.trim();
      if (src.isEmpty || dst.isEmpty) return;
      await provider.upsertGlossaryTerm(GlossaryTerm(source: src, target: dst));
    }
  }
}


