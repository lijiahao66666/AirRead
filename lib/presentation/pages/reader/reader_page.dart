import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:epubx/epubx.dart';
import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../../widgets/ai_hud.dart';
import '../../widgets/glass_panel.dart';
import '../../providers/books_provider.dart';
import '../../providers/ai_model_provider.dart';
import '../../providers/translation_provider.dart';
import '../../../data/services/book_parser.dart';
import '../../../data/models/book.dart';
import 'widgets/reader_paragraph.dart';
import '../../../ai/translation/translation_types.dart';
import '../../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../../ai/tencent_tts/tencent_tts_client.dart';

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
  double _lineHeight = 1.4;
  Color _bgColor = const Color(0xFFF5F9FA); // Default (Day)
  Color _textColor = const Color(0xFF2C3E50);

  // AI companion toggles (continuous features).
  //
  // We split "feature enabled" vs "active" so the right-side quick actions can
  // temporarily pause/resume without fully disabling the feature.
  bool _aiReadAloudPlaying = false;

  final AudioPlayer _readAloudPlayer = AudioPlayer();
  final Map<String, Uint8List> _readAloudAudioCache = {};
  String _readAloudAudioKey = '';
  final Map<String, Future<Map<int, String>>> _translationFutures = {};
  Timer? _continuousPrefetchTimer;
  int? _prefetchCursorChapterIndex;
  int _prefetchCursorParagraphIndex = 0;
  bool _prefetchTickRunning = false;

  List<EpubChapterRef> _chapters = [];
  int _currentChapterIndex = 0;

  // Horizontal Mode State
  // We track the "Page" index within the current chapter.
  // 0 means first page of chapter.
  int _currentPageInChapter = 0;
  final Map<int, int> _chapterPageCounts = {};
  Timer? _progressSaveTimer;
  double? _contentBottomInset;

  // Content Cache
  final Map<int, String> _chapterContentCache = {};
  final Map<int, String> _chapterPlainText = {};
  // Caches "effective" text used for pagination (includes translations)
  final Map<int, String> _chapterEffectiveText = {};
  final Map<int, List<TextRange>> _chapterPageRanges = {};
  final Map<int, String> _chapterPageRangeKeys = {};
  final Map<int, List<TextRange>> _chapterPlainPageRanges = {};
  final Map<int, String> _chapterPlainPageRangeKeys = {};
  final Map<int, int> _chapterPaginationLastMs = {};
  final Map<int, int> _chapterTitleLength = {};
  final Map<int, List<ReaderParagraph>> _chapterParagraphsCache = {};

  double _currentPageProgressInChapter = 0;
  double? _lastPaginationViewportHeight;
  double? _lastPaginationContentWidth;
  bool? _lastTranslationApplyToReader;
  TranslationDisplayMode? _lastTranslationDisplayMode;
  bool _relocateAfterTranslationChangeScheduled = false;

  // For Horizontal Mode, we use a PageController with a large initial index to simulate infinite scrolling
  // But strictly mapping pages is better.
  // Let's use a PageController that we reset when changing chapters?
  // No, that breaks animation.
  // We use a single PageController for the CURRENT CHAPTER's pages.
  // When we reach end, we switch to next chapter.
  late PageController _pageController;
  int _pageViewCenterIndex = 1000;

  final BookParser _parser = BookParser();
  late AnimationController _pulseController;
  late AnimationController _readAloudAnimController;
  late AnimationController _controlsController; // New Controller
  late Animation<Offset> _topBarOffset; // Animation for Top Bar
  late Animation<Offset> _bottomBarOffset; // Animation for Bottom Bar
  Timer? _pulseTimer;
  SharedPreferences? _prefs;
  Offset? _tapDownPos;
  int? _tapDownMs;
  bool _tapMoved = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 1000);
    _pageViewCenterIndex = 1000;
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
    _readAloudAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _startPulseTimer();

    _readAloudPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _aiReadAloudPlaying = false;
      });
    });

    _loadSettingsAndBook();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<TranslationProvider>().setCurrentBookId(widget.bookId);
    });
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
        _lineHeight = _prefs?.getDouble('lineHeight') ?? 1.4;
        int? colorVal = _prefs?.getInt('bgColor');
        if (colorVal != null) _bgColor = Color(colorVal);
        int? textVal = _prefs?.getInt('textColor');
        if (textVal != null) _textColor = Color(textVal);

        _aiReadAloudPlaying = false;
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
  void didUpdateWidget(covariant ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<TranslationProvider>().setCurrentBookId(widget.bookId);
      });
    }
  }

  @override
  void dispose() {
    _saveSettings();
    _saveProgress();
    _progressSaveTimer?.cancel();
    _stopContinuousPrefetch();
    _readAloudPlayer.dispose();
    _pageController.dispose();
    // for (var c in _chapterControllers.values) c.dispose(); // Removed
    _pulseController.dispose();
    _readAloudAnimController.dispose();
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
      if (mounted) {
        setState(() {
          _error = 'Book not found';
          _isLoading = false;
        });
      }
      return;
    }

    try {
      EpubBookRef? epub;
      if (kIsWeb) {
        if (book.fileBytes != null) {
          epub = await _parser.openBookFromBytes(book.fileBytes!);
        } else {
          if (mounted) {
            setState(() {
              _error = 'Cannot load file';
              _isLoading = false;
            });
          }
          return;
        }
      } else {
        if (book.filePath.isNotEmpty) {
          epub = await _parser.openBook(book.filePath);
        } else {
          if (mounted) {
            setState(() {
              _error = 'Cannot load file';
              _isLoading = false;
            });
          }
          return;
        }
      }

      if (epub != null) {
        final chapters = await _flattenChapters(epub.getChapters());

        if (mounted) {
          setState(() {
            _chapters = chapters;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<List<EpubChapterRef>> _flattenChapters(
      Future<List<EpubChapterRef>> chaptersFuture) async {
    final chapters = await chaptersFuture;
    return chapters;
  }

  // UI Methods
  void _toggleControls() {
    final next = !_showControls;
    setState(() {
      _showControls = next;
    });

    // Toggle System UI and Animation
    if (next) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge,
          overlays: SystemUiOverlay.values);
      _controlsController.forward();
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _controlsController.reverse();
    }
  }

  void _onReaderPointerDown(Offset pos) {
    _tapDownPos = pos;
    _tapDownMs = DateTime.now().millisecondsSinceEpoch;
    _tapMoved = false;
  }

  void _onReaderPointerMove(Offset pos) {
    final down = _tapDownPos;
    if (down == null) return;
    final dx = pos.dx - down.dx;
    final dy = pos.dy - down.dy;
    if ((dx * dx + dy * dy) > 256) {
      _tapMoved = true;
    }
  }

  void _onReaderPointerUp({required Offset pos, required double width}) {
    final downMs = _tapDownMs;
    _tapDownMs = null;
    _tapDownPos = null;

    final moved = _tapMoved;
    _tapMoved = false;

    if (moved) return;
    if (downMs == null) return;
    if (_showControls) return;
    if (width <= 0) return;
    if (!_pageController.hasClients) return;

    final elapsed = DateTime.now().millisecondsSinceEpoch - downMs;
    if (elapsed > 350) return;

    final x = pos.dx.clamp(0, width);
    if (x <= width * 0.3) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }
    if (x >= width * 0.7) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }
    _toggleControls();
  }

  Future<void> _openAiHud({
    AiHudRoute initialRoute = AiHudRoute.main,
    String? initialQaText,
    bool autoSendInitialQa = false,
  }) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg))),
      builder: (sheetContext) {
        return SizedBox(
          height: MediaQuery.of(sheetContext).size.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (mounted) _hideControls();
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Consumer<TranslationProvider>(
                  builder: (context, translationProvider, _) {
                    final viewportHeight = _lastPaginationViewportHeight;
                    final contentWidth = _lastPaginationContentWidth;
                    if (viewportHeight != null && contentWidth != null) {
                      _ensurePlainTextPaginationForChapter(
                        chapterIndex: _currentChapterIndex,
                        viewportHeight: viewportHeight,
                        contentWidth: contentWidth,
                      );
                    }

                    final plainRanges =
                        _chapterPlainPageRanges[_currentChapterIndex];
                    final plainPageIndex =
                        plainRanges == null || plainRanges.isEmpty
                            ? _currentPageInChapter
                            : _plainPageIndexForProgress(
                                _currentChapterIndex,
                                _currentPageProgressInChapter,
                              );

                    final qaTextCache = _chapterPlainText.isNotEmpty
                        ? Map<int, String>.from(_chapterPlainText)
                        : Map<int, String>.from(_chapterEffectiveText);

                    return AiHud(
                      bgColor: _panelBgColor,
                      textColor: _panelTextColor,
                      initialRoute: initialRoute,
                      initialQaText: initialQaText,
                      autoSendInitialQa: autoSendInitialQa,
                      translateEnabled: translationProvider.aiTranslateEnabled,
                      translateActive: translationProvider.applyToReader,
                      onTranslateChanged: (v) async {
                        await _setAiTranslateEnabled(
                          provider: translationProvider,
                          enabled: v,
                        );
                      },
                      readAloudEnabled: translationProvider.aiReadAloudEnabled,
                      onReadAloudChanged: (v) async {
                        await _setAiReadAloudEnabled(
                          provider: translationProvider,
                          enabled: v,
                        );
                      },
                      bookId: widget.bookId,
                      chapterTextCache: qaTextCache,
                      currentChapterIndex: _currentChapterIndex,
                      currentPageInChapter: plainPageIndex,
                      chapterPageRanges: _chapterPlainPageRanges.isNotEmpty
                          ? _chapterPlainPageRanges
                          : _chapterPageRanges,
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

  Future<void> _translateSelectedText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;

    final tp = context.read<TranslationProvider>();
    if (!mounted) return;
    bool started = false;
    bool done = false;
    String translation = '';
    String? errorText;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final panelBg = _panelBgColor;
        final panelText = _panelTextColor;
        return GlassPanel.sheet(
          surfaceColor: panelBg,
          opacity: AppTokens.glassOpacityDense,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.62,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: StatefulBuilder(
                  builder: (context, setModalState) {
                    if (!started) {
                      started = true;
                      Future<void>(() async {
                        try {
                          final res =
                              await tp.translateParagraphsByIndex({0: t});
                          translation = (res[0] ?? '').trim();
                        } catch (e) {
                          errorText = e.toString();
                        }
                        done = true;
                        if (!sheetContext.mounted) return;
                        setModalState(() {});
                      });
                    }

                    final String bodyText;
                    if (errorText != null && errorText!.trim().isNotEmpty) {
                      bodyText = '翻译失败：$errorText';
                    } else if (!done) {
                      bodyText = 'ai翻译中...';
                    } else {
                      bodyText = translation.isEmpty ? '（无译文）' : translation;
                    }

                    final canCopyTranslation = done &&
                        errorText == null &&
                        translation.trim().isNotEmpty;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.translate,
                                color: AppColors.techBlue),
                            const SizedBox(width: 8),
                            Text(
                              '翻译',
                              style: TextStyle(
                                color: panelText,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              icon: Icon(Icons.close,
                                  color: panelText.withOpacity(0.7)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t,
                                  style: TextStyle(
                                    color: panelText.withOpacity(0.78),
                                    height: 1.5,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: panelText.withOpacity(0.04),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: panelText.withOpacity(0.08),
                                      width: AppTokens.stroke,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(14),
                                  child: Text(
                                    bodyText,
                                    style: TextStyle(
                                      color: panelText,
                                      height: 1.5,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: t));
                                  ScaffoldMessenger.of(sheetContext)
                                      .showSnackBar(
                                    const SnackBar(content: Text('已复制原文')),
                                  );
                                },
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('复制原文'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: canCopyTranslation
                                    ? () {
                                        Clipboard.setData(
                                            ClipboardData(text: translation));
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                              content: Text('已复制译文')),
                                        );
                                      }
                                    : null,
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('复制译文'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.techBlue,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _explainSelectedText(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _openAiHud(
      initialRoute: AiHudRoute.qa,
      initialQaText: '解释：$t',
      autoSendInitialQa: true,
    );
  }

  void _hideControls() {
    if (!_showControls) return;

    // Do not drop hide requests during animation; always converge to hidden state.
    setState(() {
      _showControls = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Reverse even while animating forward; this prevents occasional "stuck visible".
    _controlsController.reverse();
  }

  Future<void> _setAiTranslateEnabled({
    required TranslationProvider provider,
    required bool enabled,
  }) async {
    if (!mounted) return;
    await provider.setAiTranslateEnabled(enabled);

    if (!enabled) {
      _translationFutures.clear();
      _stopContinuousPrefetch();
      setState(() {});
    }
    if (enabled) {
      _stopContinuousPrefetch();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final next = _nextParagraphsForPrefetch(count: 10);
        provider.prefetchParagraphs(next);
        _updatePrefetchCursorFromVisible();
        _startContinuousPrefetch();
      });
    }
  }

  Future<void> _setAiReadAloudEnabled({
    required TranslationProvider provider,
    required bool enabled,
  }) async {
    if (!mounted) return;

    await provider.setAiReadAloudEnabled(enabled);

    if (!enabled) {
      setState(() {
        _aiReadAloudPlaying = false;
      });
      _readAloudAnimController.stop();
      _readAloudAnimController.reset();
      await _stopReadAloud();
    }
  }

  String _readAloudTextForCurrentPage({int maxChars = 150}) {
    final paragraphs = _currentPageParagraphsByIndex();
    final raw = paragraphs.values.join('\n');
    final t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '';
    return t.length > maxChars ? t.substring(0, maxChars) : t;
  }

  Future<bool> _startReadAloud() async {
    final source = context.read<AiModelProvider>().source;
    if (source != AiModelSource.online) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('朗读仅支持在线模式')),
      );
      return false;
    }

    final ttsCfg = context.read<TranslationProvider>();
    final text = _readAloudTextForCurrentPage();
    if (text.isEmpty) return false;

    final voiceType = ttsCfg.ttsVoiceType;
    final speed = ttsCfg.ttsSpeed;
    final key =
        '$_currentChapterIndex|$_currentPageInChapter|${text.hashCode}|$voiceType|${speed.toStringAsFixed(2)}';
    try {
      setState(() {
        _aiReadAloudPlaying = true;
      });
      _readAloudAnimController.repeat(reverse: true);

      if (_readAloudAudioKey != key) {
        _readAloudAudioKey = key;
        await _readAloudPlayer.stop();

        final cached = _readAloudAudioCache[key];
        if (cached != null) {
          await _readAloudPlayer.play(BytesSource(cached));
          return true;
        }

        final client = TencentTtsClient(
          credentials: getEmbeddedPublicHunyuanCredentials(),
        );
        final res = await client.textToVoice(
          text: text,
          voiceType: voiceType > 0 ? voiceType : null,
          speed: speed,
        );
        final bytes = base64Decode(res.audioBase64);
        _readAloudAudioCache[key] = bytes;
        await _readAloudPlayer.play(BytesSource(bytes));
        return true;
      }

      await _readAloudPlayer.resume();
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _aiReadAloudPlaying = false;
      });
      _readAloudAnimController.stop();
      _readAloudAnimController.reset();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('朗读失败：$e')));
      return false;
    }
  }

  Future<void> _pauseReadAloud() async {
    setState(() {
      _aiReadAloudPlaying = false;
    });
    _readAloudAnimController.stop();
    _readAloudAnimController.reset();
    await _readAloudPlayer.pause();
  }

  Future<void> _stopReadAloud() async {
    setState(() {
      _aiReadAloudPlaying = false;
    });
    _readAloudAnimController.stop();
    _readAloudAnimController.reset();
    _readAloudAudioKey = '';
    await _readAloudPlayer.stop();
  }

  Widget _buildReadAloudFloatingButton() {
    if (_isLoading || _error != null) return const SizedBox.shrink();
    if (!context.watch<TranslationProvider>().aiReadAloudEnabled) {
      return const SizedBox.shrink();
    }

    final Color surface = _panelBgColor;
    final Color onSurface = _panelTextColor;

    return Positioned(
      right: 14,
      bottom: (_contentBottomInset ?? 0) + 120,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 160),
        scale:
            context.watch<TranslationProvider>().aiReadAloudEnabled ? 1 : 0.9,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(999),
          surfaceColor: surface,
          opacity: 0.86,
          border: Border.all(
              color: onSurface.withOpacity(0.08), width: AppTokens.stroke),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              if (_aiReadAloudPlaying) {
                _pauseReadAloud();
              } else {
                _startReadAloud();
              }
            },
            child: SizedBox(
              width: 48,
              height: 48,
              child: AnimatedBuilder(
                animation: _readAloudAnimController,
                builder: (context, child) {
                  // Breathing effect: scale between 1.0 and 1.2
                  final scale = 1.0 + (_readAloudAnimController.value * 0.2);
                  return Transform.scale(
                    scale: scale,
                    child: child,
                  );
                },
                child: Icon(
                  Icons.volume_up_rounded,
                  color: _aiReadAloudPlaying
                      ? AppColors.techBlue
                      : onSurface.withOpacity(0.5),
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
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

  // Helper to construct the text to be rendered/measured based on available translations
  String _getEffectiveTextForChapter(int chapterIndex, TranslationProvider tp) {
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (!tp.applyToReader) return plainText;

    // Generate a hash of current translation state for this chapter
    // This is an optimization to avoid rebuilding the string if nothing changed
    // Ideally we track which paragraphs have translations.
    // Since we don't have a cheap way to know "version" of translations,
    // we construct the string and cache it if same.

    // We only include translations that are CACHED.
    // If not cached, we use original text.

    final paragraphs = _getParagraphsForChapter(chapterIndex, plainText);
    final buffer = StringBuffer();
    final bool isBilingual =
        tp.config.displayMode == TranslationDisplayMode.bilingual;
    final bool isTransOnly =
        tp.config.displayMode == TranslationDisplayMode.translationOnly;

    // Use string buffer
    for (int i = 0; i < paragraphs.length; i++) {
      final p = paragraphs[i];
      final trans = tp.getCachedTranslation(p.text);
      final pending = tp.isTranslationPending(p.text);
      final failed = tp.isTranslationFailed(p.text);

      // Add indentation if not title
      final bool isTitle = i == 0;
      final String indent = isTitle ? '' : '　　';

      if (trans != null && trans.isNotEmpty) {
        if (isTransOnly) {
          buffer.write('$indent$trans');
        } else {
          // Bilingual
          buffer.write(p.text); // Original already has indent
          buffer.write('\n');
          buffer.write('$indent$trans');
        }
      } else if (pending) {
        if (isTransOnly) {
          buffer.write(p.text);
          buffer.write('\n');
          buffer.write('${indent}AI 正在翻译…');
        } else if (isBilingual) {
          buffer.write(p.text);
          buffer.write('\n');
          buffer.write('${indent}AI 正在翻译…');
        } else {
          buffer.write(p.text);
        }
      } else if (failed) {
        // 翻译失败，显示原文和失败提示
        if (isTransOnly) {
          buffer.write(p.text);
          buffer.write('\n');
          buffer.write('$indent翻译失败');
        } else if (isBilingual) {
          buffer.write(p.text);
          buffer.write('\n');
          buffer.write('$indent翻译失败');
        } else {
          buffer.write(p.text);
        }
      } else {
        // No translation yet
        buffer.write(p.text); // Original already has indent
      }

      if (i < paragraphs.length - 1) {
        buffer.write('\n\n');
      }
    }

    return buffer.toString();
  }

  TextSpan _buildReaderSpan({
    required String text,
    required TextStyle bodyStyle,
  }) {
    const marker = 'AI 正在翻译…';
    const int markerLen = marker.length;
    const paraSep = '\n\n';

    final List<InlineSpan> children = [];

    final placeholderStyle = bodyStyle.copyWith(
      fontStyle: FontStyle.italic,
      fontSize: bodyStyle.fontSize == null ? null : bodyStyle.fontSize! * 0.92,
      color: (bodyStyle.color ?? _textColor).withOpacity(0.55),
    );

    final gapStyle = bodyStyle.copyWith(
      height: 0.6,
      fontSize:
          bodyStyle.fontSize == null ? null : (bodyStyle.fontSize! * 0.58),
    );

    int i = 0;
    while (i < text.length) {
      final idxMarker = text.indexOf(marker, i);
      final idxPara = text.indexOf(paraSep, i);

      int nextIdx = -1;
      bool nextIsMarker = false;
      bool nextIsPara = false;

      if (idxMarker >= 0) {
        nextIdx = idxMarker;
        nextIsMarker = true;
      }
      if (idxPara >= 0 && (nextIdx == -1 || idxPara < nextIdx)) {
        nextIdx = idxPara;
        nextIsMarker = false;
        nextIsPara = true;
      }

      if (nextIdx < 0) {
        children.add(TextSpan(text: text.substring(i), style: bodyStyle));
        break;
      }

      if (nextIdx > i) {
        children
            .add(TextSpan(text: text.substring(i, nextIdx), style: bodyStyle));
      }

      if (nextIsPara) {
        children.add(TextSpan(text: '\n', style: bodyStyle));
        children.add(TextSpan(text: '\n', style: gapStyle));
        i = nextIdx + paraSep.length;
        continue;
      }

      if (nextIsMarker) {
        final end = (nextIdx + markerLen).clamp(0, text.length);
        children.add(
          TextSpan(text: text.substring(nextIdx, end), style: placeholderStyle),
        );
        i = end;
        continue;
      }

      i = nextIdx + 1;
    }

    return TextSpan(children: children, style: bodyStyle);
  }

  void _ensureTextPaginationForChapter({
    required int chapterIndex,
    required double viewportHeight,
    required double contentWidth,
  }) {
    // 1. Get Base Text (Original)
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) {
      _chapterPageRanges[chapterIndex] = [const TextRange(start: 0, end: 0)];
      _chapterPageCounts[chapterIndex] = 1;
      return;
    }

    // 2. Determine "Effective" Text (Mixed with Translation)
    final tp = Provider.of<TranslationProvider>(context, listen: false);
    String effectiveText = plainText;

    // If translation is active, we need to construct the mixed text
    // We check if we need to update our cached effective text
    // A simple heuristic: check if we have any new translations for this chapter?
    // Or just re-construct it every time we paginate (pagination is expensive anyway)

    if (tp.applyToReader) {
      effectiveText = _getEffectiveTextForChapter(chapterIndex, tp);
    }

    _chapterEffectiveText[chapterIndex] = effectiveText;

    final dpr = MediaQuery.of(context).devicePixelRatio;
    String snapKey(double v) => (v * dpr).roundToDouble().toStringAsFixed(0);
    final String paginationKey =
        'v2|${snapKey(contentWidth)}|${snapKey(viewportHeight)}|${_fontSize.toStringAsFixed(2)}|${_lineHeight.toStringAsFixed(2)}|${effectiveText.length}|${_contentBottomInset?.toStringAsFixed(1) ?? '0'}';

    if (_chapterPageRangeKeys[chapterIndex] == paginationKey &&
        _chapterPageRanges[chapterIndex] != null) {
      return;
    }

    if (tp.applyToReader && _chapterPageRanges[chapterIndex] != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _chapterPaginationLastMs[chapterIndex] ?? 0;
      if (now - last < 450) {
        return;
      }
      _chapterPaginationLastMs[chapterIndex] = now;
    }

    // ... (rest of logic uses effectiveText instead of text)
    final text = effectiveText; // Use effective text

    final TextStyle effectiveTextStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: _lineHeight,
      fontSize: _fontSize,
      color: _textColor,
    );

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.of(context).textScaler,
      strutStyle:
          StrutStyle.fromTextStyle(effectiveTextStyle, forceStrutHeight: true),
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
        // _buildStyledSpanForRange needs to handle mixed text too?
        // Actually, since we constructed effectiveText, we just style it uniformly?
        // Wait, Title logic relies on _chapterTitleLength of ORIGINAL text.
        // If effective text has changed, title length might be different (if title translated).
        // For simplicity, let's treat title styling as "First N chars of effective text if first paragraph".
        // Or simpler: Just style the whole thing as body for now, or detect first newline.

        textPainter.text = _buildReaderSpan(
          text: text.substring(start, mid),
          bodyStyle: effectiveTextStyle,
        );

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
    _chapterPaginationLastMs[chapterIndex] =
        DateTime.now().millisecondsSinceEpoch;
    final int pageCount = ranges.isEmpty ? 1 : ranges.length;
    _chapterPageCounts[chapterIndex] = pageCount;
    if (chapterIndex == _currentChapterIndex) {
      if (_currentPageInChapter >= pageCount) {
        _currentPageInChapter = pageCount - 1;
      }
    }
  }

  void _ensurePlainTextPaginationForChapter({
    required int chapterIndex,
    required double viewportHeight,
    required double contentWidth,
  }) {
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) {
      _chapterPlainPageRanges[chapterIndex] = [
        const TextRange(start: 0, end: 0)
      ];
      return;
    }

    final dpr = MediaQuery.of(context).devicePixelRatio;
    String snapKey(double v) => (v * dpr).roundToDouble().toStringAsFixed(0);
    final String paginationKey =
        'v2|${snapKey(contentWidth)}|${snapKey(viewportHeight)}|${_fontSize.toStringAsFixed(2)}|${_lineHeight.toStringAsFixed(2)}|${plainText.length}|${_contentBottomInset?.toStringAsFixed(1) ?? '0'}';

    if (_chapterPlainPageRangeKeys[chapterIndex] == paginationKey &&
        _chapterPlainPageRanges[chapterIndex] != null) {
      return;
    }

    final TextStyle textStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: _lineHeight,
      fontSize: _fontSize,
      color: _textColor,
    );

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.of(context).textScaler,
      strutStyle: StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true),
    );

    final List<TextRange> ranges = [];
    int start = 0;
    final int len = plainText.length;

    while (start < len) {
      int low = start + 1;
      int high = len;
      int best = low;

      while (low <= high) {
        final int mid = (low + high) >> 1;
        textPainter.text = _buildReaderSpan(
          text: plainText.substring(start, mid),
          bodyStyle: textStyle,
        );
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
      while (start < len && plainText.codeUnitAt(start) == 10) {
        start++;
      }
    }

    _chapterPlainPageRanges[chapterIndex] = ranges;
    _chapterPlainPageRangeKeys[chapterIndex] = paginationKey;
  }

  void _invalidatePagination() {
    _chapterPageCounts.clear();
    _chapterPageRanges.clear();
    _chapterPageRangeKeys.clear();
    _chapterPlainPageRanges.clear();
    _chapterPlainPageRangeKeys.clear();
  }

  int _plainPageIndexForProgress(int chapterIndex, double progress) {
    final ranges = _chapterPlainPageRanges[chapterIndex];
    if (ranges == null || ranges.isEmpty) return 0;

    final plainText = _getPlainTextForChapter(chapterIndex);
    final len = plainText.length;
    if (len <= 0) return 0;

    final int target = (progress.clamp(0.0, 1.0) * len).round().clamp(0, len);

    int low = 0;
    int high = ranges.length - 1;
    int best = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final r = ranges[mid];
      if (target < r.start) {
        high = mid - 1;
      } else if (target >= r.end) {
        low = mid + 1;
        best = mid;
      } else {
        best = mid;
        break;
      }
    }
    return best.clamp(0, ranges.length - 1);
  }

  void _relocateCurrentPageToProgress(double progress) {
    final ranges = _chapterPageRanges[_currentChapterIndex];
    if (ranges == null || ranges.isEmpty) return;

    final effectiveText = _chapterEffectiveText[_currentChapterIndex] ??
        _getPlainTextForChapter(_currentChapterIndex);
    final len = effectiveText.length;
    if (len <= 0) return;

    final int target = (progress.clamp(0.0, 1.0) * len).round().clamp(0, len);

    int low = 0;
    int high = ranges.length - 1;
    int best = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final r = ranges[mid];
      if (target < r.start) {
        high = mid - 1;
      } else if (target >= r.end) {
        low = mid + 1;
        best = mid;
      } else {
        best = mid;
        break;
      }
    }

    _currentPageInChapter = best.clamp(0, ranges.length - 1);
  }

  void _scheduleRelocateAfterTranslationChange(TranslationProvider tp) {
    final apply = tp.applyToReader;
    final mode = tp.config.displayMode;
    if (_lastTranslationApplyToReader == null ||
        _lastTranslationDisplayMode == null) {
      _lastTranslationApplyToReader = apply;
      _lastTranslationDisplayMode = mode;
      return;
    }

    final changed = _lastTranslationApplyToReader != apply ||
        _lastTranslationDisplayMode != mode;
    _lastTranslationApplyToReader = apply;
    _lastTranslationDisplayMode = mode;
    if (!changed) return;
    if (_relocateAfterTranslationChangeScheduled) return;

    final anchor = _currentPageProgressInChapter;
    _relocateAfterTranslationChangeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _relocateCurrentPageToProgress(anchor);
        _pageViewCenterIndex = 1000;
      });
      if (_pageController.hasClients) {
        _pageController.jumpToPage(1000);
      }
      _relocateAfterTranslationChangeScheduled = false;
    });
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
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (context) {
        return GlassPanel.sheet(
          surfaceColor: _panelBgColor,
          child: Container(
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
                            _pageViewCenterIndex = 1000;
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
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (context) {
        return GlassPanel.sheet(
          surfaceColor: _panelBgColor,
          child: StatefulBuilder(
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
                            style: TextStyle(
                                fontSize: 16, color: _panelTextColor)),
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
                            style: TextStyle(
                                fontSize: 20, color: _panelTextColor)),
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
          ),
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
            final int diff = index - _pageViewCenterIndex;
            if (diff == 0) return;
            setState(() {
              _pageViewCenterIndex = index;

              final int steps = diff.abs();
              for (int s = 0; s < steps; s++) {
                if (diff > 0) {
                  _currentPageInChapter++;
                  int total = _pageCountForChapter(_currentChapterIndex);
                  if (_currentPageInChapter >= total) {
                    if (_currentChapterIndex < _chapters.length - 1) {
                      _currentChapterIndex++;
                      _currentPageInChapter = 0;
                    } else {
                      _currentPageInChapter--;
                    }
                  }
                } else {
                  _currentPageInChapter--;
                  if (_currentPageInChapter < 0) {
                    if (_currentChapterIndex > 0) {
                      _currentChapterIndex--;
                      int prevCount =
                          _pageCountForChapter(_currentChapterIndex);
                      _currentPageInChapter = prevCount - 1;
                    } else {
                      _currentPageInChapter++;
                    }
                  }
                }
              }
            });
            _saveProgressDebounced();

            final translationProvider =
                Provider.of<TranslationProvider>(context, listen: false);
            if (translationProvider.applyToReader) {
              _stopContinuousPrefetch();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _updatePrefetchCursorFromVisible();
                _startContinuousPrefetch();
              });
            }

            // Force jump back to center to allow infinite scroll

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_pageController.hasClients) {
                if (mounted && _pageViewCenterIndex != 1000) {
                  setState(() {
                    _pageViewCenterIndex = 1000;
                  });
                }
                _pageController.jumpToPage(1000);
              }
            });
          },
          itemBuilder: (context, index) {
            if (index == _pageViewCenterIndex) {
              return _buildSinglePage(
                  _currentChapterIndex, _currentPageInChapter, padding);
            }

            final int diff = index - _pageViewCenterIndex;

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
        double snapDown(double value) => (value * dpr).floorToDouble() / dpr;

        final double topMargin = snap(padding.top + 16);
        final double bottomMargin = snap(padding.bottom + 24);

        double viewportHeight = snapDown(
          constraints.maxHeight - topMargin - bottomMargin - (1 / dpr),
        );
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

        _lastPaginationViewportHeight = viewportHeight;
        _lastPaginationContentWidth = contentWidth;

        _ensurePlainTextPaginationForChapter(
          chapterIndex: chapterIndex,
          viewportHeight: viewportHeight,
          contentWidth: contentWidth,
        );

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
        final isCurrentPage = chapterIndex == _currentChapterIndex &&
            safeIndex == _currentPageInChapter;

        // Use EFFECTIVE TEXT, not plain text
        final String effectiveText = _chapterEffectiveText[chapterIndex] ??
            _getPlainTextForChapter(chapterIndex);

        if (chapterIndex == _currentChapterIndex &&
            pageIndex == _currentPageInChapter) {
          final len = effectiveText.length;
          _currentPageProgressInChapter = len > 0 ? range.start / len : 0;
        }

        if (range.start >= effectiveText.length) {
          return const SizedBox.shrink();
        }
        final int end = range.end.clamp(0, effectiveText.length);

        // For mixed text, we just style it as body, title logic is too complex to preserve for now
        final TextSpan span = _buildReaderSpan(
          text: effectiveText.substring(range.start, end),
          bodyStyle: effectiveTextStyle,
        );

        return Stack(
          children: [
            Positioned(
              top: topMargin,
              left: 0,
              right: 0,
              bottom: bottomMargin,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) => _onReaderPointerDown(e.localPosition),
                onPointerMove: (e) => _onReaderPointerMove(e.localPosition),
                onPointerUp: (e) => _onReaderPointerUp(
                    pos: e.localPosition, width: constraints.maxWidth),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildPageBody(
                      chapterIndex: chapterIndex,
                      range: range,
                      end: end,
                      effectiveText: effectiveText,
                      bodySpan: span,
                      bodyStyle: effectiveTextStyle,
                      isCurrentPage: isCurrentPage,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPageBody({
    required int chapterIndex,
    required TextRange range,
    required int end,
    required String effectiveText, // Now using effective text
    required TextSpan bodySpan,
    required TextStyle bodyStyle,
    required bool isCurrentPage,
  }) {
    final translationProvider = Provider.of<TranslationProvider>(context);

    // If we are in translation mode, we trigger translation requests for *visible* paragraphs.
    // But we RENDER what we have in effectiveText (which includes Cached Translations).

    if (translationProvider.applyToReader && isCurrentPage) {
      final plainText = _getPlainTextForChapter(chapterIndex);
      final allParas = _getParagraphsForChapter(chapterIndex, plainText);

      if (allParas.isNotEmpty) {
        final visible = chapterIndex == _currentChapterIndex
            ? _currentPageParagraphsByIndex()
            : const <int, String>{};
        final sorted = visible.keys.toList()..sort();
        final int startIdx = sorted.isEmpty ? 0 : sorted.first;
        final int lastVisibleIdx = sorted.isEmpty ? 0 : sorted.last;
        const int extraCount = 10;
        final int endIdx =
            (lastVisibleIdx + extraCount).clamp(0, allParas.length - 1);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          final Map<int, String> toRequest = {};
          for (int i = startIdx; i <= endIdx; i++) {
            final t = allParas[i].text;
            if (translationProvider.getCachedTranslation(t) != null) continue;
            if (translationProvider.isTranslationPending(t)) continue;
            if (translationProvider.isTranslationFailed(t)) continue;
            toRequest[i] = t;
          }

          final int remainingExtra = extraCount -
              ((allParas.length - 1) - lastVisibleIdx)
                  .clamp(0, extraCount)
                  .toInt();
          if (remainingExtra > 0 && chapterIndex < _chapters.length - 1) {
            final nextChapterIdx = chapterIndex + 1;
            final nextText = _chapterPlainText[nextChapterIdx];
            if (nextText != null && nextText.isNotEmpty) {
              final nextParas =
                  _getParagraphsForChapter(nextChapterIdx, nextText);
              for (int i = 0; i < nextParas.length && i < remainingExtra; i++) {
                final t = nextParas[i].text;
                if (translationProvider.getCachedTranslation(t) != null) {
                  continue;
                }
                if (translationProvider.isTranslationPending(t)) continue;
                if (translationProvider.isTranslationFailed(t)) continue;
                toRequest[100000 + i] = t;
              }
            } else {
              _ensureChapterContentCached(nextChapterIdx);
            }
          }

          if (toRequest.isNotEmpty) {
            translationProvider.requestTranslationForParagraphs(toRequest);
          }
        });
      }
    }

    return SizedBox(
      width: double.infinity,
      child: SelectableText.rich(
        bodySpan,
        style: bodyStyle,
        strutStyle: StrutStyle.fromTextStyle(bodyStyle, forceStrutHeight: true),
        contextMenuBuilder: (context, state) {
          final selection = state.textEditingValue.selection;
          final hasSelection = !selection.isCollapsed;
          final selectedText = hasSelection
              ? state.textEditingValue.text
                  .substring(selection.start, selection.end)
                  .trim()
              : '';

          final isDarkBg = _bgColor.computeLuminance() < 0.5;
          final toolbarBg = isDarkBg
              ? Colors.white.withOpacity(0.94)
              : AppColors.deepSpace.withOpacity(0.92);
          final toolbarFg = isDarkBg ? AppColors.deepSpace : Colors.white;
          final disabledFg = toolbarFg.withOpacity(0.38);
          final baseTheme = Theme.of(context);
          final themed = baseTheme.copyWith(
            colorScheme: baseTheme.colorScheme.copyWith(
              surface: toolbarBg,
              onSurface: toolbarFg,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: toolbarFg,
                disabledForegroundColor: disabledFg,
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          );

          return Theme(
            data: themed,
            child: AdaptiveTextSelectionToolbar(
              anchors: state.contextMenuAnchors,
              children: [
                ...() {
                  final aiModel = context.watch<AiModelProvider>();
                  final source = aiModel.source;
                  final bool showTranslate = source != AiModelSource.local ||
                      aiModel.isLocalTranslationModelReady;
                  final bool showExplain = source != AiModelSource.local ||
                      aiModel.isLocalQaModelReady;
                  return [
                    TextButton(
                      onPressed: () {
                        state.copySelection(SelectionChangedCause.toolbar);
                        state.hideToolbar();
                      },
                      child: const Text('复制'),
                    ),
                    if (showTranslate)
                      TextButton(
                        onPressed: selectedText.isEmpty
                            ? null
                            : () async {
                                state.hideToolbar();
                                await _translateSelectedText(selectedText);
                              },
                        child: const Text('翻译'),
                      ),
                    if (showExplain)
                      TextButton(
                        onPressed: selectedText.isEmpty
                            ? null
                            : () {
                                state.hideToolbar();
                                _explainSelectedText(selectedText);
                              },
                        child: const Text('解释'),
                      ),
                  ];
                }(),
              ],
            ),
          );
        },
      ),
    );
  }

  Map<int, String> _paragraphsByIndexForRange({
    required int chapterIndex,
    required String plainText,
    required int start,
    required int end,
  }) {
    final paras = _getParagraphsForChapter(chapterIndex, plainText);
    final Map<int, String> out = {};
    for (final p in paras) {
      if (p.end <= start) continue;
      if (p.start >= end) break;
      if (p.start < end && p.end > start) {
        out[p.index] = p.text;
      }
    }
    return out;
  }

  List<ReaderParagraph> _getParagraphsForChapter(
      int chapterIndex, String plainText) {
    final cached = _chapterParagraphsCache[chapterIndex];
    if (cached != null) return cached;

    final List<ReaderParagraph> out = [];
    final matches = RegExp(r'\n{2,}').allMatches(plainText).toList();

    int start = 0;
    int idx = 0;

    for (final m in matches) {
      final end = m.start;
      final raw = plainText.substring(start, end);
      final cleaned =
          raw.replaceAll(RegExp(r'^\n+'), '').replaceAll(RegExp(r'\n+$'), '');
      if (cleaned.trim().isNotEmpty) {
        out.add(
            ReaderParagraph(index: idx, start: start, end: end, text: cleaned));
        idx++;
      }
      start = m.end;
    }

    if (start < plainText.length) {
      final raw = plainText.substring(start);
      final cleaned =
          raw.replaceAll(RegExp(r'^\n+'), '').replaceAll(RegExp(r'\n+$'), '');
      if (cleaned.trim().isNotEmpty) {
        out.add(ReaderParagraph(
            index: idx, start: start, end: plainText.length, text: cleaned));
      }
    }

    _chapterParagraphsCache[chapterIndex] = out;
    return out;
  }

  Map<int, String> _currentPageParagraphsByIndex() {
    final ranges = _chapterPlainPageRanges[_currentChapterIndex];
    if (ranges == null || ranges.isEmpty) return {};

    final plainText = _getPlainTextForChapter(_currentChapterIndex);
    if (plainText.isEmpty) return {};

    final safeIndex = _plainPageIndexForProgress(
      _currentChapterIndex,
      _currentPageProgressInChapter,
    );
    final range = ranges[safeIndex];
    final end = range.end.clamp(0, plainText.length);

    return _paragraphsByIndexForRange(
      chapterIndex: _currentChapterIndex,
      plainText: plainText,
      start: range.start,
      end: end,
    );
  }

  List<String> _nextParagraphsForPrefetch({required int count}) {
    final List<String> out = [];

    // 1. Try fetching from current chapter
    final currentParas = _getParagraphsForChapter(
        _currentChapterIndex, _getPlainTextForChapter(_currentChapterIndex));

    // Find indices currently visible on screen
    final currentVisible = _currentPageParagraphsByIndex();
    final visibleSorted = currentVisible.keys.toList()..sort();
    final int firstVisibleIdx = visibleSorted.isEmpty ? 0 : visibleSorted.first;
    final int lastVisibleIdx = visibleSorted.isEmpty ? -1 : visibleSorted.last;

    for (int i = firstVisibleIdx;
        i <= lastVisibleIdx && i < currentParas.length && out.length < count;
        i++) {
      out.add(currentParas[i].text);
    }

    // Add subsequent paragraphs from current chapter
    for (int i = lastVisibleIdx + 1;
        i < currentParas.length && out.length < count;
        i++) {
      out.add(currentParas[i].text);
    }

    // 2. If we still need more and have a next chapter, fetch from there
    if (out.length < count && _currentChapterIndex < _chapters.length - 1) {
      final nextChapterIdx = _currentChapterIndex + 1;
      // Ensure content is loaded (this might be async, so we might miss it on first pass,
      // but usually prefetch is fire-and-forget. We can only prefetch if content is in cache)
      // If not in cache, we skip.
      final nextText = _chapterPlainText[nextChapterIdx];
      if (nextText != null && nextText.isNotEmpty) {
        final nextParas = _getParagraphsForChapter(nextChapterIdx, nextText);
        for (int i = 0; i < nextParas.length && out.length < count; i++) {
          out.add(nextParas[i].text);
        }
      } else {
        // Trigger load for next chapter so next time we can prefetch
        _ensureChapterContentCached(nextChapterIdx);
      }
    }

    return out;
  }

  void _startContinuousPrefetch() {
    _continuousPrefetchTimer?.cancel();
    _continuousPrefetchTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) {
        _runContinuousPrefetchTick();
      },
    );
  }

  void _stopContinuousPrefetch() {
    _continuousPrefetchTimer?.cancel();
    _continuousPrefetchTimer = null;
    _prefetchCursorChapterIndex = null;
    _prefetchCursorParagraphIndex = 0;
    _prefetchTickRunning = false;
  }

  void _updatePrefetchCursorFromVisible() {
    final currentParas = _getParagraphsForChapter(
      _currentChapterIndex,
      _getPlainTextForChapter(_currentChapterIndex),
    );
    if (currentParas.isEmpty) return;

    final currentVisible = _currentPageParagraphsByIndex();
    int lastVisibleIdx = -1;
    if (currentVisible.isNotEmpty) {
      lastVisibleIdx = (currentVisible.keys.toList()..sort()).last;
    }

    final chapterCursor = _prefetchCursorChapterIndex;
    if (chapterCursor == null || chapterCursor < _currentChapterIndex) {
      _prefetchCursorChapterIndex = _currentChapterIndex;
      _prefetchCursorParagraphIndex =
          (lastVisibleIdx + 1).clamp(0, currentParas.length);
      return;
    }

    if (chapterCursor == _currentChapterIndex) {
      final nextIdx = (lastVisibleIdx + 1).clamp(0, currentParas.length);
      if (nextIdx > _prefetchCursorParagraphIndex) {
        _prefetchCursorParagraphIndex = nextIdx;
      }
    }
  }

  Future<void> _runContinuousPrefetchTick() async {
    if (_prefetchTickRunning) return;
    _prefetchTickRunning = true;
    try {
      if (!mounted) return;
      final tp = Provider.of<TranslationProvider>(context, listen: false);
      if (!tp.applyToReader) {
        _stopContinuousPrefetch();
        return;
      }
      final source = context.read<AiModelProvider>().source;
      if (source != AiModelSource.local) {
        _stopContinuousPrefetch();
        return;
      }

      int chapterIndex = _prefetchCursorChapterIndex ?? _currentChapterIndex;
      int paragraphIndex = _prefetchCursorParagraphIndex;
      final out = <String>[];

      while (out.length < 10 && chapterIndex < _chapters.length) {
        final plainText = _getPlainTextForChapter(chapterIndex);
        if (plainText.isEmpty) {
          _ensureChapterContentCached(chapterIndex);
          break;
        }
        final paras = _getParagraphsForChapter(chapterIndex, plainText);
        if (paras.isEmpty) {
          chapterIndex++;
          paragraphIndex = 0;
          continue;
        }

        int i = paragraphIndex.clamp(0, paras.length);
        for (; i < paras.length && out.length < 10; i++) {
          final t = paras[i].text;
          if (tp.getCachedTranslation(t) != null) continue;
          if (tp.isTranslationPending(t)) continue;
          if (tp.isTranslationFailed(t)) continue;
          out.add(t);
        }

        if (i >= paras.length) {
          chapterIndex++;
          paragraphIndex = 0;
        } else {
          paragraphIndex = i;
        }
      }

      _prefetchCursorChapterIndex = chapterIndex;
      _prefetchCursorParagraphIndex = paragraphIndex;

      if (out.isNotEmpty) {
        await tp.prefetchParagraphs(out);
        return;
      }

      if (chapterIndex >= _chapters.length) {
        _stopContinuousPrefetch();
      }
    } finally {
      _prefetchTickRunning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<TranslationProvider>();
    _scheduleRelocateAfterTranslationChange(tp);

    // IMPORTANT: Get padding from MediaQuery BEFORE removing it
    final mq = MediaQuery.of(context);
    final padding = mq.padding;
    final viewPadding = mq.viewPadding;
    final systemGestureInsets = mq.systemGestureInsets;
    double contentTopInset = viewPadding.top;
    if (padding.top > contentTopInset) contentTopInset = padding.top;

    double contentBottomInset = viewPadding.bottom;
    if (padding.bottom > contentBottomInset) {
      contentBottomInset = padding.bottom;
    }
    if (systemGestureInsets.bottom > contentBottomInset) {
      contentBottomInset = systemGestureInsets.bottom;
    }
    _contentBottomInset = contentBottomInset;

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
        _pageViewCenterIndex = 1000;
      }
    } catch (e) {
      _pageController = PageController(initialPage: 1000);
      _pageViewCenterIndex = 1000;
    }
    readerContent = _buildHorizontalMode(
      EdgeInsets.only(
        top: contentTopInset,
        bottom: contentBottomInset,
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: barColor,
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
                  height: contentTopInset + 64,
                  padding: EdgeInsets.only(
                      top: contentTopInset + 8, left: 16, right: 16),
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
                        bottom: contentBottomInset + 24,
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
                            _openAiHud();
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

              _buildReadAloudFloatingButton(),
            ],
          ),
        ),
      ),
    );
  }
}
