import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../widgets/glass_panel.dart';
import '../../../providers/translation_provider.dart';
import '../../../../ai/translation/glossary.dart';
import '../../../../ai/translation/translation_types.dart';

/// Translation settings sheet.
///
/// Note: In this app the "apply translation to reader" switch is controlled from
/// the AI companion main panel. This sheet focuses on configuration + glossary.
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
                      icon: Icon(Icons.close, color: panelText.withOpacity(0.7)),
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
                      Text(
                        '提示：翻译是否在正文中生效，请在“AI伴读”主面板开启/关闭。',
                        style: TextStyle(
                          color: panelText.withOpacity(0.65),
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _openGlossaryEditor(context),
                          icon: const Icon(Icons.auto_fix_high, size: 18),
                          label: const Text('术语表'),
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
        border: Border.all(color: panelText.withOpacity(0.06), width: AppTokens.stroke),
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
          color: active ? AppColors.techBlue.withOpacity(0.12) : Colors.transparent,
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

  Future<void> _openGlossaryEditor(BuildContext context) async {
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
        bgColor: bgColor,
        textColor: textColor,
      ),
    );
  }
}

class _GlossaryEditor extends StatefulWidget {
  final Color bgColor;
  final Color textColor;

  const _GlossaryEditor({
    required this.bgColor,
    required this.textColor,
  });

  @override
  State<_GlossaryEditor> createState() => _GlossaryEditorState();
}

class _GlossaryEditorState extends State<_GlossaryEditor> {
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

    final query = _searchCtl.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? terms
        : terms
            .where((t) =>
                t.source.toLowerCase().contains(query) || t.target.toLowerCase().contains(query))
            .toList();

    return GlassPanel.sheet(
      surfaceColor: widget.bgColor,
      opacity: AppTokens.glassOpacityDense,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.78,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
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
                        color: widget.textColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: widget.textColor.withOpacity(0.7)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '为保证术语一致性，建议添加专有名词映射（源术语 → 目标术语）。',
                        style: TextStyle(
                          color: widget.textColor.withOpacity(0.65),
                          fontSize: 12,
                          height: 1.4,
                        ),
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
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchCtl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: '搜索源术语 / 目标术语',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                if (_editing != null || _srcCtl.text.isNotEmpty || _dstCtl.text.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _editor(provider),
                ],
                const SizedBox(height: 12),
                if (terms.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text('暂无术语', style: TextStyle(color: widget.textColor.withOpacity(0.5))),
                    ),
                  )
                else if (filtered.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text('未找到匹配项', style: TextStyle(color: widget.textColor.withOpacity(0.5))),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Divider(color: widget.textColor.withOpacity(0.08)),
                      itemBuilder: (context, i) {
                        final t = filtered[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            t.source,
                            style: TextStyle(color: widget.textColor, fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            t.target,
                            style: TextStyle(color: widget.textColor.withOpacity(0.7), height: 1.3),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(Icons.edit, color: widget.textColor.withOpacity(0.7)),
                                onPressed: () => _startEdit(t),
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

  Widget _editor(TranslationProvider provider) {
    final isEditing = _editing != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.textColor.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.textColor.withOpacity(0.08), width: AppTokens.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEditing ? '编辑术语' : '新增术语',
            style: TextStyle(color: widget.textColor, fontWeight: FontWeight.w700),
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

