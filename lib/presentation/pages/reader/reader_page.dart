import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:epubx/epubx.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import '../../../core/theme/app_colors.dart';
import '../../widgets/ai_hud.dart';
import '../../providers/books_provider.dart';
import '../../../data/services/book_parser.dart';
import '../../../data/models/book.dart';

class _MeasureSize extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onChange;

  const _MeasureSize({
    required this.onChange,
    required this.child,
  });

  @override
  _MeasureSizeState createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Schedule callback
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            final size = context.size;
            if (size != null) {
              widget.onChange(size);
            }
          }
        });
        return widget.child;
      },
    );
  }
}

class ReaderPage extends StatefulWidget {
  final String bookId;

  const ReaderPage({super.key, required this.bookId});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with TickerProviderStateMixin {
  bool _showControls = false;
  bool _isLoading = true;
  String? _error;

  // Settings State
  double _fontSize = 18.0;
  double _lineHeight = 1.8;
  Color _bgColor = const Color(0xFFF5F9FA); // Default (Day)
  Color _textColor = const Color(0xFF2C3E50);

  EpubBookRef? _epubBook;
  List<EpubChapterRef> _chapters = [];
  int _currentChapterIndex = 0;

  // Horizontal Mode State
  // We track the "Page" index within the current chapter.
  // 0 means first page of chapter.
  int _currentPageInChapter = 0;
  int _totalPagesInCurrentChapter = 1;
  Map<int, int> _chapterPageCounts = {};
  Timer? _progressSaveTimer;
  double? _contentTopInset;
  double? _contentBottomInset;

  // Content Cache
  final Map<int, String> _chapterContentCache = {};
  final Map<int, String> _chapterPlainText = {};
  final Map<int, List<TextRange>> _chapterPageRanges = {};
  final Map<int, String> _chapterPageRangeKeys = {};
  final Map<int, int> _chapterTitleLength = {};
  // For Horizontal Mode, we use a PageController with a large initial index to simulate infinite scrolling
  // But strictly mapping pages is better.
  // Let's use a PageController that we reset when changing chapters?
  // No, that breaks animation.
  // We use a single PageController for the CURRENT CHAPTER's pages.
  // When we reach end, we switch to next chapter.
  late PageController _pageController;

  final BookParser _parser = BookParser();
  late AnimationController _pulseController;
  late AnimationController _controlsController; // New Controller
  late Animation<Offset> _topBarOffset; // Animation for Top Bar
  late Animation<Offset> _bottomBarOffset; // Animation for Bottom Bar
  Timer? _pulseTimer;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // Hide System UI immediately on entry
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Controls Animation
    _controlsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _topBarOffset =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
      CurvedAnimation(parent: _controlsController, curve: Curves.easeOut),
    );
    _bottomBarOffset =
        Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
      CurvedAnimation(parent: _controlsController, curve: Curves.easeOut),
    );

    // Pulse Animation
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _startPulseTimer();

    _loadSettingsAndBook();
  }

  void _startPulseTimer() {
    _pulseTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        _pulseController.forward().then((_) => _pulseController.reverse());
      }
    });
  }

  Future<void> _loadSettingsAndBook() async {
    _prefs = await SharedPreferences.getInstance();

    // Load Settings
    if (mounted) {
      setState(() {
        _fontSize = _prefs?.getDouble('fontSize') ?? 18.0;
        _lineHeight = _prefs?.getDouble('lineHeight') ?? 1.8;
        int? colorVal = _prefs?.getInt('bgColor');
        if (colorVal != null) _bgColor = Color(colorVal);
        int? textVal = _prefs?.getInt('textColor');
        if (textVal != null) _textColor = Color(textVal);
      });
    }

    await _loadBookContent();

    // Restore Progress
    if (_chapters.isNotEmpty) {
      String key = 'progress_${widget.bookId}';
      final int legacyChapter = _prefs?.getInt('${key}_index') ?? 0;
      final int savedHChapter =
          _prefs?.getInt('${key}_h_chapter') ?? legacyChapter;
      final int savedHPage = _prefs?.getInt('${key}_h_page') ?? 0;

      _currentChapterIndex = savedHChapter.clamp(0, _chapters.length - 1);
      _currentPageInChapter = savedHPage.clamp(0, 999999);
      if (mounted) setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pageController.hasClients) {
          _pageController.jumpToPage(1000);
        }
      });
    }
  }

  @override
  void dispose() {
    _saveSettings();
    _saveProgress();
    _progressSaveTimer?.cancel();
    _pageController.dispose();
    // for (var c in _chapterControllers.values) c.dispose(); // Removed
    _pulseController.dispose();
    _controlsController.dispose();
    _pulseTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _saveSettings() async {
    if (_prefs == null) return;
    final prefs = _prefs!;
    final booksProvider = Provider.of<BooksProvider>(context, listen: false);
    await prefs.setDouble('fontSize', _fontSize);
    await prefs.setDouble('lineHeight', _lineHeight);
    await prefs.setInt('bgColor', _bgColor.value);
    await prefs.setInt('textColor', _textColor.value);
    try {
      booksProvider.saveReadingSettingsToDb(
        fontSize: _fontSize,
        lineHeight: _lineHeight,
      );
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    if (_prefs == null) return;
    String key = 'progress_${widget.bookId}';
    await _prefs!.setInt('${key}_h_chapter', _currentChapterIndex);
    await _prefs!.setInt('${key}_h_page', _currentPageInChapter);
  }

  void _saveProgressDebounced() {
    if (_prefs == null) return;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(milliseconds: 500), () {
      _saveProgress();
    });
  }

  Future<void> _loadBookContent() async {
    final booksProvider = Provider.of<BooksProvider>(context, listen: false);

    Book book;
    try {
      book = booksProvider.books.firstWhere((b) => b.id == widget.bookId);
    } catch (e) {
      if (mounted)
        setState(() {
          _error = 'Book not found';
          _isLoading = false;
        });
      return;
    }

    try {
      EpubBookRef? epub;
      if (kIsWeb) {
        if (book.fileBytes != null) {
          epub = await _parser.openBookFromBytes(book.fileBytes!);
        } else {
          if (mounted)
            setState(() {
              _error = 'Cannot load file';
              _isLoading = false;
            });
          return;
        }
      } else {
        if (book.filePath.isNotEmpty) {
          epub = await _parser.openBook(book.filePath);
        } else {
          if (mounted)
            setState(() {
              _error = 'Cannot load file';
              _isLoading = false;
            });
          return;
        }
      }

      if (epub != null) {
        final chapters = await _flattenChapters(epub.getChapters());

        if (mounted) {
          setState(() {
            _epubBook = epub;
            _chapters = chapters;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _error = 'Error: $e';
          _isLoading = false;
        });
    }
  }

  Future<List<EpubChapterRef>> _flattenChapters(
      Future<List<EpubChapterRef>> chaptersFuture) async {
    final chapters = await chaptersFuture;
    return chapters;
  }

  // UI Methods
  void _toggleControls() {
    if (_controlsController.isAnimating) return;

    setState(() {
      _showControls = !_showControls;
    });

    // Toggle System UI and Animation
    if (_showControls) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge,
          overlays: SystemUiOverlay.values);
      _controlsController.forward();
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _controlsController.reverse();
    }
  }

  void _hideControls() {
    if (!_showControls) return;
    if (_controlsController.isAnimating) return;
    setState(() {
      _showControls = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controlsController.reverse();
  }

  int _pageCountForChapter(int chapterIndex) {
    final ranges = _chapterPageRanges[chapterIndex];
    if (ranges != null && ranges.isNotEmpty) {
      return ranges.length.clamp(1, 999999);
    }
    return _chapterPageCounts[chapterIndex] ?? 9999;
  }

  String _getPlainTextForChapter(int chapterIndex) {
    final cached = _chapterPlainText[chapterIndex];
    if (cached != null) return cached;
    final html = _chapterContentCache[chapterIndex];
    if (html == null) return '';

    String text = html;

    text = text.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text =
        text.replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n\n');

    text = text.replaceAll(RegExp(r'<[^>]+>', multiLine: true), ' ');

    text = text.replaceAll(RegExp(r'\r\n?'), '\n');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.trim();

    final parts = text.split(RegExp(r'\n+'));
    final buffer = StringBuffer();
    int titleLength = 0;
    for (int i = 0; i < parts.length; i++) {
      final raw = parts[i].trim();
      if (raw.isEmpty) continue;
      final bool isTitle = i == 0;
      final String indent = isTitle ? '' : '　　';
      final String paraText = indent + raw;
      if (isTitle) {
        titleLength = paraText.length;
      }
      buffer.write(paraText);
      if (i != parts.length - 1) {
        buffer.write('\n\n');
      }
    }

    final result = buffer.toString();
    _chapterPlainText[chapterIndex] = result;
    _chapterTitleLength[chapterIndex] = titleLength;
    return result;
  }

  TextSpan _buildStyledSpanForRange(
    int chapterIndex,
    String fullText,
    int start,
    int end,
    TextStyle bodyStyle,
  ) {
    if (end <= start || start >= fullText.length) {
      return TextSpan(text: '', style: bodyStyle);
    }
    final int safeStart = start.clamp(0, fullText.length);
    final int safeEnd = end.clamp(0, fullText.length);
    final int titleLen = _chapterTitleLength[chapterIndex] ?? 0;
    final TextStyle titleStyle = bodyStyle.copyWith(
      fontSize: _fontSize + 2,
      fontWeight: FontWeight.bold,
    );

    if (titleLen <= 0 || safeStart >= titleLen) {
      return TextSpan(
        text: fullText.substring(safeStart, safeEnd),
        style: bodyStyle,
      );
    }
    if (safeEnd <= titleLen) {
      return TextSpan(
        text: fullText.substring(safeStart, safeEnd),
        style: titleStyle,
      );
    }

    final List<InlineSpan> children = [];
    if (safeStart < titleLen) {
      children.add(TextSpan(
        text: fullText.substring(safeStart, titleLen),
        style: titleStyle,
      ));
    }
    if (titleLen < safeEnd) {
      children.add(TextSpan(
        text: fullText.substring(titleLen, safeEnd),
        style: bodyStyle,
      ));
    }
    return TextSpan(children: children, style: bodyStyle);
  }

  void _ensureTextPaginationForChapter({
    required int chapterIndex,
    required double viewportHeight,
    required double contentWidth,
  }) {
    final text = _getPlainTextForChapter(chapterIndex);
    if (text.isEmpty) {
      _chapterPageRanges[chapterIndex] = [const TextRange(start: 0, end: 0)];
      _chapterPageRangeKeys[chapterIndex] = '';
      _chapterPageCounts[chapterIndex] = 1;
      if (chapterIndex == _currentChapterIndex) {
        _totalPagesInCurrentChapter = 1;
        _currentPageInChapter = 0;
      }
      return;
    }

    final dpr = MediaQuery.of(context).devicePixelRatio;
    String snapKey(double v) => (v * dpr).roundToDouble().toStringAsFixed(0);
    final String paginationKey =
        '${snapKey(contentWidth)}|${snapKey(viewportHeight)}|${_fontSize.toStringAsFixed(2)}|${_lineHeight.toStringAsFixed(2)}|${MediaQuery.of(context).textScaler.scale(1).toStringAsFixed(3)}';

    if (_chapterPageRangeKeys[chapterIndex] == paginationKey &&
        _chapterPageRanges[chapterIndex] != null) {
      return;
    }

    final TextStyle effectiveTextStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: _lineHeight,
      fontSize: _fontSize,
      color: _textColor,
    );

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    final List<TextRange> ranges = [];
    int start = 0;
    final int len = text.length;

    while (start < len) {
      int low = start + 1;
      int high = len;
      int best = low;

      while (low <= high) {
        final int mid = (low + high) >> 1;
        textPainter.text = _buildStyledSpanForRange(
            chapterIndex, text, start, mid, effectiveTextStyle);
        textPainter.layout(minWidth: 0, maxWidth: contentWidth);
        if (textPainter.height <= viewportHeight) {
          best = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }

      if (best <= start) {
        best = (start + 1).clamp(start + 1, len);
      }

      ranges.add(TextRange(start: start, end: best));
      start = best;
      while (start < len && text.codeUnitAt(start) == 10) {
        start++;
      }
    }

    _chapterPageRanges[chapterIndex] = ranges;
    _chapterPageRangeKeys[chapterIndex] = paginationKey;
    final int pageCount = ranges.isEmpty ? 1 : ranges.length;
    _chapterPageCounts[chapterIndex] = pageCount;
    if (chapterIndex == _currentChapterIndex) {
      _totalPagesInCurrentChapter = pageCount;
      if (_currentPageInChapter >= pageCount) {
        _currentPageInChapter = pageCount - 1;
      }
    }
  }

  void _invalidatePagination() {
    _chapterPageCounts.clear();
    _chapterPageRanges.clear();
    _chapterPageRangeKeys.clear();
    _totalPagesInCurrentChapter = 1;
    _currentPageInChapter = 0;
  }

  Future<void> _ensureChapterContentCached(int chapterIndex) async {
    if (_chapterContentCache[chapterIndex] != null) return;
    final value = await _chapters[chapterIndex].readHtmlContent();
    if (!mounted) return;
    setState(() {
      _chapterContentCache[chapterIndex] = value;
    });
  }

  void _showTableOfContents() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _panelBgColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text('目录',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _panelTextColor)),
              ),
              Divider(color: _panelTextColor.withOpacity(0.1)),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    return ListTile(
                      title: Text(
                        chapter.Title ?? 'Chapter ${index + 1}',
                        style: TextStyle(
                          color: index == _currentChapterIndex
                              ? AppColors.techBlue
                              : _panelTextColor,
                          fontWeight: index == _currentChapterIndex
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      onTap: () {
                        setState(() {
                          _currentChapterIndex = index;
                          _currentPageInChapter = 0;
                        });
                        if (_pageController.hasClients) {
                          _pageController.jumpToPage(1000);
                        }
                        _hideControls();
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ).then((_) {
      if (mounted) _hideControls();
    });
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _panelBgColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('阅读设置',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: _panelTextColor)),
                  const SizedBox(height: 24),

                  // Font Size
                  Row(
                    children: [
                      Icon(Icons.format_size,
                          color: _panelTextColor.withOpacity(0.5)),
                      const SizedBox(width: 16),
                      Text('A-',
                          style:
                              TextStyle(fontSize: 16, color: _panelTextColor)),
                      Expanded(
                        child: Slider(
                          value: _fontSize,
                          min: 12,
                          max: 32,
                          divisions: 10,
                          activeColor: AppColors.techBlue,
                          onChanged: (val) {
                            setSheetState(() {});
                            setState(() {
                              _fontSize = val;
                              _invalidatePagination();
                            });
                          },
                        ),
                      ),
                      Text('A+',
                          style:
                              TextStyle(fontSize: 20, color: _panelTextColor)),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Line Height
                  Row(
                    children: [
                      Icon(Icons.format_line_spacing,
                          color: _panelTextColor.withOpacity(0.5)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Slider(
                          value: _lineHeight,
                          min: 1.0,
                          max: 3.0,
                          divisions: 4,
                          activeColor: AppColors.techBlue,
                          onChanged: (val) {
                            setSheetState(() {});
                            setState(() {
                              _lineHeight = val;
                              _invalidatePagination();
                            });
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Background Theme
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildThemeOption(const Color(0xFFF5F9FA),
                          const Color(0xFF2C3E50), '日间'),
                      _buildThemeOption(const Color(0xFFF5EDC0),
                          const Color(0xFF3E2723), '护眼'),
                      _buildThemeOption(
                          const Color(0xFF121212),
                          const Color(0xFFEEEEEE),
                          '夜间'), // Light text for dark theme
                    ],
                  ),

                  const SizedBox(height: 24),

                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      if (mounted) _hideControls();
    });
  }

  Widget _buildThemeOption(Color color, Color textColor, String label) {
    bool isSelected = _bgColor.value == color.value;
    return GestureDetector(
      onTap: () {
        setState(() {
          _bgColor = color;
          _textColor = textColor;
        });
        _hideControls();
        Navigator.pop(context);
      },
      child: Column(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? AppColors.techBlue : Colors.grey[300]!,
                width: isSelected ? 2 : 1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  color: isSelected
                      ? AppColors.techBlue
                      : _panelTextColor.withOpacity(0.5),
                  fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildFlatButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    Color? color, // Optional color override
    bool isActive = false,
  }) {
    // If color not provided, use default based on theme
    final bool isDarkBg = _bgColor.computeLuminance() < 0.5;
    final Color defaultColor = isDarkBg ? Colors.white : AppColors.deepSpace;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.techBlue.withOpacity(0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: isActive ? AppColors.techBlue : (color ?? defaultColor),
            size: 24, // Standard size
          ),
        ),
      ),
    );
  }

  // Helper to get panel colors based on reading theme
  Color get _panelBgColor => _bgColor.computeLuminance() < 0.5
      ? const Color(0xFF333333)
      : Colors.white;
  Color get _panelTextColor =>
      _bgColor.computeLuminance() < 0.5 ? Colors.white : AppColors.deepSpace;

  // Horizontal Mode (Page Swipe)
  Widget _buildHorizontalMode(EdgeInsets padding) {
    // Use MediaQuery.removePadding to force remove system Safe Area "bars"
    // because we handle padding manually in _buildSinglePage.
    // This prevents PageView from adding implicit padding for notches/home bar.
    return MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        child: PageView.builder(
          controller: _pageController,
          padEnds: false,
          onPageChanged: (index) {
            // Determine direction
            int diff = index - 1000;
            if (diff == 0) return;
            setState(() {
              if (diff > 0) {
                // Next Page
                _currentPageInChapter++;
                // Check if we exceeded current chapter pages
                int total = _pageCountForChapter(_currentChapterIndex);

                if (_currentPageInChapter >= total) {
                  // Next Chapter
                  if (_currentChapterIndex < _chapters.length - 1) {
                    _currentChapterIndex++;
                    _currentPageInChapter = 0;
                    // Reset page count for new chapter
                    _totalPagesInCurrentChapter = 1;
                  } else {
                    // End of book, revert
                    _currentPageInChapter--;
                  }
                }
              } else {
                // Prev Page
                _currentPageInChapter--;
                if (_currentPageInChapter < 0) {
                  // Prev Chapter
                  if (_currentChapterIndex > 0) {
                    _currentChapterIndex--;
                    // We need to know pages of prev chapter to set to last page
                    // If not cached, we default to 0 and let it load/correct itself?
                    // If we set to 0, user sees first page of prev chapter.
                    // Ideally we want last page.
                    // We can set it to a high number (e.g. 9999) and let the layout logic clamp it?
                    // No, our layout logic below needs exact index.
                    // If we don't know, we set to 0 (start of chapter) is safer than empty end.
                    // BUT user expects to go to END of prev chapter.
                    int prevCount = _pageCountForChapter(_currentChapterIndex);
                    _currentPageInChapter = prevCount - 1;
                    _totalPagesInCurrentChapter = prevCount;
                  } else {
                    // Start of book, revert
                    _currentPageInChapter++;
                  }
                }
              }
            });
            _saveProgressDebounced();

            // Force jump back to center to allow infinite scroll
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_pageController.hasClients) {
                _pageController.jumpToPage(1000);
              }
            });
          },
          itemBuilder: (context, index) {
            if (index == 1000) {
              return _buildSinglePage(
                  _currentChapterIndex, _currentPageInChapter, padding);
            }

            int diff = index - 1000;

            int targetChapter = _currentChapterIndex;
            int targetPage = _currentPageInChapter + diff;

            int currentTotal = _pageCountForChapter(targetChapter);

            if (targetPage >= currentTotal) {
              if (targetChapter < _chapters.length - 1) {
                targetChapter++;
                targetPage = 0;
              } else {
                return null;
              }
            } else if (targetPage < 0) {
              if (targetChapter > 0) {
                targetChapter--;
                int prevCount = _pageCountForChapter(targetChapter);
                targetPage = prevCount - 1;
              } else {
                return null;
              }
            }

            return _buildSinglePage(targetChapter, targetPage, padding);
          },
        ));
  }

  Widget _buildSinglePage(int chapterIndex, int pageIndex, EdgeInsets padding) {
    // 1. Check Cache
    String? content = _chapterContentCache[chapterIndex];

    if (content == null) {
      // Trigger load if not loading
      _chapters[chapterIndex].readHtmlContent().then((value) {
        if (mounted) {
          setState(() {
            _chapterContentCache[chapterIndex] = value;
          });
        }
      });
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        double snap(double value) => (value * dpr).roundToDouble() / dpr;

        final double topMargin = snap(padding.top + 16);
        final double bottomMargin = snap(padding.bottom + 16);

        double viewportHeight =
            snap(constraints.maxHeight - topMargin - bottomMargin);
        if (viewportHeight <= 0) viewportHeight = 500;

        final TextStyle effectiveTextStyle =
            (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
                .copyWith(
          height: _lineHeight,
          fontSize: _fontSize,
          color: _textColor,
        );

        final double contentWidth =
            (constraints.maxWidth - 48).clamp(0, constraints.maxWidth);

        _ensureTextPaginationForChapter(
          chapterIndex: chapterIndex,
          viewportHeight: viewportHeight,
          contentWidth: contentWidth,
        );

        final ranges = _chapterPageRanges[chapterIndex];
        if (ranges == null || ranges.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final int safeIndex = pageIndex.clamp(0, ranges.length - 1);
        final range = ranges[safeIndex];
        final String plainText = _getPlainTextForChapter(chapterIndex);
        if (range.start >= plainText.length) {
          return const SizedBox.shrink();
        }
        final int end = range.end.clamp(0, plainText.length);
        final TextSpan span = _buildStyledSpanForRange(
          chapterIndex,
          plainText,
          range.start,
          end,
          effectiveTextStyle,
        );

        return Stack(
          children: [
            Positioned(
              top: topMargin,
              left: 0,
              right: 0,
              bottom: bottomMargin,
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text.rich(span),
                ),
              ),
            ),
            if (!_showControls)
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          _pageController.previousPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut);
                        },
                        child: Container(color: Colors.transparent),
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _toggleControls,
                        child: Container(color: Colors.transparent),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          _pageController.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut);
                        },
                        child: Container(color: Colors.transparent),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // IMPORTANT: Get padding from MediaQuery BEFORE removing it
    final padding = MediaQuery.of(context).padding;
    final viewPadding = MediaQuery.of(context).viewPadding;
    _contentTopInset ??= viewPadding.top;
    _contentBottomInset ??= viewPadding.bottom;

    // Determine dynamic background for bars
    // Ensure fully opaque background as requested
    Color barColor = _bgColor.withAlpha(255);
    // If background is dark, use light icons; else dark icons.
    bool isDarkBg = _bgColor.computeLuminance() < 0.5;
    Color iconColor = isDarkBg ? Colors.white : AppColors.deepSpace;
    Brightness systemIconBrightness =
        isDarkBg ? Brightness.light : Brightness.dark;

    Widget readerContent;
    try {
      if (!_pageController.hasClients) {
        _pageController = PageController(initialPage: 1000);
      }
    } catch (e) {
      _pageController = PageController(initialPage: 1000);
    }
    readerContent = _buildHorizontalMode(
      EdgeInsets.only(
        top: _contentTopInset ?? 0,
        bottom: _contentBottomInset ?? 0,
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: systemIconBrightness,
        systemNavigationBarIconBrightness: systemIconBrightness,
        systemNavigationBarContrastEnforced: false,
      ),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Container(color: _bgColor),

              if (_isLoading)
                const Center(child: CircularProgressIndicator())
              else if (_error != null)
                Center(
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red)))
              else
                readerContent,

              // Overlay to dismiss controls when clicking content
              if (_showControls)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _toggleControls,
                    child: Container(color: Colors.transparent),
                  ),
                ),

              // Top Bar
              SlideTransition(
                position: _topBarOffset,
                child: Container(
                  height: padding.top + 64,
                  padding: EdgeInsets.only(
                      top: padding.top + 8, left: 16, right: 16),
                  color: barColor,
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () => Navigator.pop(context),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(Icons.arrow_back,
                              color: iconColor, size: 24),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom Bar
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SlideTransition(
                  position: _bottomBarOffset,
                  child: Container(
                    padding: EdgeInsets.only(
                        bottom: padding.bottom + 24,
                        top: 20,
                        left: 24,
                        right: 24),
                    color: barColor,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildFlatButton(
                            icon: Icons.menu_rounded,
                            onTap: _showTableOfContents,
                            tooltip: '目录'),

                        // AI Assistant Pulse Button (Center)
                        GestureDetector(
                          onTap: () {
                            showModalBottomSheet(
                              context: context,
                              backgroundColor:
                                  _panelBgColor, // Use theme-aware bg
                              shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(24))),
                              builder: (context) => AiHud(
                                bgColor: _panelBgColor,
                                textColor: _panelTextColor,
                              ),
                            );
                          },
                          child: AnimatedBuilder(
                            animation: _pulseController,
                            builder: (context, child) {
                              return Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.techBlue.withOpacity(
                                          0.4 * _pulseController.value),
                                      blurRadius:
                                          10 + (10 * _pulseController.value),
                                      spreadRadius: 2 * _pulseController.value,
                                    ),
                                  ],
                                ),
                                child: child,
                              );
                            },
                            child: Container(
                              width: 48, height: 48,
                              decoration: const BoxDecoration(
                                color: Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.auto_awesome,
                                  size: 24,
                                  color: AppColors.techBlue), // Standard size
                            ),
                          ),
                        ),

                        // Settings Button (Right)
                        _buildFlatButton(
                            icon: Icons.text_fields_rounded,
                            onTap: _showSettings,
                            tooltip: '阅读设置'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChapterContent(int index) {
    return FutureBuilder<String>(
      future: _chapters[index].readHtmlContent(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const SizedBox(
              height: 300, child: Center(child: CircularProgressIndicator()));
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HtmlWidget(
                snapshot.data!,
                textStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: _lineHeight,
                      fontSize: _fontSize,
                      color: _textColor,
                    ),
                customStylesBuilder: (element) {
                  // FIX: Reset body and html margins to prevent 8px vertical shift
                  if (element.localName == 'body' ||
                      element.localName == 'html') {
                    return {
                      'margin': '0',
                      'padding': '0',
                      'height': 'auto',
                      'width': 'auto'
                    };
                  }
                  // Force paragraph spacing to be exactly one line height
                  if (element.localName == 'p') {
                    return {
                      'margin-top': '0',
                      'margin-bottom': '${_lineHeight}em',
                      'padding': '0'
                    };
                  }
                  // Normalize Headers
                  if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6']
                      .contains(element.localName)) {
                    return {
                      'margin-top': '0',
                      'margin-bottom': '${_lineHeight}em',
                      'font-size': '1em',
                      'font-weight': 'bold',
                      'line-height': 'inherit'
                    };
                  }
                  if ([
                    'div',
                    'section',
                    'article',
                    'blockquote',
                    'ul',
                    'ol',
                    'li'
                  ].contains(element.localName)) {
                    return {'margin': '0', 'padding': '0'};
                  }
                  return null;
                },
              ),
              const Divider(height: 64),
            ],
          ),
        );
      },
    );
  }
}
