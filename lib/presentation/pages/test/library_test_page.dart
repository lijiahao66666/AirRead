import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/library_test_provider.dart';
import '../../widgets/glass_panel.dart';
import 'link_discovery_test_page.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_tokens.dart';

class LibraryTestPage extends StatefulWidget {
  const LibraryTestPage({super.key});

  @override
  State<LibraryTestPage> createState() => _LibraryTestPageState();
}

class _LibraryTestPageState extends State<LibraryTestPage> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _opdsController = TextEditingController();

  void _handleSearch() {
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      context.read<LibraryTestProvider>().search(query);
    }
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _showLinksSheet({
    required String title,
    required Map<String, String> downloadUrls,
  }) {
    final entries = downloadUrls.entries.toList();
    int weight(String k) {
      switch (k.toLowerCase()) {
        case 'epub':
          return 0;
        case 'txt':
          return 1;
        default:
          return 9;
      }
    }

    entries.sort((a, b) {
      final wa = weight(a.key);
      final wb = weight(b.key);
      if (wa != wb) return wa.compareTo(wb);
      return a.key.compareTo(b.key);
    });

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (entries.isEmpty)
                  const Text('没有可用链接')
                else
                  ...entries.map(
                    (e) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(e.key.toUpperCase()),
                      subtitle: Text(
                        e.value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () async {
                        Navigator.of(ctx).pop();
                        await _openExternalUrl(e.value);
                      },
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
  void dispose() {
    _searchController.dispose();
    _opdsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final testProvider = context.watch<LibraryTestProvider>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    if (_opdsController.text.isEmpty && testProvider.opdsUrl.isNotEmpty) {
      _opdsController.text = testProvider.opdsUrl;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          testProvider.source == LibraryOnlineSource.opds
              ? '在线书库搜索测试 (OPDS)'
              : '公版书库搜索测试 (Gutendex)',
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.travel_explore),
            tooltip: '链接聚合测试',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const LinkDiscoveryTestPage()),
              );
            },
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
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            DropdownButtonHideUnderline(
                              child: DropdownButton<LibraryOnlineSource>(
                                value: testProvider.source,
                                items: const [
                                  DropdownMenuItem(
                                    value: LibraryOnlineSource.gutendex,
                                    child: Text('Gutendex'),
                                  ),
                                  DropdownMenuItem(
                                    value: LibraryOnlineSource.opds,
                                    child: Text('OPDS'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    context
                                        .read<LibraryTestProvider>()
                                        .setSource(v);
                                  }
                                },
                              ),
                            ),
                            const Spacer(),
                            if (testProvider.source == LibraryOnlineSource.opds)
                              Text(
                                '支持 {searchTerms} 模板',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color
                                      ?.withAlpha(179),
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (testProvider.source == LibraryOnlineSource.opds) ...[
                      const SizedBox(height: 10),
                      GlassPanel(
                        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                        child: TextField(
                          controller: _opdsController,
                          decoration: const InputDecoration(
                            hintText: 'OPDS 目录或搜索模板 URL',
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 16),
                          ),
                          onChanged: (v) {
                            context.read<LibraryTestProvider>().setOpdsUrl(v);
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: GlassPanel(
                            borderRadius:
                                BorderRadius.circular(AppTokens.radiusMd),
                            child: TextField(
                              controller: _searchController,
                              decoration: const InputDecoration(
                                hintText: '搜索书名、作者...',
                                border: InputBorder.none,
                                contentPadding:
                                    EdgeInsets.symmetric(horizontal: 16),
                              ),
                              onSubmitted: (_) => _handleSearch(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _handleSearch,
                          icon: const Icon(Icons.search),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: testProvider.isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : testProvider.searchError != null
                        ? Center(child: Text(testProvider.searchError!))
                        : ListView.builder(
                            itemCount: testProvider.searchResults.length,
                            itemBuilder: (context, index) {
                              final book = testProvider.searchResults[index];

                              return ListTile(
                                leading: book.coverUrl != null
                                    ? Image.network(book.coverUrl!,
                                        width: 40,
                                        height: 60,
                                        fit: BoxFit.cover)
                                    : const Icon(Icons.book),
                                title: Text(book.title),
                                subtitle: Text(book.authors.join(', ')),
                                trailing: IconButton(
                                  icon: const Icon(Icons.open_in_new),
                                  onPressed: book.downloadUrls.isEmpty
                                      ? null
                                      : () {
                                          _showLinksSheet(
                                            title: book.title,
                                            downloadUrls: book.downloadUrls,
                                          );
                                        },
                                ),
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
