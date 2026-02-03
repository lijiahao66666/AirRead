import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/link_discovery_provider.dart';
import '../../widgets/glass_panel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_tokens.dart';

class LinkDiscoveryTestPage extends StatefulWidget {
  const LinkDiscoveryTestPage({super.key});

  @override
  State<LinkDiscoveryTestPage> createState() => _LinkDiscoveryTestPageState();
}

class _LinkDiscoveryTestPageState extends State<LinkDiscoveryTestPage> {
  final TextEditingController _queryController = TextEditingController();
  final TextEditingController _urlsController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    _urlsController.dispose();
    super.dispose();
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LinkDiscoveryProvider>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_queryController.text != provider.query) {
      _queryController.text = provider.query;
      _queryController.selection =
          TextSelection.collapsed(offset: _queryController.text.length);
    }
    if (_urlsController.text != provider.rawUrlsInput) {
      _urlsController.text = provider.rawUrlsInput;
      _urlsController.selection =
          TextSelection.collapsed(offset: _urlsController.text.length);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('链接聚合测试'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: provider.isLabeling ? null : () => provider.labelWithAi(),
            icon: provider.isLabeling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            tooltip: 'AI 标注',
          ),
          IconButton(
            onPressed: provider.buildCandidates,
            icon: const Icon(Icons.refresh),
            tooltip: '生成链接',
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFF0E1418), AppColors.nightBg]
                : const [AppColors.airBlue, AppColors.mistWhite],
            stops: const [0.0, 0.3],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    GlassPanel(
                      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                      child: TextField(
                        controller: _queryController,
                        decoration: const InputDecoration(
                          hintText: '输入书名/作者/ISBN，用于生成合规跳转链接',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onChanged: (v) => context
                            .read<LinkDiscoveryProvider>()
                            .setQuery(v),
                        onSubmitted: (_) =>
                            context.read<LinkDiscoveryProvider>().buildCandidates(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    GlassPanel(
                      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                      child: TextField(
                        controller: _urlsController,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText:
                              '粘贴任意网页链接（可多行/混合文本），用于分组与风险标注',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (v) => context
                            .read<LinkDiscoveryProvider>()
                            .setRawUrlsInput(v),
                      ),
                    ),
                    if (provider.labelError != null) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          provider.labelError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: provider.buildCandidates,
                            child: const Text('生成/解析链接'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: provider.isLabeling
                                ? null
                                : () => provider.labelWithAi(),
                            child: const Text('AI 标注'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: provider.candidates.length,
                  itemBuilder: (context, index) {
                    final c = provider.candidates[index];
                    final riskColor = switch (c.risk) {
                      LinkRiskLevel.low => Colors.green,
                      LinkRiskLevel.medium => Colors.orange,
                      LinkRiskLevel.high => Colors.red,
                    };
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: riskColor.withAlpha(60),
                        child: Icon(
                          Icons.link,
                          size: 16,
                          color: riskColor,
                        ),
                      ),
                      title: Text(c.title),
                      subtitle: Text(
                        c.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () async => _openExternalUrl(c.url),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

