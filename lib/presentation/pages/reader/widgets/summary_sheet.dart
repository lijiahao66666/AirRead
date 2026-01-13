import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../ai/summarize/summarize_service.dart';
import '../../../widgets/glass_panel.dart';

class SummarySheet extends StatefulWidget {
  final Color bgColor;
  final Color textColor;
  final String content;

  const SummarySheet({
    super.key,
    required this.bgColor,
    required this.textColor,
    required this.content,
  });

  @override
  State<SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends State<SummarySheet> {
  final SummarizeService _service = SummarizeService();

  String? _result;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final r = await _service.summarizeToChinese(text: widget.content);
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final panelBg = widget.bgColor;
    final panelText = widget.textColor;

    return GlassPanel.sheet(
      surfaceColor: panelBg,
      opacity: AppTokens.glassOpacityDense,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.70,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.summarize, color: AppColors.techBlue),
                    const SizedBox(width: 8),
                    Text(
                      '总结（截至当前页）',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: panelText,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _loading ? null : _run,
                      icon: Icon(Icons.refresh, color: panelText.withOpacity(0.7)),
                    ),
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
                  child: Row(
                    children: [
                      Icon(Icons.article_outlined, size: 16, color: panelText.withOpacity(0.55)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '范围：本章开头 → 当前阅读位置',
                          style: TextStyle(color: panelText.withOpacity(0.75), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                Expanded(
                  child: _buildBody(panelBg: panelBg, panelText: panelText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody({required Color panelBg, required Color panelText}) {
    if (_loading && _result == null) {
      return Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text('正在生成总结…', style: TextStyle(color: panelText.withOpacity(0.6))),
          ],
        ),
      );
    }

    if (_error != null) {
      return _buildCard(
        panelBg: panelBg,
        panelText: panelText,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('生成失败', style: TextStyle(color: panelText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: panelText.withOpacity(0.65), fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _run,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.techBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                ),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ),
          ],
        ),
      );
    }

    final text = _result;
    if (text == null || text.trim().isEmpty) {
      return Center(
        child: Text(
          '暂无总结内容',
          style: TextStyle(color: panelText.withOpacity(0.5)),
        ),
      );
    }

    return _buildCard(
      panelBg: panelBg,
      panelText: panelText,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: SelectableText(
          text,
          style: TextStyle(color: panelText, height: 1.6, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildCard({
    required Color panelBg,
    required Color panelText,
    required Widget child,
  }) {
    final bool isDark = panelBg.computeLuminance() < 0.5;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.06) : AppColors.mistWhite,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: panelText.withOpacity(0.06), width: AppTokens.stroke),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}
