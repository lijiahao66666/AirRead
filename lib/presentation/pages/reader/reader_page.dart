import 'dart:convert';

import 'package:epubx/epubx.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../providers/books_provider.dart';
import '../../widgets/ai_hud.dart';
import 'book_bytes_loader.dart';

class ReaderPage extends StatefulWidget {
  final String bookId;

  const ReaderPage({super.key, required this.bookId});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  bool _loading = true;
  String? _error;
  String _content = '';
  String _title = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loading) return;
    _load();
  }

  Future<void> _load() async {
    final books = context.read<BooksProvider>().books;
    final book = books.firstWhere(
      (b) => b.id == widget.bookId,
      orElse: () => throw StateError('Book not found'),
    );

    setState(() {
      _title = book.title;
      _loading = true;
      _error = null;
    });

    try {
      final bytes = await loadBookBytes(book.fileBytes, book.filePath);
      final format = book.format.toLowerCase();
      final text = await _decodeBook(bytes, format);
      if (!mounted) return;
      setState(() {
        _content = text.trim();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<String> _decodeBook(List<int> bytes, String format) async {
    if (format.contains('epub')) {
      final epub = await EpubReader.readBook(bytes);
      final chapters = epub.Chapters ?? const <EpubChapter>[];
      final buffer = StringBuffer();
      for (final ch in chapters) {
        _collectChapterText(ch, buffer);
      }
      return _cleanText(buffer.toString());
    }
    return _cleanText(utf8.decode(bytes, allowMalformed: true));
  }

  void _collectChapterText(EpubChapter chapter, StringBuffer buffer) {
    final title = (chapter.Title ?? '').trim();
    if (title.isNotEmpty) {
      buffer.writeln(title);
      buffer.writeln();
    }
    final html = (chapter.HtmlContent ?? '').trim();
    if (html.isNotEmpty) {
      buffer.writeln(_stripHtml(html));
      buffer.writeln();
    }
    final subs = chapter.SubChapters ?? const <EpubChapter>[];
    for (final sub in subs) {
      _collectChapterText(sub, buffer);
    }
  }

  String _stripHtml(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanText(String s) {
    var out = s.replaceAll('\u0000', '');
    if (out.isNotEmpty && out.codeUnitAt(0) == 0xFEFF) {
      out = out.substring(1);
    }
    return out;
  }

  String? _validateSelectionForIllustration(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return '未选中文本';
    if (clean.length < 12) return '选中内容太短，无法描述画面';
    if (clean.length > 300) return '选中内容过长，建议精简到 300 字以内';
    final hasContent = RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9]').hasMatch(clean);
    if (!hasContent) return '选中内容无效';
    return null;
  }

  Future<void> _openAiHud({
    AiHudRoute initialRoute = AiHudRoute.main,
    String? initialQaText,
    bool autoSendInitialQa = false,
    String? initialIllustrationText,
    bool autoGenerateIllustration = false,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black.withOpacity(0.2),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final isDark = theme.brightness == Brightness.dark;
        final bg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
        final fg = isDark ? Colors.white : AppColors.deepSpace;
        return AiHud(
          bgColor: bg,
          textColor: fg,
          bookId: widget.bookId,
          chapterId: '0',
          chapterTitle: _title,
          chapterContent: _content,
          initialRoute: initialRoute,
          initialQaText: initialQaText,
          autoSendInitialQa: autoSendInitialQa,
          initialIllustrationText: initialIllustrationText,
          autoGenerateIllustration: autoGenerateIllustration,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? AppColors.nightBg : AppColors.airBlue;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: Text(_title.isEmpty ? '阅读' : _title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'AI伴读',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _loading || _content.isEmpty ? null : () => _openAiHud(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null
              ? Center(child: Text(_error!))
              : _buildReaderBody(context)),
    );
  }

  Widget _buildReaderBody(BuildContext context) {
    String selectedText = '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: SelectionArea(
        onSelectionChanged: (value) {
          selectedText = ((value as dynamic)?.plainText as String?)?.trim() ?? '';
        },
        contextMenuBuilder: (context, selectableRegionState) {
          final text = selectedText.trim();
          final items = <ContextMenuButtonItem>[
            if (text.isNotEmpty)
              ContextMenuButtonItem(
                onPressed: () {
                  ContextMenuController.removeAny();
                  selectableRegionState.hideToolbar();
                  _openAiHud(
                    initialRoute: AiHudRoute.qa,
                    initialQaText: text,
                    autoSendInitialQa: true,
                  );
                },
                type: ContextMenuButtonType.custom,
                label: '解释',
              ),
            if (text.isNotEmpty)
              ContextMenuButtonItem(
                onPressed: () {
                  final err = _validateSelectionForIllustration(text);
                  if (err != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    return;
                  }
                  ContextMenuController.removeAny();
                  selectableRegionState.hideToolbar();
                  _openAiHud(
                    initialRoute: AiHudRoute.illustration,
                    initialIllustrationText: text,
                    autoGenerateIllustration: true,
                  );
                },
                type: ContextMenuButtonType.custom,
                label: '配图',
              ),
            ...selectableRegionState.contextMenuButtonItems,
          ];

          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectableRegionState.contextMenuAnchors,
            buttonItems: items,
          );
        },
        child: SingleChildScrollView(
          child: Text(
            _content,
            style: TextStyle(
              fontSize: 18,
              height: 1.8,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withOpacity(0.85)
                  : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}
