import 'dart:ui';
import '../../presentation/providers/ai_model_provider.dart';

/// XML内容清理工具
class XmlContentCleaner {
  /// 从XML字符串中提取纯文本内容
  static String cleanXmlContent(String xmlContent) {
    if (xmlContent.trim().isEmpty) return '';

    // 如果不是XML格式，直接返回（但清理空白字符）
    if (!xmlContent.contains('<') || !xmlContent.contains('>')) {
      return _cleanNonXmlContent(xmlContent);
    }

    try {
      // 移除XML声明
      String cleaned = xmlContent.replaceAll(RegExp(r'<\?xml[^>]*\?>'), '');

      // 移除注释
      cleaned = cleaned.replaceAll(RegExp(r'<!--[^>]*-->'), '');

      // 移除CDATA（通常包含脚本或样式，对阅读无意义）
      cleaned = cleaned.replaceAll(RegExp(r'<!\[CDATA\[[^\]]*\]\]>'), '');

      // 提取文本内容（标签之间的文本）
      cleaned = cleaned.replaceAll(RegExp(r'<[^>]+>'), ' ');

      // 合并多个空格和换行
      cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');

      // 移除特殊字符实体
      cleaned = cleaned
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAll('&#160;', ' ') // 不间断空格
          .replaceAll('&#xA0;', ' '); // 不间断空格（十六进制）

      // 清理前后空白并移除零宽字符
      cleaned = cleaned.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');

      // 如果结果为空，尝试更激进的内容提取（只保留有意义的文本行）
      if (cleaned.isEmpty || cleaned.length < 10) {
        return _extractMeaningfulText(xmlContent);
      }

      return cleaned;
    } catch (e) {
      // 如果解析失败，返回原始内容（但清理空白字符）
      return _cleanNonXmlContent(xmlContent);
    }
  }

  /// 清理非XML内容
  static String _cleanNonXmlContent(String content) {
    if (content.trim().isEmpty) return '';

    // 移除零宽字符和控制字符
    String cleaned = content.replaceAll(
        RegExp(r'[\u200B-\u200D\uFEFF\x00-\x08\x0B-\x0C\x0E-\x1F]'), '');

    // 合并多个空格和换行
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');

    // 移除常见的无意义字符组合
    cleaned = cleaned
        .replaceAll('�', '') // 替换字符
        .replaceAll(RegExp(r'\*{3,}'), '') // 多个星号
        .replaceAll(RegExp(r'-{3,}'), '') // 多个连字符
        .replaceAll(RegExp(r'_{3,}'), ''); // 多个下划线

    return cleaned.trim();
  }

  /// 提取有意义的文本（当常规清理失败时使用）
  static String _extractMeaningfulText(String content) {
    // 按行分割
    final lines = content.split('\n');
    final meaningfulLines = <String>[];

    for (String line in lines) {
      // 清理行内的标签
      String cleanLine = line.replaceAll(RegExp(r'<[^>]*>'), '').trim();

      // 跳过空行、过短的行（少于5个字符）或明显无意义的行
      if (cleanLine.length < 5 ||
          cleanLine.startsWith('<?xml') ||
          cleanLine.startsWith('<!DOCTYPE') ||
          cleanLine.startsWith('<!--') ||
          RegExp(r'^[\s\*\-_=]+$').hasMatch(cleanLine)) {
        continue;
      }

      // 如果行看起来有意义，添加到结果
      if (_looksLikeMeaningfulText(cleanLine)) {
        meaningfulLines.add(cleanLine);
      }
    }

    return meaningfulLines.join(' ');
  }

  /// 判断文本是否看起来有意义
  static bool _looksLikeMeaningfulText(String text) {
    // 至少包含一定数量的字母或中文字符
    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(text);
    final hasChinese = RegExp(r'[\u4e00-\u9fa5]').hasMatch(text);
    final hasNumbers = RegExp(r'\d').hasMatch(text);

    // 必须包含字母、中文或数字
    if (!hasLetters && !hasChinese && !hasNumbers) {
      return false;
    }

    // 如果文本主要由特殊字符组成，则认为无意义
    final specialChars = RegExp(r'[^a-zA-Z0-9\u4e00-\u9fa5\s,.;:!?，。；：！？]')
        .allMatches(text)
        .length;
    if (specialChars > text.length * 0.3) {
      // 特殊字符超过30%
      return false;
    }

    return true;
  }

  /// 判断内容是否为XML格式
  static bool isXmlContent(String content) {
    if (content.trim().isEmpty) return false;
    final trimmed = content.trim();
    return trimmed.startsWith('<') &&
        trimmed.contains('</') &&
        (trimmed.contains('<chapter') ||
            trimmed.contains('<p>') ||
            trimmed.contains('<div>') ||
            trimmed.contains('<body>') ||
            trimmed.contains('<html>') ||
            trimmed.contains('<section'));
  }
}

class ReadingContextService {
  static const int _windowSize = 5; // 前后各5页，共11页

  final Map<int, String> _chapterContentCache;
  final int _currentChapterIndex;
  final int _currentPageInChapter;
  final Map<int, List<TextRange>> _chapterPageRanges;

  ReadingContextService({
    required Map<int, String> chapterContentCache,
    required int currentChapterIndex,
    required int currentPageInChapter,
    required Map<int, List<TextRange>> chapterPageRanges,
  })  : _chapterContentCache = chapterContentCache,
        _currentChapterIndex = currentChapterIndex,
        _currentPageInChapter = currentPageInChapter,
        _chapterPageRanges = chapterPageRanges;

  /// 获取当前章节的完整内容（用于总结和要点提取）
  String getCurrentChapterContent() {
    final rawContent = _chapterContentCache[_currentChapterIndex] ?? '';
    return _cleanContent(rawContent);
  }

  /// 获取滑动窗口内容（用于一般问答）
  String getSlidingWindowContent() {
    final windowPages = _getWindowPages();
    final buffer = StringBuffer();

    for (final page in windowPages) {
      final content = _getPageContent(page.chapterIndex, page.pageIndex);
      if (content.isNotEmpty) {
        buffer.writeln(content);
        buffer.writeln();
      }
    }

    return _cleanContent(buffer.toString().trim());
  }

  /// 获取从章节开始到当前页面的内容
  String getChapterToCurrentPageContent() {
    final rawContent = _chapterContentCache[_currentChapterIndex] ?? '';
    if (rawContent.isEmpty) return '';

    final pageRanges = _chapterPageRanges[_currentChapterIndex];
    if (pageRanges == null || _currentPageInChapter >= pageRanges.length) {
      return _cleanContent(rawContent);
    }

    // 计算当前页面的结束位置
    final currentRange = pageRanges[_currentPageInChapter];
    final endPosition = currentRange.end.clamp(0, rawContent.length);
    if (endPosition <= 0) return '';

    // 返回从开始到当前页面的内容
    final sliced = rawContent.substring(0, endPosition);
    return _cleanContent(sliced);
  }

  /// 获取仅当前页面的内容
  String getCurrentPageContent() {
    final content =
        _getPageContent(_currentChapterIndex, _currentPageInChapter);
    return _cleanContent(content);
  }

  /// 根据内容范围获取内容
  String getContentByScope(QAContentScope scope) {
    switch (scope) {
      case QAContentScope.currentPage:
        return getCurrentPageContent();
      case QAContentScope.currentChapterToPage:
        return getChapterToCurrentPageContent();
      case QAContentScope.slidingWindow:
        return getSlidingWindowContent();
    }
  }

  /// 清理内容中的XML标签
  String _cleanContent(String content) {
    return XmlContentCleaner.cleanXmlContent(content);
  }

  /// 生成总结的提示词
  String generateSummaryPrompt() {
    final chapterContent = getCurrentChapterContent();

    final prompt = '请总结以下章节内容，用清晰的要点列出：\n\n'
        '$chapterContent\n\n'
        '请从以下方面进行总结：\n'
        '1. 核心情节发展\n'
        '2. 关键人物及其行为动机\n'
        '3. 重要的伏笔和线索\n'
        '4. 情感氛围和主题思想\n\n'
        '请用简洁、条理清晰的方式输出。';

    return prompt;
  }

  /// 生成提取要点的提示词
  String generateKeyPointsPrompt() {
    final chapterContent = getCurrentChapterContent();
    return '请从以下内容中提取关键要点，控制在5条以内：\n\n'
        '$chapterContent\n\n'
        '关键要点应包括：\n'
        '- 核心事件\n'
        '- 人物关系变化\n'
        '- 重要细节和伏笔\n'
        '- 情节转折点\n\n'
        '每条要点请用一句话概括。';
  }

  /// 生成一般问答的提示词（包含阅读内容与历史上下文）
  String generateQAPrompt(
    String userQuestion,
    QAContentScope scope, {
    String? history,
  }) {
    final content = getContentByScope(scope).trim();
    final historyText = (history ?? '').trim();

    final buffer = StringBuffer()
      ..writeln('你是阅读助手。请仅基于【当前阅读内容】与【历史问答】作答。')
      ..writeln('要求：')
      ..writeln('1) 优先在内容中定位答案并直接回答。')
      ..writeln('2) 必要时引用原文短句作为依据（可简短摘录）。')
      ..writeln('3) 不要编造；只有确实找不到再说“文中未提及/需要更多上下文”。')
      ..writeln()
      ..writeln('【当前阅读内容】')
      ..writeln(content.isEmpty ? '（当前阅读内容为空）' : content)
      ..writeln();

    if (historyText.isNotEmpty) {
      buffer
        ..writeln('【历史问答（最近对话）】')
        ..writeln(historyText)
        ..writeln();
    }

    buffer
      ..writeln('【用户问题】')
      ..writeln(userQuestion)
      ..writeln()
      ..writeln('请给出清晰、准确的回答。');

    return buffer.toString().trim();
  }

  // 私有方法

  List<PageRef> _getWindowPages() {
    final pages = <PageRef>[];
    final currentPage = PageRef(_currentChapterIndex, _currentPageInChapter);

    // 添加前几页
    for (int i = 1; i <= _windowSize; i++) {
      final prev = _getPreviousPage(currentPage, i);
      if (prev != null) pages.insert(0, prev);
    }

    // 添加当前页
    pages.add(currentPage);

    // 添加后几页
    for (int i = 1; i <= _windowSize; i++) {
      final next = _getNextPage(currentPage, i);
      if (next != null) pages.add(next);
    }

    return pages;
  }

  PageRef? _getPreviousPage(PageRef current, int offset) {
    // 简化的页码计算逻辑
    final targetPage = current.pageIndex - offset;
    if (targetPage >= 0) {
      return PageRef(current.chapterIndex, targetPage);
    }

    // 如果需要跨章节，暂时不处理（简化版）
    return null;
  }

  PageRef? _getNextPage(PageRef current, int offset) {
    // 简化的页码计算逻辑
    final targetPage = current.pageIndex + offset;
    final pageRanges = _chapterPageRanges[current.chapterIndex];
    if (pageRanges != null && targetPage < pageRanges.length) {
      return PageRef(current.chapterIndex, targetPage);
    }

    // 如果需要跨章节，暂时不处理（简化版）
    return null;
  }

  String _getPageContent(int chapterIndex, int pageIndex) {
    final content = _chapterContentCache[chapterIndex];
    if (content == null || content.isEmpty) return '';

    final pageRanges = _chapterPageRanges[chapterIndex];
    if (pageRanges == null || pageIndex >= pageRanges.length) return '';

    final range = pageRanges[pageIndex];
    final start = range.start;
    if (start >= content.length) return '';

    final end = range.end;
    final actualEnd = end > content.length ? content.length : end;

    return content.substring(start, actualEnd);
  }
}

class PageRef {
  final int chapterIndex;
  final int pageIndex;

  const PageRef(this.chapterIndex, this.pageIndex);
}
