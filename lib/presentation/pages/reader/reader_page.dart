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
import 'tts_web_speech.dart'
    if (dart.library.js_interop) 'tts_web_speech_web.dart';

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

abstract class _ReaderChapter {
  String? get title;
  Future<String> readHtmlContent();
}

class _EpubReaderChapter implements _ReaderChapter {
  final EpubChapterRef ref;
  final String? _titleOverride;
  _EpubReaderChapter(this.ref, {String? titleOverride})
      : _titleOverride = titleOverride;

  @override
  String? get title => _titleOverride ?? ref.Title;

  @override
  Future<String> readHtmlContent() => ref.readHtmlContent();
}

class _TextReaderChapter implements _ReaderChapter {
  final String _title;
  final String _sourceText;
  final int _start;
  final int _end;

  _TextReaderChapter({
    required String title,
    required String sourceText,
    required int start,
    required int end,
  })  : _title = title,
        _sourceText = sourceText,
        _start = start,
        _end = end;

  @override
  String? get title => _title;

  @override
  Future<String> readHtmlContent() async => '';

  Future<String> readPlainText() async {
    final buffer = StringBuffer();
    final titleText = _title.trim().isEmpty ? '正文' : _title.trim();
    buffer.write(titleText);

    final int start = _start.clamp(0, _sourceText.length);
    final int end = _end.clamp(start, _sourceText.length);
    if (start >= end) return buffer.toString();

    final paraBuffer = StringBuffer();
    String? prevLineInPara;
    int processedLines = 0;

    void flushPara() {
      if (paraBuffer.isEmpty) return;
      buffer.write('\n\n');
      buffer.write('　　');
      buffer.write(paraBuffer.toString());
      paraBuffer.clear();
      prevLineInPara = null;
    }

    int i = start;
    while (i < end) {
      int lineStart = i;
      int lineEnd = i;
      while (lineEnd < end) {
        final int cu = _sourceText.codeUnitAt(lineEnd);
        if (cu == 10 || cu == 13) break;
        lineEnd++;
      }

      int next = lineEnd;
      if (next < end) {
        final int cu = _sourceText.codeUnitAt(next);
        if (cu == 13) {
          next++;
          if (next < end && _sourceText.codeUnitAt(next) == 10) {
            next++;
          }
        } else if (cu == 10) {
          next++;
        }
      }

      final rawLine = _sourceText.substring(lineStart, lineEnd);
      final t = rawLine.trim();

      if (t.isEmpty) {
        flushPara();
      } else {
        if (paraBuffer.isNotEmpty) {
          final glue =
              (prevLineInPara != null && _isCjk(prevLineInPara!) && _isCjk(t))
                  ? ''
                  : ' ';
          paraBuffer.write(glue);
        }
        paraBuffer.write(t);
        prevLineInPara = t;
      }

      processedLines++;
      if (processedLines % 300 == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      i = next;
    }

    flushPara();
    return buffer.toString();
  }

  bool _isCjk(String s) {
    return RegExp(r'[\u4E00-\u9FFF]').hasMatch(s);
  }
}

class _ReadAloudChunk {
  final int paragraphIndex;
  final String speechText;
  final String highlightText;

  const _ReadAloudChunk({
    required this.paragraphIndex,
    required this.speechText,
    required this.highlightText,
  });

  int get key => paragraphIndex;
}

class _TtsSegment {
  final String speech;
  final String highlight;

  const _TtsSegment({
    required this.speech,
    required this.highlight,
  });
}

class ReaderPage extends StatefulWidget {
  final String bookId;

  const ReaderPage({super.key, required this.bookId});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const int _onlinePrefetchWindow = 5;
  static const MethodChannel _localTtsChannel =
      MethodChannel('airread/local_tts');
  static const EventChannel _localTtsEvents =
      EventChannel('airread/local_tts_events');
  bool _showControls = false;
  bool _isLoading = true;
  String? _error;
  DateTime? _lastErrorTime;
  String? _lastErrorMessage;
  String? _currentBookFormat;
  Book? _currentBook;
  bool _txtTocParsing = false;
  int _txtTocParseToken = 0;
  int? _pendingRestoreChapterIndex;
  int? _pendingRestorePageInChapter;
  double? _pendingRestoreProgress;
  bool _popping = false;

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
  bool _aiReadAloudPreparing = false;
  int _readAloudSession = 0;
  List<_ReadAloudChunk> _readAloudQueue = const [];
  int _readAloudQueuePos = 0;
  int? _readAloudResumeParagraphIndex;
  String? _readAloudHighlightText;
  StreamSubscription<dynamic>? _localTtsSub;
  int? _readAloudAutoContinueSession;
  int _readAloudAutoSkipRemaining = 0;
  ReadAloudEngine? _lastReadAloudEngine;
  double? _lastTtsSpeed;
  int? _lastTtsVoiceType;
  bool? _lastReadTranslationEnabled;
  Offset? _readAloudFabOffset;

  final AudioPlayer _readAloudPlayer = AudioPlayer();
  final Map<String, Uint8List> _readAloudAudioCache = {};
  final Map<String, Future<Uint8List>> _readAloudAudioInFlight = {};
  TencentTtsClient? _tencentTtsClient;
  final WebSpeechTts _webSpeechTts = createWebSpeechTts();
  final Map<String, Future<Map<int, String>>> _translationFutures = {};
  Timer? _continuousPrefetchTimer;
  Timer? _prefetchKickTimer;
  int _prefetchKickAttempts = 0;
  int? _prefetchCursorChapterIndex;
  int _prefetchCursorParagraphIndex = 0;
  bool _prefetchTickRunning = false;
  bool _onlinePrefetchRunning = false;
  bool _onlinePrefetchNeedsRerun = false;

  List<_ReaderChapter> _chapters = [];
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
  final Map<int, String> _chapterFallbackEffectiveText = {};
  final Map<int, List<TextRange>> _chapterFallbackPageRanges = {};
  final Map<int, String> _chapterFallbackPageRangeKeys = {};
  final Map<int, List<TextRange>> _chapterPlainPageRanges = {};
  final Map<int, String> _chapterPlainPageRangeKeys = {};
  final Map<int, Future<void>> _chapterTextPaginationTasks = {};
  final Map<int, String> _chapterTextPaginationTaskKeys = {};
  final Map<int, int> _chapterTextPaginationTargetCounts = {};
  final Map<int, bool> _chapterTextPaginationComplete = {};
  final Map<int, Future<void>> _chapterPlainPaginationTasks = {};
  final Map<int, String> _chapterPlainPaginationTaskKeys = {};
  final Map<int, int> _chapterPlainPaginationTargetCounts = {};
  final Map<int, bool> _chapterPlainPaginationComplete = {};
  final Map<int, int> _chapterPaginationLastMs = {};
  final Map<int, int> _chapterTitleLength = {};
  final Map<int, List<ReaderParagraph>> _chapterParagraphsCache = {};
  final Map<int, _ReaderChapter> _chapterPlainLoading = {};
  final Map<int, _ReaderChapter> _chapterHtmlLoading = {};

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
    WidgetsBinding.instance.addObserver(this);

    // Setup TranslationProvider error handler
    final transProvider = context.read<TranslationProvider>();
    transProvider.onError = (msg) {
      if (!mounted) return;
      _showTopError(msg);
    };

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
      _onReadAloudPlayerComplete();
    });

    if (!kIsWeb) {
      try {
        _localTtsSub = _localTtsEvents.receiveBroadcastStream().listen((event) {
          if (!mounted) return;
          if (event is Map) {
            final type = event['type'];
            final int? session = switch (event['session']) {
              int v => v,
              num v => v.toInt(),
              String v => int.tryParse(v),
              _ => null,
            };
            if (session != null && session != _readAloudSession) return;
            if (type == 'done') {
              _onLocalTtsDone();
            } else if (type == 'error') {
              final msg = (event['message'] ?? '').toString();
              _onLocalTtsError(msg);
            }
          }
        });
      } catch (_) {}
    }

    _loadSettingsAndBook();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _progressSaveTimer?.cancel();
      _saveProgress();
      _saveProgressToDb();
    }
  }

  void _startPulseTimer() {
    _pulseTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        _pulseController.forward().then((_) => _pulseController.reverse());
      }
    });
  }

  List<_ReaderChapter> _buildEpubChapters(List<EpubChapterRef> roots) {
    final chapters = <_ReaderChapter>[];

    void walk(List<EpubChapterRef> items, int depth) {
      for (final c in items) {
        final rawTitle = (c.Title ?? '').trim();
        final prefix = depth <= 0 ? '' : List.filled(depth, '　　').join();
        final displayTitle = rawTitle.isEmpty ? null : '$prefix$rawTitle';
        chapters.add(_EpubReaderChapter(c, titleOverride: displayTitle));
        final subs = c.SubChapters;
        if (subs != null && subs.isNotEmpty) {
          walk(subs, depth + 1);
        }
      }
    }

    walk(roots, 0);
    return chapters;
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
      final int prefChapter =
          _prefs?.getInt('${key}_h_chapter') ?? legacyChapter;
      final int prefPage = _prefs?.getInt('${key}_h_page') ?? 0;
      final double prefProgress = _prefs?.getDouble('${key}_h_progress') ?? 0.0;

      final int bookChapter = _currentBook?.readingChapter ?? 0;
      final int bookPage = _currentBook?.readingPage ?? 0;
      final double bookProgress = _currentBook?.readingProgress ?? 0.0;

      final bool prefHasProgress = prefChapter != 0 || prefPage != 0;
      final bool bookHasProgress = bookChapter != 0 || bookPage != 0;
      final bool prefHasProgressValue = prefHasProgress || prefProgress > 0.0;
      final bool bookHasProgressValue = bookHasProgress || bookProgress > 0.0;

      final int savedHChapter = prefHasProgressValue
          ? prefChapter
          : (bookHasProgressValue ? bookChapter : prefChapter);
      final int savedHPage = prefHasProgressValue
          ? prefPage
          : (bookHasProgressValue ? bookPage : prefPage);
      final double savedProgress = prefHasProgressValue
          ? prefProgress
          : (bookHasProgressValue ? bookProgress : prefProgress);

      _pendingRestoreChapterIndex = savedHChapter;
      _pendingRestorePageInChapter = savedHPage;
      _pendingRestoreProgress =
          savedProgress > 0.0 ? savedProgress.clamp(0.0, 1.0) : null;
      if (!(_currentBookFormat == 'txt' && _txtTocParsing)) {
        _applyPendingRestore();
      } else {
        _currentChapterIndex = 0;
        _currentPageInChapter = 0;
      }
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
    try {
      context.read<TranslationProvider>().onError = null;
    } catch (_) {}
    _saveSettings();
    _saveProgress();
    _progressSaveTimer?.cancel();
    _stopContinuousPrefetch();
    _localTtsSub?.cancel();
    unawaited(_webSpeechTts.stop());
    _readAloudPlayer.dispose();
    _pageController.dispose();
    // for (var c in _chapterControllers.values) c.dispose(); // Removed
    _pulseController.dispose();
    _readAloudAnimController.dispose();
    _controlsController.dispose();
    _pulseTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
    await _prefs!.setDouble(
        '${key}_h_progress', _currentPageProgressInChapter.clamp(0.0, 1.0));
  }

  Future<void> _saveProgressToDb() async {
    if (!mounted) return;
    try {
      final booksProvider = Provider.of<BooksProvider>(context, listen: false);
      await booksProvider.saveReadingProgress(
        bookId: widget.bookId,
        chapterIndex: _currentChapterIndex,
        pageInChapter: _currentPageInChapter,
        progress: _currentPageProgressInChapter.clamp(0.0, 1.0),
      );
      _currentBook = _currentBook?.copyWith(
        readingChapter: _currentChapterIndex,
        readingPage: _currentPageInChapter,
        readingProgress: _currentPageProgressInChapter.clamp(0.0, 1.0),
        lastRead: DateTime.now(),
      );
    } catch (_) {}
  }

  void _saveProgressDebounced() {
    if (_prefs == null) return;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(milliseconds: 500), () {
      _saveProgress();
      _saveProgressToDb();
    });
  }

  Future<void> _popReader() async {
    if (_popping) return;
    _popping = true;
    _progressSaveTimer?.cancel();
    await _saveProgress();
    await _saveProgressToDb();
    await _saveSettings();
    if (!mounted) return;
    Navigator.pop(context);
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
    _currentBook = book;

    try {
      final format = book.format.toLowerCase();
      _currentBookFormat = format;

      if (format == 'epub') {
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
          final refs = await epub.getChapters();
          final chapters = _buildEpubChapters(refs);
          if (mounted) {
            setState(() {
              _chapters = chapters;
              _chapterContentCache.clear();
              _chapterPlainText.clear();
              _chapterEffectiveText.clear();
              _chapterPageRanges.clear();
              _chapterPageRangeKeys.clear();
              _chapterPlainPageRanges.clear();
              _chapterPlainPageRangeKeys.clear();
              _chapterTextPaginationTasks.clear();
              _chapterTextPaginationTaskKeys.clear();
              _chapterTextPaginationTargetCounts.clear();
              _chapterTextPaginationComplete.clear();
              _chapterPlainPaginationTasks.clear();
              _chapterPlainPaginationTaskKeys.clear();
              _chapterPlainPaginationTargetCounts.clear();
              _chapterPlainPaginationComplete.clear();
              _chapterPaginationLastMs.clear();
              _chapterTitleLength.clear();
              _chapterParagraphsCache.clear();
              _chapterPlainLoading.clear();
              _chapterHtmlLoading.clear();
              _chapterPageCounts.clear();
              _isLoading = false;
            });
          }
        }
        return;
      }

      if (format == 'txt') {
        String? text;
        if (kIsWeb) {
          if (book.fileBytes != null) {
            text = await _parser.openTxtFromBytes(book.fileBytes!);
          }
        } else {
          if (book.filePath.isNotEmpty) {
            text = await _parser.openTxt(book.filePath);
          }
        }

        if (text == null) {
          if (mounted) {
            setState(() {
              _error = 'Cannot load file';
              _isLoading = false;
            });
          }
          return;
        }

        final loadedText = text;
        final int token = ++_txtTocParseToken;
        final int bodyStart =
            _txtBodyStart(text: loadedText, bookTitle: book.title);
        if (mounted) {
          setState(() {
            _txtTocParsing = true;
            _pageViewCenterIndex = 1000;
            _chapters = [
              _TextReaderChapter(
                title: book.title.trim().isEmpty ? '正文' : book.title.trim(),
                sourceText: loadedText,
                start: bodyStart,
                end: loadedText.length,
              )
            ];
            _chapterContentCache.clear();
            _chapterPlainText.clear();
            _chapterEffectiveText.clear();
            _invalidatePagination();
            _chapterPaginationLastMs.clear();
            _chapterTitleLength.clear();
            _chapterParagraphsCache.clear();
            _chapterPlainLoading.clear();
            _chapterHtmlLoading.clear();
            _isLoading = false;
          });
        }

        Future<void>(() async {
          final chapters =
              await _buildTxtChapters(text: loadedText, bookTitle: book.title);
          if (!mounted) return;
          if (_txtTocParseToken != token) return;
          setState(() {
            _txtTocParsing = false;
            _pageViewCenterIndex = 1000;
            _chapters = chapters;
            _chapterContentCache.clear();
            _chapterPlainText.clear();
            _chapterEffectiveText.clear();
            _invalidatePagination();
            _chapterPaginationLastMs.clear();
            _chapterTitleLength.clear();
            _chapterParagraphsCache.clear();
            _chapterPlainLoading.clear();
            _chapterHtmlLoading.clear();
          });
          _applyPendingRestore();
          if (_pageController.hasClients) {
            _pageController.jumpToPage(1000);
          }
        });
        return;
      }

      if (mounted) {
        setState(() {
          _error = 'Unsupported format: ${book.format}';
          _isLoading = false;
        });
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

  int _txtBodyStart({required String text, required String bookTitle}) {
    final trimmedBookTitle = bookTitle.trim();
    final int bomOffset =
        text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
    if (trimmedBookTitle.isEmpty) return bomOffset;
    int i = bomOffset;
    int scanned = 0;
    while (i < text.length && scanned < 200) {
      int lineStart = i;
      int lineEnd = i;
      while (lineEnd < text.length) {
        final cu = text.codeUnitAt(lineEnd);
        if (cu == 10 || cu == 13) break;
        lineEnd++;
      }

      int next = lineEnd;
      if (next < text.length) {
        final cu = text.codeUnitAt(next);
        if (cu == 13) {
          next++;
          if (next < text.length && text.codeUnitAt(next) == 10) next++;
        } else if (cu == 10) {
          next++;
        }
      }

      if (lineEnd > lineStart) {
        final t = text.substring(lineStart, lineEnd).trim();
        if (t.isNotEmpty) {
          if (t == trimmedBookTitle) return next;
          return bomOffset;
        }
      }
      scanned++;
      i = next;
    }
    return bomOffset;
  }

  bool _applyPendingRestore() {
    if (_chapters.isEmpty) return false;
    final ch = _pendingRestoreChapterIndex;
    final pg = _pendingRestorePageInChapter;
    if (ch == null || pg == null) return false;

    final nextChapter = ch.clamp(0, _chapters.length - 1);
    final nextPage = pg.clamp(0, 999999);
    final changed = nextChapter != _currentChapterIndex ||
        nextPage != _currentPageInChapter;

    void apply() {
      _currentChapterIndex = nextChapter;
      _currentPageInChapter = nextPage;
      _pendingRestoreChapterIndex = null;
      _pendingRestorePageInChapter = null;
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
    return changed;
  }

  String _txtNormalizeHeadingTitle(String raw) {
    var t = raw.trim();
    t = t.replaceAll(RegExp(r'^[【\[\(（\s]+'), '');
    t = t.replaceAll(RegExp(r'[】\]\)）\s]+$'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    return t;
  }

  Future<List<_ReaderChapter>> _buildTxtChapters({
    required String text,
    required String bookTitle,
  }) async {
    final trimmedBookTitle = bookTitle.trim();
    final headingsRe = RegExp(
      r'^\s*(?:【\s*)?(?:第\s*(?:[0-9]{1,6}|[一二三四五六七八九十百千零〇两]{1,12})\s*[章节回卷篇节部幕]\s*.*|卷\s*(?:[0-9]{1,6}|[一二三四五六七八九十百千零〇两]{1,12})\s*.*|(CHAPTER|Chapter)\s+(?:\d+|[IVXLC]+)\b.*|序(章|言)|前言|楔子|引子)\s*(?:】)?\s*$',
      caseSensitive: false,
    );
    final int bomOffset =
        text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
    if (kIsWeb && text.length >= 1500000) {
      final hasHeadings = _txtHasHeadingSample(
        text: text,
        headingsRe: headingsRe,
        bomOffset: bomOffset,
      );
      if (!hasHeadings) {
        return _buildTxtChaptersFast(text: text, bookTitle: bookTitle);
      }
    }

    final List<_ReaderChapter> chapters = [];
    String currentTitle = trimmedBookTitle.isNotEmpty ? trimmedBookTitle : '正文';
    int bodyStart = bomOffset;
    bool sawHeading = false;
    bool firstNonEmptyHandled = false;
    final splitPoints = <int>[];
    int chunkChars = 0;
    int contentChars = 0;

    bool hasMeaningfulContent(int start, int endExclusive) {
      final int s = start.clamp(0, text.length);
      final int e = endExclusive.clamp(s, text.length);
      int count = 0;
      for (int i = s; i < e; i++) {
        final int cu = text.codeUnitAt(i);
        if (_isSkippableWhitespaceCu(cu)) continue;
        count++;
        if (count >= 12) return true;
      }
      return false;
    }

    void addChapter(int endExclusive) {
      if (endExclusive <= bodyStart) return;
      if (!hasMeaningfulContent(bodyStart, endExclusive)) return;
      chapters.add(
        _TextReaderChapter(
          title: currentTitle,
          sourceText: text,
          start: bodyStart,
          end: endExclusive,
        ),
      );
    }

    int i = bomOffset;
    int processedLines = 0;
    final sw = Stopwatch()..start();
    while (i < text.length) {
      int lineStart = i;
      int lineEnd = i;
      while (lineEnd < text.length) {
        final int cu = text.codeUnitAt(lineEnd);
        if (cu == 10 || cu == 13) break;
        lineEnd++;
      }

      int next = lineEnd;
      if (next < text.length) {
        final int cu = text.codeUnitAt(next);
        if (cu == 13) {
          next++;
          if (next < text.length && text.codeUnitAt(next) == 10) {
            next++;
          }
        } else if (cu == 10) {
          next++;
        }
      }

      String? trimmed;
      final int len = lineEnd - lineStart;
      if (len > 0) {
        final candidate = text.substring(lineStart, lineEnd);
        final t = candidate.trim();
        if (t.isNotEmpty) {
          trimmed = t;
        }
      }

      if (!firstNonEmptyHandled && trimmed != null) {
        firstNonEmptyHandled = true;
        if (trimmedBookTitle.isNotEmpty && trimmed == trimmedBookTitle) {
          bodyStart = next;
          splitPoints.clear();
          chunkChars = 0;
          contentChars = 0;
        }
      }

      if (trimmed != null &&
          trimmed.length <= 60 &&
          headingsRe.hasMatch(trimmed)) {
        sawHeading = true;
        splitPoints.clear();
        chunkChars = 0;
        if (contentChars > 0) {
          addChapter(lineStart);
        }
        currentTitle = _txtNormalizeHeadingTitle(trimmed);
        bodyStart = next;
        contentChars = 0;
      }

      if (!sawHeading && lineStart >= bodyStart) {
        chunkChars += (next - lineStart);
        if (chunkChars >= 220000 && next > bodyStart && next < text.length) {
          splitPoints.add(next);
          chunkChars = 0;
        }
      }

      if (lineStart >= bodyStart && trimmed != null) {
        final isHeading = trimmed.length <= 60 && headingsRe.hasMatch(trimmed);
        if (!isHeading) {
          contentChars += trimmed.length;
        }
      }

      processedLines++;
      if (processedLines % 300 == 0 && sw.elapsedMilliseconds >= 8) {
        await Future<void>.delayed(Duration.zero);
        sw.reset();
      }
      i = next;
    }

    if (!sawHeading) {
      final baseTitle = currentTitle;
      final boundaries = <int>[bodyStart, ...splitPoints, text.length]..sort();
      final result = <_ReaderChapter>[];
      int part = 1;
      for (int b = 0; b < boundaries.length - 1; b++) {
        final start = boundaries[b].clamp(0, text.length);
        final end = boundaries[b + 1].clamp(start, text.length);
        if (end <= start) continue;
        if (!hasMeaningfulContent(start, end)) continue;
        final t = part == 1 ? baseTitle : '$baseTitle $part';
        result.add(
          _TextReaderChapter(
            title: t,
            sourceText: text,
            start: start,
            end: end,
          ),
        );
        part++;
      }
      if (result.isEmpty) {
        return [
          _TextReaderChapter(
            title: baseTitle,
            sourceText: text,
            start: bodyStart,
            end: text.length,
          )
        ];
      }
      return result;
    }

    if (contentChars > 0) {
      addChapter(text.length);
    }
    if (chapters.isEmpty) {
      return [
        _TextReaderChapter(
          title: trimmedBookTitle.isNotEmpty ? trimmedBookTitle : '正文',
          sourceText: text,
          start: bomOffset,
          end: text.length,
        )
      ];
    }
    return chapters;
  }

  bool _txtHasHeadingSample({
    required String text,
    required RegExp headingsRe,
    required int bomOffset,
  }) {
    int i = bomOffset;
    int scanned = 0;
    int scannedLines = 0;
    const int maxChars = 200000;
    const int maxLines = 4000;
    while (i < text.length && scanned < maxChars && scannedLines < maxLines) {
      int lineStart = i;
      int lineEnd = i;
      while (lineEnd < text.length) {
        final int cu = text.codeUnitAt(lineEnd);
        if (cu == 10 || cu == 13) break;
        lineEnd++;
      }

      int next = lineEnd;
      if (next < text.length) {
        final int cu = text.codeUnitAt(next);
        if (cu == 13) {
          next++;
          if (next < text.length && text.codeUnitAt(next) == 10) {
            next++;
          }
        } else if (cu == 10) {
          next++;
        }
      }

      final int len = lineEnd - lineStart;
      if (len > 0 && len <= 120) {
        final t = text.substring(lineStart, lineEnd).trim();
        if (t.isNotEmpty && t.length <= 60 && headingsRe.hasMatch(t)) {
          return true;
        }
      }

      scanned += (next - lineStart);
      scannedLines++;
      i = next;
    }
    return false;
  }

  Future<List<_ReaderChapter>> _buildTxtChaptersFast({
    required String text,
    required String bookTitle,
  }) async {
    final trimmedBookTitle = bookTitle.trim();
    final baseTitle = trimmedBookTitle.isNotEmpty ? trimmedBookTitle : '正文';
    final int bomOffset =
        text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
    int bodyStart = bomOffset;

    if (trimmedBookTitle.isNotEmpty) {
      int i = bomOffset;
      int scannedLines = 0;
      while (i < text.length && scannedLines < 200) {
        int lineStart = i;
        int lineEnd = i;
        while (lineEnd < text.length) {
          final int cu = text.codeUnitAt(lineEnd);
          if (cu == 10 || cu == 13) break;
          lineEnd++;
        }

        int next = lineEnd;
        if (next < text.length) {
          final int cu = text.codeUnitAt(next);
          if (cu == 13) {
            next++;
            if (next < text.length && text.codeUnitAt(next) == 10) {
              next++;
            }
          } else if (cu == 10) {
            next++;
          }
        }

        if (lineEnd > lineStart) {
          final t = text.substring(lineStart, lineEnd).trim();
          if (t.isNotEmpty) {
            if (t == trimmedBookTitle) {
              bodyStart = next;
            }
            break;
          }
        }

        scannedLines++;
        i = next;
      }
    }

    const int chunkSize = 300000;
    const int seekWindow = 2000;
    final chapters = <_ReaderChapter>[];
    int start = bodyStart;
    int part = 1;

    while (start < text.length) {
      int end = (start + chunkSize).clamp(start + 1, text.length);
      if (end < text.length) {
        int forward = end;
        final forwardLimit = (end + seekWindow).clamp(0, text.length);
        while (forward < forwardLimit) {
          final cu = text.codeUnitAt(forward);
          if (cu == 10 || cu == 13) break;
          forward++;
        }
        if (forward < forwardLimit) {
          int next = forward;
          final int cu = text.codeUnitAt(next);
          if (cu == 13) {
            next++;
            if (next < text.length && text.codeUnitAt(next) == 10) {
              next++;
            }
          } else if (cu == 10) {
            next++;
          }
          end = next.clamp(start + 1, text.length);
        } else {
          int back = end;
          final backLimit = (end - seekWindow).clamp(start + 1, text.length);
          while (back > backLimit) {
            final cu = text.codeUnitAt(back);
            if (cu == 10 || cu == 13) break;
            back--;
          }
          if (back > backLimit) {
            end = back.clamp(start + 1, text.length);
          }
        }
      }

      final title = part == 1 ? baseTitle : '$baseTitle $part';
      if (_rangeHasNonWhitespace(text, start, end)) {
        chapters.add(
          _TextReaderChapter(
            title: title,
            sourceText: text,
            start: start,
            end: end,
          ),
        );
      }
      start = end;
      part++;
      if (part % 2 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (chapters.isEmpty) {
      return [
        _TextReaderChapter(
          title: baseTitle,
          sourceText: text,
          start: bodyStart,
          end: text.length,
        )
      ];
    }
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
    if (width <= 0) return;
    if (!_pageController.hasClients) return;

    final elapsed = DateTime.now().millisecondsSinceEpoch - downMs;
    if (elapsed > 350) return;

    final x = pos.dx.clamp(0, width);
    final isLeft = x <= width * 0.3;
    final isRight = x >= width * 0.7;

    if (!isLeft && !isRight) {
      _toggleControls();
      return;
    }

    if (isLeft) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _openAiHud({
    AiHudRoute initialRoute = AiHudRoute.main,
    String? initialQaText,
    bool autoSendInitialQa = false,
  }) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: _panelBgColor,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg))),
      builder: (sheetContext) {
        return Consumer<TranslationProvider>(
          builder: (context, translationProvider, _) {
            final viewportHeight = _lastPaginationViewportHeight;
            final contentWidth = _lastPaginationContentWidth;
            if (viewportHeight != null && contentWidth != null) {
              _schedulePlainPaginationForChapter(
                chapterIndex: _currentChapterIndex,
                viewportHeight: viewportHeight,
                contentWidth: contentWidth,
              );
            }

            final plainRanges = _chapterPlainPageRanges[_currentChapterIndex];
            final plainPageIndex = plainRanges == null || plainRanges.isEmpty
                ? _currentPageInChapter
                : _plainPageIndexForProgress(
                    _currentChapterIndex,
                    _currentPageProgressInChapter,
                  );

            final qaTextCache = Map<int, String>.from(_chapterPlainText);
            qaTextCache[_currentChapterIndex] =
                _getPlainTextForChapter(_currentChapterIndex);

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
              onShowTopMessage: _showTopError,
            );
          },
        );
      },
    ).then((_) {
      if (mounted) _hideControls();
    });
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
    try {
      await provider.setAiTranslateEnabled(enabled);
    } catch (e) {
      if (!mounted) return;
      _showTopError(e.toString());
      return;
    }

    if (!enabled) {
      _translationFutures.clear();
      _stopContinuousPrefetch();
      setState(() {});
    }
    if (enabled) {
      _stopContinuousPrefetch();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _kickoffTranslationPrefetch(provider);
      });
    }
  }

  Future<void> _setAiReadAloudEnabled({
    required TranslationProvider provider,
    required bool enabled,
  }) async {
    if (!mounted) return;

    try {
      await provider.setAiReadAloudEnabled(enabled);
    } catch (e) {
      if (!mounted) return;
      _showTopError(e.toString());
      return;
    }

    if (!enabled) {
      await _stopReadAloud(keepResume: true);
      if (!mounted) return;
      setState(() {
        _readAloudHighlightText = null;
      });
      return;
    }
    if (!mounted) return;
    final resume = _readAloudResumeParagraphIndex;
    if (resume != null) {
      final highlight = _paragraphTextForIndex(resume);
      if (highlight != null && highlight.trim().isNotEmpty) {
        _readAloudHighlightText = highlight;
      }
    }
    setState(() {});
  }

  String? _paragraphTextForIndex(int paragraphIndex) {
    if (_chapters.isEmpty) return null;
    final plainText = _getPlainTextForChapter(_currentChapterIndex);
    if (plainText.isEmpty) return null;
    final paras = _getParagraphsForChapter(_currentChapterIndex, plainText);
    if (paras.isEmpty) return null;
    if (paragraphIndex < 0 || paragraphIndex >= paras.length) return null;
    return paras[paragraphIndex].text;
  }

  Future<void> _startReadAloudFromParagraphIndex(int paragraphIndex) async {
    final cfg = context.read<TranslationProvider>();
    final queue = _buildReadAloudQueue();
    if (queue.isEmpty) return;

    final idx = queue.indexWhere((e) => e.paragraphIndex == paragraphIndex);
    if (idx < 0) return;

    await _stopReadAloud(keepResume: true);
    if (!mounted) return;

    final session = ++_readAloudSession;
    _readAloudQueue = queue;
    _readAloudQueuePos = idx;
    _readAloudResumeParagraphIndex = paragraphIndex;
    _readAloudHighlightText = null;

    if (cfg.readAloudEngine == ReadAloudEngine.local) {
      await _readAloudPlayer.stop();
      await _speakLocalQueueItem(session);
      return;
    }

    await _playOnlineQueueItem(session);
  }

  List<_ReadAloudChunk> _buildReadAloudQueue() {
    return _buildReadAloudQueueFromParagraphs(_currentPageParagraphsByIndex());
  }

  List<_ReadAloudChunk> _buildReadAloudQueueFromParagraphs(
      Map<int, String> paragraphsByIndex) {
    final tp = context.read<TranslationProvider>();
    final entries = paragraphsByIndex.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final out = <_ReadAloudChunk>[];
    for (final e in entries) {
      final base = _speechTextForParagraph(
        provider: tp,
        paragraphIndex: e.key,
        paragraphText: e.value,
      );
      if (base.trim().isEmpty) continue;
      if (tp.readAloudEngine == ReadAloudEngine.online) {
        final segments = _splitTtsSegments(base);
        for (final seg in segments) {
          final speech = seg.speech.trim();
          if (speech.isEmpty) continue;
          final highlight = seg.highlight.trim();
          out.add(
            _ReadAloudChunk(
              paragraphIndex: e.key,
              speechText: speech,
              highlightText: highlight.isEmpty ? speech : highlight,
            ),
          );
        }
      } else {
        final speech = _normalizeSpeechText(base);
        if (speech.trim().isEmpty) continue;
        final highlight = base.trim();
        out.add(
          _ReadAloudChunk(
            paragraphIndex: e.key,
            speechText: speech,
            highlightText: highlight.isEmpty ? speech : highlight,
          ),
        );
      }
    }
    return out;
  }

  String _normalizeSpeechText(String text) {
    var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    while (t.isNotEmpty) {
      final cu = t.codeUnitAt(0);
      if (cu == 32 || cu == 9 || cu == 12288) {
        t = t.substring(1);
        continue;
      }
      break;
    }
    return t;
  }

  String _speechTextForParagraph({
    required TranslationProvider provider,
    required int paragraphIndex,
    required String paragraphText,
  }) {
    final original = paragraphText.trim();
    if (!provider.readTranslationEnabled) return original;

    final trans = provider.getCachedTranslation(paragraphText);
    if (trans == null || trans.trim().isEmpty) return original;
    final normalizedTrans = trans.trim();
    if (normalizedTrans.isEmpty) return original;

    final transOnly = provider.applyToReader &&
        provider.config.displayMode == TranslationDisplayMode.translationOnly;
    if (transOnly) return normalizedTrans;
    if (original.isEmpty) return normalizedTrans;
    return '$original\n$normalizedTrans';
  }

  bool _containsCjk(String s) {
    return RegExp(r'[\u4E00-\u9FFF]').hasMatch(s);
  }

  int _ttsUnitCount(String s) {
    var count = 0;
    for (int i = 0; i < s.length; i++) {
      final cu = s.codeUnitAt(i);
      if (_isSkippableWhitespaceCu(cu)) continue;
      count++;
    }
    return count;
  }

  List<_TtsSegment> _splitTtsSegments(String text) {
    final base = text.trim();
    if (base.isEmpty) return const [];
    final maxUnits = _containsCjk(base) ? 150 : 500;
    if (_ttsUnitCount(base) <= maxUnits) {
      return <_TtsSegment>[
        _TtsSegment(
          speech: _normalizeSpeechText(base),
          highlight: base,
        ),
      ];
    }

    final sentenceRegex = RegExp(r'[^。！？；.!?;]+[。！？；.!?;]*\s*');
    final parts = sentenceRegex
        .allMatches(base)
        .map((m) => m.group(0) ?? '')
        .where((e) => e.trim().isNotEmpty)
        .toList();

    final out = <_TtsSegment>[];
    final buf = StringBuffer();
    int bufUnits = 0;

    void flush() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) {
        out.add(
          _TtsSegment(
            speech: _normalizeSpeechText(s),
            highlight: s,
          ),
        );
      }
      buf.clear();
      bufUnits = 0;
    }

    for (final raw in parts) {
      final seg = raw.trim();
      if (seg.isEmpty) continue;
      final segUnits = _ttsUnitCount(seg);
      if (segUnits > maxUnits) {
        if (bufUnits > 0) flush();
        final pieces = _splitLongSegment(seg, maxUnits: maxUnits);
        for (final p in pieces) {
          final s = p.trim();
          if (s.isEmpty) continue;
          out.add(
            _TtsSegment(
              speech: _normalizeSpeechText(s),
              highlight: s,
            ),
          );
        }
        continue;
      }
      if (bufUnits == 0) {
        buf.write(seg);
        bufUnits = segUnits;
        continue;
      }
      if (bufUnits + segUnits <= maxUnits) {
        buf.write(seg);
        bufUnits += segUnits;
      } else {
        flush();
        buf.write(seg);
        bufUnits = segUnits;
      }
    }
    if (bufUnits > 0) flush();
    return out.isEmpty
        ? <_TtsSegment>[
            _TtsSegment(
              speech: _normalizeSpeechText(base),
              highlight: base,
            ),
          ]
        : out;
  }

  List<String> _splitLongSegment(String seg, {required int maxUnits}) {
    final seps = <RegExp>[
      RegExp(r'(?<=[，,、])\s*'),
      RegExp(r'\s+'),
    ];
    var current = <String>[seg];
    for (final sep in seps) {
      final next = <String>[];
      for (final piece in current) {
        if (_ttsUnitCount(piece) <= maxUnits) {
          next.add(piece);
          continue;
        }
        next.addAll(piece.split(sep).where((e) => e.trim().isNotEmpty));
      }
      current = next;
    }

    final out = <String>[];
    for (final piece in current) {
      var p = piece.trim();
      if (p.isEmpty) continue;
      if (_ttsUnitCount(p) <= maxUnits) {
        out.add(p);
        continue;
      }
      int start = 0;
      while (start < p.length) {
        int units = 0;
        int end = start;
        while (end < p.length && units < maxUnits) {
          final cu = p.codeUnitAt(end);
          if (!_isSkippableWhitespaceCu(cu)) units++;
          end++;
        }
        final slice = p.substring(start, end).trim();
        if (slice.isNotEmpty) out.add(slice);
        start = end;
      }
    }
    return out;
  }

  Future<Uint8List> _getOnlineTtsBytes({
    required String text,
    required int voiceType,
    required double speed,
  }) async {
    final key = _onlineTtsCacheKey(
      text: text,
      voiceType: voiceType,
      speed: speed,
    );
    final cached = _readAloudAudioCache[key];
    if (cached != null) return cached;

    final client = _tencentTtsClient ??= TencentTtsClient(
      credentials: getEmbeddedPublicHunyuanCredentials(),
    );
    Uint8List bytes;
    try {
      bytes = await client.streamTextToVoiceBytes(
        text: text,
        codec: 'mp3',
        voiceType: voiceType > 0 ? voiceType : null,
        speed: speed,
      );
    } on FormatException {
      final res = await client.textToVoice(
        text: text,
        codec: 'mp3',
        voiceType: voiceType > 0 ? voiceType : null,
        speed: speed,
      );
      bytes = base64Decode(res.audioBase64);
    } on UnsupportedError {
      final res = await client.textToVoice(
        text: text,
        codec: 'mp3',
        voiceType: voiceType > 0 ? voiceType : null,
        speed: speed,
      );
      bytes = base64Decode(res.audioBase64);
    }
    _readAloudAudioCache[key] = bytes;
    return bytes;
  }

  String _onlineTtsCacheKey({
    required String text,
    required int voiceType,
    required double speed,
  }) {
    return 'v2|${text.hashCode}|$voiceType|${speed.toStringAsFixed(2)}';
  }

  Future<Uint8List> _getOnlineTtsBytesDedup({
    required String text,
    required int voiceType,
    required double speed,
  }) {
    final key =
        _onlineTtsCacheKey(text: text, voiceType: voiceType, speed: speed);
    final cached = _readAloudAudioCache[key];
    if (cached != null) {
      return Future<Uint8List>.value(cached);
    }
    final existing = _readAloudAudioInFlight[key];
    if (existing != null) return existing;
    final fut =
        _getOnlineTtsBytes(text: text, voiceType: voiceType, speed: speed)
            .whenComplete(() {
      _readAloudAudioInFlight.remove(key);
    });
    _readAloudAudioInFlight[key] = fut;
    return fut;
  }

  void _scheduleOnlinePrefetchWindow(int session) {
    if (!mounted) return;
    if (session != _readAloudSession) return;
    if (_onlinePrefetchRunning) {
      _onlinePrefetchNeedsRerun = true;
      return;
    }
    _onlinePrefetchRunning = true;
    unawaited(() async {
      while (true) {
        if (!mounted || session != _readAloudSession) break;
        await _runOnlinePrefetchWindow(session);
        if (!_onlinePrefetchNeedsRerun) break;
        _onlinePrefetchNeedsRerun = false;
      }
      _onlinePrefetchRunning = false;
    }());
  }

  Future<void> _runOnlinePrefetchWindow(int session) async {
    if (!mounted) return;
    if (session != _readAloudSession) return;
    if (_readAloudQueue.isEmpty) return;
    final cfg = context.read<TranslationProvider>();
    final combined = _buildOnlinePrefetchQueue();
    if (combined.isEmpty) return;
    final int start = (_readAloudQueuePos + 1).clamp(0, combined.length);
    if (start >= combined.length) return;
    final int end =
        (start + _onlinePrefetchWindow - 1).clamp(0, combined.length - 1);
    for (int i = start; i <= end; i++) {
      if (!mounted || session != _readAloudSession) return;
      final next = combined[i];
      final key = _onlineTtsCacheKey(
        text: next.speechText,
        voiceType: cfg.ttsVoiceType,
        speed: cfg.ttsSpeed,
      );
      if (_readAloudAudioCache.containsKey(key)) continue;
      if (_readAloudAudioInFlight.containsKey(key)) continue;
      try {
        await _getOnlineTtsBytesDedup(
          text: next.speechText,
          voiceType: cfg.ttsVoiceType,
          speed: cfg.ttsSpeed,
        );
      } catch (_) {}
    }
  }

  List<_ReadAloudChunk> _buildOnlinePrefetchQueue() {
    final out = <_ReadAloudChunk>[];
    out.addAll(_readAloudQueue);
    final int targetLength = _readAloudQueuePos + _onlinePrefetchWindow + 1;
    int chapterIndex = _currentChapterIndex;
    int pageIndex = _currentPlainPageIndex();
    int guard = 0;
    while (out.length < targetLength && guard < 20) {
      guard++;
      var ranges = _chapterPlainPageRanges[chapterIndex];
      if (ranges == null || ranges.isEmpty) break;
      pageIndex++;
      if (pageIndex >= ranges.length) {
        chapterIndex++;
        pageIndex = 0;
        if (chapterIndex >= _chapters.length) break;
        ranges = _chapterPlainPageRanges[chapterIndex];
        if (ranges == null || ranges.isEmpty) {
          _ensureChapterContentCached(chapterIndex);
          break;
        }
      }
      final next = _paragraphsByIndexForPage(
        chapterIndex: chapterIndex,
        pageIndex: pageIndex,
      );
      if (next.isEmpty) break;
      out.addAll(_buildReadAloudQueueFromParagraphs(next));
    }
    return out;
  }

  Future<void> _playOnlineQueueItem(int session) async {
    if (!mounted) return;
    if (session != _readAloudSession) return;
    if (_readAloudQueuePos < 0 ||
        _readAloudQueuePos >= _readAloudQueue.length) {
      await _stopReadAloud(keepResume: false);
      return;
    }

    final cfg = context.read<TranslationProvider>();
    final entry = _readAloudQueue[_readAloudQueuePos];
    _readAloudResumeParagraphIndex = entry.paragraphIndex;

    setState(() {
      _aiReadAloudPlaying = true;
      _aiReadAloudPreparing = true;
      _readAloudHighlightText = entry.highlightText;
    });
    _readAloudAnimController.repeat(reverse: true);

    try {
      final bytes = await _getOnlineTtsBytesDedup(
        text: entry.speechText,
        voiceType: cfg.ttsVoiceType,
        speed: cfg.ttsSpeed,
      );
      if (!mounted) return;
      if (session != _readAloudSession) return;

      setState(() {
        _aiReadAloudPreparing = false;
      });
      await _readAloudPlayer.stop();
      await _readAloudPlayer.play(BytesSource(bytes));
      _scheduleOnlinePrefetchWindow(session);
    } catch (e) {
      if (!mounted) return;
      if (session != _readAloudSession) return;
      await _stopReadAloud(keepResume: true);
      if (!mounted) return;
      _showTopError('朗读失败：$e');
    }
  }

  Future<void> _speakLocalQueueItem(int session) async {
    if (!mounted) return;
    if (session != _readAloudSession) return;
    if (_readAloudQueuePos < 0 ||
        _readAloudQueuePos >= _readAloudQueue.length) {
      await _stopReadAloud(keepResume: false);
      return;
    }
    final cfg = context.read<TranslationProvider>();
    final entry = _readAloudQueue[_readAloudQueuePos];
    _readAloudResumeParagraphIndex = entry.paragraphIndex;

    setState(() {
      _aiReadAloudPlaying = true;
      _aiReadAloudPreparing = true;
      _readAloudHighlightText = entry.highlightText;
    });
    _readAloudAnimController.repeat(reverse: true);

    String? lang;
    if (cfg.readTranslationEnabled) {
      lang = cfg.config.targetLang;
    } else {
      lang = cfg.config.sourceLang;
    }
    if (lang.trim().isEmpty) lang = null;

    try {
      if (kIsWeb) {
        if (!_webSpeechTts.supported) {
          throw UnsupportedError('当前浏览器不支持本地朗读');
        }
        await _webSpeechTts.speak(
          text: entry.speechText,
          rate: cfg.ttsSpeed,
          session: session,
          onDone: (s) {
            if (!mounted) return;
            if (s != _readAloudSession) return;
            _onLocalTtsDone();
          },
          onError: (s, msg) {
            if (!mounted) return;
            if (s != _readAloudSession) return;
            _onLocalTtsError(msg);
          },
        );
        if (!mounted) return;
        if (session != _readAloudSession) return;
        setState(() {
          _aiReadAloudPreparing = false;
        });
      } else {
        final args = {
          'text': entry.speechText,
          'rate': cfg.ttsSpeed,
          'session': session,
          'lang': lang,
        };
        try {
          await _localTtsChannel.invokeMethod('speak', args);
        } on PlatformException catch (e) {
          if (e.code != 'NOT_AVAILABLE') rethrow;
          final ok =
              await _localTtsChannel.invokeMethod<bool>('isAvailable') ?? false;
          if (!ok) rethrow;
          await _localTtsChannel.invokeMethod('speak', args);
        }
        if (!mounted) return;
        if (session != _readAloudSession) return;
        setState(() {
          _aiReadAloudPreparing = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (session != _readAloudSession) return;
      await _stopReadAloud(keepResume: true);
      if (!mounted) return;
      _showTopError('朗读失败：$e');
    }
  }

  Future<bool> _startReadAloud() async {
    final cfg = context.read<TranslationProvider>();
    final queue = _buildReadAloudQueue();
    if (queue.isEmpty) return false;

    int pos = 0;
    final resume = _readAloudResumeParagraphIndex;
    if (resume != null) {
      final idx = queue.indexWhere((e) => e.key == resume);
      if (idx >= 0) pos = idx;
    }

    final session = ++_readAloudSession;
    _readAloudQueue = queue;
    _readAloudQueuePos = pos;

    if (cfg.readAloudEngine == ReadAloudEngine.local) {
      await _readAloudPlayer.stop();
      await _speakLocalQueueItem(session);
      return true;
    }

    _scheduleOnlinePrefetchWindow(session);
    await _playOnlineQueueItem(session);
    return true;
  }

  Future<void> _stopReadAloud({required bool keepResume}) async {
    _readAloudSession++;
    if (!keepResume) {
      _readAloudResumeParagraphIndex = null;
      _readAloudHighlightText = null;
    }
    _readAloudQueue = const [];
    _readAloudQueuePos = 0;
    _readAloudAudioInFlight.clear();
    _readAloudAnimController.stop();
    _readAloudAnimController.reset();
    try {
      if (kIsWeb) {
        await _webSpeechTts.stop();
      } else {
        await _localTtsChannel.invokeMethod('stop');
      }
    } catch (_) {}
    await _readAloudPlayer.stop();
    if (!mounted) return;
    setState(() {
      _aiReadAloudPlaying = false;
      _aiReadAloudPreparing = false;
    });
  }

  void _onReadAloudPlayerComplete() {
    if (!mounted) return;
    final cfg = context.read<TranslationProvider>();
    if (!_aiReadAloudPlaying) return;
    if (cfg.readAloudEngine != ReadAloudEngine.online) return;

    final session = _readAloudSession;
    final nextPos = _readAloudQueuePos + 1;
    if (nextPos >= _readAloudQueue.length) {
      unawaited(_continueReadAloudToNextPage(session));
      return;
    }
    _readAloudQueuePos = nextPos;
    unawaited(_playOnlineQueueItem(session));
  }

  void _onLocalTtsDone() {
    if (!mounted) return;
    final cfg = context.read<TranslationProvider>();
    if (cfg.readAloudEngine != ReadAloudEngine.local) return;
    if (!_aiReadAloudPlaying) return;

    final session = _readAloudSession;
    final nextPos = _readAloudQueuePos + 1;
    if (nextPos >= _readAloudQueue.length) {
      unawaited(_continueReadAloudToNextPage(session));
      return;
    }
    _readAloudQueuePos = nextPos;
    unawaited(_speakLocalQueueItem(session));
  }

  bool _hasNextReadingPage() {
    if (_chapters.isEmpty) return false;
    final total = _pageCountForChapter(_currentChapterIndex);
    if (_currentPageInChapter + 1 < total) return true;
    if (_currentChapterIndex + 1 < _chapters.length) return true;
    return false;
  }

  Future<void> _continueReadAloudToNextPage(int session) async {
    if (!mounted) return;
    if (session != _readAloudSession) return;

    if (!_hasNextReadingPage()) {
      await _stopReadAloud(keepResume: false);
      return;
    }

    if (_readAloudAutoContinueSession != session) {
      _readAloudAutoContinueSession = session;
      _readAloudAutoSkipRemaining = 10;
    }

    if (_pageController.hasClients) {
      await _pageController.nextPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
      return;
    }

    int nextChapter = _currentChapterIndex;
    int nextPage = _currentPageInChapter + 1;
    final total = _pageCountForChapter(nextChapter);
    if (nextPage >= total) {
      nextChapter++;
      nextPage = 0;
    }
    if (nextChapter >= _chapters.length) {
      await _stopReadAloud(keepResume: false);
      return;
    }

    setState(() {
      _currentChapterIndex = nextChapter;
      _currentPageInChapter = nextPage;
    });
    _saveProgressDebounced();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeAutoContinueReadAloudAfterPageTurn();
    });
  }

  void _maybeAutoContinueReadAloudAfterPageTurn() {
    final session = _readAloudAutoContinueSession;
    if (session == null) return;
    if (session != _readAloudSession) {
      _readAloudAutoContinueSession = null;
      _readAloudAutoSkipRemaining = 0;
      return;
    }
    if (!_aiReadAloudPlaying) {
      _readAloudAutoContinueSession = null;
      _readAloudAutoSkipRemaining = 0;
      return;
    }

    final queue = _buildReadAloudQueue();
    if (queue.isEmpty) {
      if (_readAloudAutoSkipRemaining > 0) {
        _readAloudAutoSkipRemaining--;
        unawaited(_continueReadAloudToNextPage(session));
      } else {
        unawaited(_stopReadAloud(keepResume: false));
      }
      return;
    }

    _readAloudQueue = queue;
    _readAloudQueuePos = 0;
    _readAloudResumeParagraphIndex = null;

    final cfg = context.read<TranslationProvider>();
    if (cfg.readAloudEngine == ReadAloudEngine.local) {
      unawaited(_speakLocalQueueItem(session));
    } else {
      unawaited(_playOnlineQueueItem(session));
    }
  }

  void _onLocalTtsError(String message) {
    if (!mounted) return;
    if (!_aiReadAloudPlaying) return;
    unawaited(_stopReadAloud(keepResume: true));
    final text = message.isEmpty ? '朗读失败' : '朗读失败：$message';
    _showTopError(text);
  }

  void _showTopError(String message, {bool isError = true}) {
    if (_lastErrorMessage == message &&
        _lastErrorTime != null &&
        DateTime.now().difference(_lastErrorTime!) <
            const Duration(seconds: 3)) {
      return;
    }
    _lastErrorMessage = message;
    _lastErrorTime = DateTime.now();

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentMaterialBanner();

    final bgColor =
        isError ? Colors.red.withOpacity(0.95) : Colors.green.withOpacity(0.95);

    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: bgColor,
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('关闭', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  Widget _buildReadAloudFloatingButton() {
    if (_isLoading || _error != null) return const SizedBox.shrink();
    if (!context.watch<TranslationProvider>().aiReadAloudEnabled) {
      return const SizedBox.shrink();
    }

    final Color surface = _panelBgColor;
    final Color onSurface = _panelTextColor;

    final mq = MediaQuery.of(context);
    final size = mq.size;
    const fabSize = 48.0;
    const margin = 12.0;
    final bottomInset = _contentBottomInset ?? mq.viewPadding.bottom;
    final topInset = mq.viewPadding.top;

    final defaultX = size.width - 14 - fabSize;
    final defaultY = size.height - bottomInset - 120 - fabSize;
    final current = _readAloudFabOffset ?? Offset(defaultX, defaultY);

    final maxX = size.width - margin - fabSize;
    final maxY = size.height - bottomInset - 80 - fabSize;
    final clamped = Offset(
      current.dx.clamp(margin, maxX),
      current.dy.clamp(topInset + margin, maxY),
    );

    final isDarkBg = _bgColor.computeLuminance() < 0.5;
    final shadow = <BoxShadow>[
      BoxShadow(
        color: Colors.black.withOpacity(isDarkBg ? 0.55 : 0.22),
        blurRadius: 18,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: Colors.white.withOpacity(isDarkBg ? 0.06 : 0.75),
        blurRadius: 10,
        offset: const Offset(0, -4),
      ),
    ];

    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          final base = _readAloudFabOffset ?? Offset(defaultX, defaultY);
          final next = base + details.delta;
          final nextClamped = Offset(
            next.dx.clamp(margin, maxX),
            next.dy.clamp(topInset + margin, maxY),
          );
          setState(() => _readAloudFabOffset = nextClamped);
        },
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          scale:
              context.watch<TranslationProvider>().aiReadAloudEnabled ? 1 : 0.9,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              boxShadow: shadow,
            ),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.002)
                ..rotateX(-0.12)
                ..rotateY(0.10),
              child: GlassPanel(
                borderRadius: BorderRadius.circular(999),
                surfaceColor: surface,
                opacity: 0.92,
                blurSigma: 14,
                border: Border.all(
                  color: onSurface.withOpacity(0.08),
                  width: AppTokens.stroke,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    if (_aiReadAloudPlaying || _aiReadAloudPreparing) {
                      _stopReadAloud(keepResume: true);
                      return;
                    }
                    _startReadAloud();
                  },
                  child: SizedBox(
                    width: fabSize,
                    height: fabSize,
                    child: AnimatedBuilder(
                      animation: _readAloudAnimController,
                      builder: (context, child) {
                        final active =
                            _aiReadAloudPlaying || _aiReadAloudPreparing;
                        final scale = active
                            ? 1.0 + (_readAloudAnimController.value * 0.2)
                            : 1.0;
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            Icons.volume_up_rounded,
                            color:
                                (_aiReadAloudPlaying || _aiReadAloudPreparing)
                                    ? AppColors.techBlue
                                    : onSurface.withOpacity(0.5),
                            size: 24,
                          ),
                          if (_aiReadAloudPreparing)
                            SizedBox(
                              width: 34,
                              height: 34,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.techBlue.withOpacity(0.7),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _pageCountForChapter(int chapterIndex) {
    final count = _chapterPageCounts[chapterIndex];
    if (count != null) {
      return count.clamp(1, 999999);
    }
    final ranges = _chapterPageRanges[chapterIndex];
    if (ranges != null && ranges.isNotEmpty) {
      return ranges.length.clamp(1, 999999);
    }
    final fallback = _chapterFallbackPageRanges[chapterIndex];
    if (fallback != null && fallback.isNotEmpty) {
      return fallback.length.clamp(1, 999999);
    }
    return 9999;
  }

  String _getPlainTextForChapter(int chapterIndex) {
    final cached = _chapterPlainText[chapterIndex];
    if (cached != null) return cached;
    final html = _chapterContentCache[chapterIndex];
    if (html == null) return '';

    String text = html;

    text = text.replaceAll(
      RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
      ' ',
    );
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
    bool firstWritten = false;
    for (int i = 0; i < parts.length; i++) {
      final raw = parts[i].trim();
      if (raw.isEmpty) continue;
      if (firstWritten) {
        buffer.write('\n\n');
      }
      final bool isTitle = !firstWritten;
      final String indent = isTitle ? '' : '　　';
      final String paraText = indent + raw;
      if (isTitle) {
        titleLength = paraText.length;
      }
      buffer.write(paraText);
      firstWritten = true;
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
          buffer.write('$indent翻译中...');
        } else if (isBilingual) {
          buffer.write(p.text);
          buffer.write('\n');
          buffer.write('$indent翻译中...');
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
    const marker = '翻译中...';
    const int markerLen = marker.length;
    const paraSep = '\n\n';

    final List<InlineSpan> children = [];

    final highlightText = _readAloudHighlightText;
    int hiStart = -1;
    int hiEnd = -1;
    if (highlightText != null && highlightText.trim().isNotEmpty) {
      hiStart = text.indexOf(highlightText);
      if (hiStart >= 0) {
        hiEnd = (hiStart + highlightText.length).clamp(0, text.length);
        while (hiStart < hiEnd &&
            _isSkippableWhitespaceCu(text.codeUnitAt(hiStart))) {
          hiStart++;
        }
        if (hiStart >= hiEnd) {
          hiStart = -1;
          hiEnd = -1;
        }
      }
    }

    final placeholderStyle = bodyStyle.copyWith(
      fontStyle: FontStyle.italic,
      fontSize: bodyStyle.fontSize == null ? null : bodyStyle.fontSize! * 0.92,
      color: (bodyStyle.color ?? _textColor).withOpacity(0.55),
    );

    final highlightStyle = bodyStyle.copyWith(
      backgroundColor: AppColors.techBlue.withOpacity(0.12),
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
      final idxHiStart = hiStart > i ? hiStart : -1;
      final idxHiEnd = hiEnd > i ? hiEnd : -1;

      int nextIdx = -1;
      bool nextIsMarker = false;
      bool nextIsPara = false;
      bool nextIsHighlightBoundary = false;

      if (idxMarker >= 0) {
        nextIdx = idxMarker;
        nextIsMarker = true;
      }
      if (idxPara >= 0 && (nextIdx == -1 || idxPara < nextIdx)) {
        nextIdx = idxPara;
        nextIsMarker = false;
        nextIsPara = true;
      }
      if (idxHiStart >= 0 && (nextIdx == -1 || idxHiStart < nextIdx)) {
        nextIdx = idxHiStart;
        nextIsMarker = false;
        nextIsPara = false;
        nextIsHighlightBoundary = true;
      }
      if (idxHiEnd >= 0 && (nextIdx == -1 || idxHiEnd < nextIdx)) {
        nextIdx = idxHiEnd;
        nextIsMarker = false;
        nextIsPara = false;
        nextIsHighlightBoundary = true;
      }

      if (nextIdx < 0) {
        final inHighlight =
            hiStart >= 0 && hiEnd > hiStart && i >= hiStart && i < hiEnd;
        children.add(TextSpan(
          text: text.substring(i),
          style: inHighlight ? highlightStyle : bodyStyle,
        ));
        break;
      }

      if (nextIdx > i) {
        final inHighlight =
            hiStart >= 0 && hiEnd > hiStart && i >= hiStart && i < hiEnd;
        children.add(TextSpan(
          text: text.substring(i, nextIdx),
          style: inHighlight ? highlightStyle : bodyStyle,
        ));
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

      if (nextIsHighlightBoundary) {
        i = nextIdx;
        continue;
      }

      i = nextIdx + 1;
    }

    return TextSpan(children: children, style: bodyStyle);
  }

  String _paginationKey({
    required double viewportHeight,
    required double contentWidth,
    required int textLength,
  }) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    String snapKey(double v) => (v * dpr).roundToDouble().toStringAsFixed(0);
    return 'v2|${snapKey(contentWidth)}|${snapKey(viewportHeight)}|${_fontSize.toStringAsFixed(2)}|${_lineHeight.toStringAsFixed(2)}|$textLength|${_contentBottomInset?.toStringAsFixed(1) ?? '0'}';
  }

  bool _isSkippableWhitespaceCu(int cu) {
    if (cu == 10 || cu == 13 || cu == 9 || cu == 32 || cu == 12288) {
      return true;
    }
    if (cu == 0xFEFF) return true;
    if (cu == 0x00A0) return true;
    if (cu == 0x2028 || cu == 0x2029) return true;
    if (cu >= 0x2000 && cu <= 0x200A) return true;
    if (cu == 0x200B) return true;
    return false;
  }

  bool _rangeHasNonWhitespace(String text, int start, int end) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(s, text.length);
    for (int i = s; i < e; i++) {
      final cu = text.codeUnitAt(i);
      if (!_isSkippableWhitespaceCu(cu)) return true;
    }
    return false;
  }

  int _bestEndForPage({
    required String text,
    required int start,
    required TextPainter textPainter,
    required TextStyle textStyle,
    required double viewportHeight,
    required double contentWidth,
    required int previousPageChars,
  }) {
    final int len = text.length;
    final int minEnd = (start + 1).clamp(0, len);
    if (minEnd >= len) return len;

    bool fits(int end) {
      final int safeEnd = end.clamp(minEnd, len);
      textPainter.text = _buildReaderSpan(
        text: text.substring(start, safeEnd),
        bodyStyle: textStyle,
      );
      textPainter.layout(minWidth: 0, maxWidth: contentWidth);
      return textPainter.height <= viewportHeight;
    }

    int guess = previousPageChars.clamp(200, 6000);
    int high = (start + guess).clamp(minEnd, len);
    if (high == minEnd) {
      high = (minEnd + 1).clamp(minEnd, len);
    }

    int best = minEnd;
    if (fits(minEnd)) {
      best = minEnd;
    } else {
      return minEnd;
    }

    if (high >= len) {
      return fits(len) ? len : best;
    }

    if (fits(high)) {
      int lastGood = high;
      int step = guess;
      while (lastGood < len) {
        step = (step * 2).clamp(256, 65536);
        final nextHigh = (lastGood + step).clamp(lastGood + 1, len);
        if (nextHigh == lastGood) break;
        if (fits(nextHigh)) {
          lastGood = nextHigh;
          best = lastGood;
          if (lastGood == len) return len;
        } else {
          int low = lastGood + 1;
          int hi = nextHigh;
          int localBest = lastGood;
          while (low <= hi) {
            final mid = (low + hi) >> 1;
            if (fits(mid)) {
              localBest = mid;
              low = mid + 1;
            } else {
              hi = mid - 1;
            }
          }
          return localBest;
        }
      }
      return best;
    } else {
      int low = minEnd + 1;
      int hi = high;
      int localBest = best;
      while (low <= hi) {
        final mid = (low + hi) >> 1;
        if (fits(mid)) {
          localBest = mid;
          low = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return localBest;
    }
  }

  void _scheduleTextPaginationForChapter({
    required int chapterIndex,
    required double viewportHeight,
    required double contentWidth,
    int minPages = 6,
  }) {
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) return;

    final tp = Provider.of<TranslationProvider>(context, listen: false);
    final prevEffectiveText = _chapterEffectiveText[chapterIndex];
    String effectiveText = plainText;
    if (tp.applyToReader) {
      effectiveText = _getEffectiveTextForChapter(chapterIndex, tp);
    }
    _chapterEffectiveText[chapterIndex] = effectiveText;

    final paginationKey = _paginationKey(
      viewportHeight: viewportHeight,
      contentWidth: contentWidth,
      textLength: effectiveText.length,
    );

    final prevKey = _chapterPageRangeKeys[chapterIndex];
    final keyChanged = prevKey != paginationKey;
    int? anchorIndex;
    if (keyChanged && chapterIndex == _currentChapterIndex) {
      final ranges = _chapterPageRanges[chapterIndex];
      if (ranges != null &&
          ranges.isNotEmpty &&
          _currentPageInChapter < ranges.length) {
        anchorIndex = ranges[_currentPageInChapter].start;
      }
    }

    if (keyChanged) {
      final prevRanges = _chapterPageRanges[chapterIndex];
      if (prevKey != null && prevRanges != null && prevRanges.isNotEmpty) {
        _chapterFallbackPageRangeKeys[chapterIndex] = prevKey;
        _chapterFallbackPageRanges[chapterIndex] = prevRanges;
        _chapterFallbackEffectiveText[chapterIndex] =
            prevEffectiveText ?? effectiveText;
      }
      _chapterPageRanges.remove(chapterIndex);
      _chapterPageRangeKeys.remove(chapterIndex);
      _chapterTextPaginationComplete.remove(chapterIndex);
      _chapterPageCounts.remove(chapterIndex);
    }

    final alreadyComplete =
        _chapterTextPaginationComplete[chapterIndex] ?? false;
    final existingRanges = _chapterPageRanges[chapterIndex];
    if (alreadyComplete &&
        existingRanges != null &&
        existingRanges.isNotEmpty) {
      _chapterPageCounts[chapterIndex] = existingRanges.length.clamp(1, 999999);
      return;
    }

    final int target = minPages.clamp(1, 999999);
    final prevTarget = _chapterTextPaginationTargetCounts[chapterIndex] ?? 0;
    if (target > prevTarget) {
      _chapterTextPaginationTargetCounts[chapterIndex] = target;
    }

    final taskKey = '$paginationKey|t$target';
    final existingTaskKey = _chapterTextPaginationTaskKeys[chapterIndex];
    if (existingTaskKey == taskKey &&
        _chapterTextPaginationTasks[chapterIndex] != null) {
      return;
    }

    _chapterTextPaginationTaskKeys[chapterIndex] = taskKey;

    final TextStyle textStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: _lineHeight,
      fontSize: _fontSize,
      color: _textColor,
    );
    final textScaler = MediaQuery.of(context).textScaler;

    _chapterTextPaginationTasks[chapterIndex] = Future<void>(() async {
      if (!mounted) return;
      if (_chapterTextPaginationTaskKeys[chapterIndex] != taskKey) return;

      final List<TextRange> ranges =
          List<TextRange>.from(_chapterPageRanges[chapterIndex] ?? const []);
      int start = ranges.isEmpty ? 0 : ranges.last.end;
      final int len = effectiveText.length;
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        strutStyle: StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true),
      );

      while (start < len) {
        final currentTarget =
            _chapterTextPaginationTargetCounts[chapterIndex] ?? 6;
        if (ranges.length >= currentTarget) break;

        final prevChars =
            ranges.isNotEmpty ? (ranges.last.end - ranges.last.start) : 800;
        int best = _bestEndForPage(
          text: effectiveText,
          start: start,
          textPainter: textPainter,
          textStyle: textStyle,
          viewportHeight: viewportHeight,
          contentWidth: contentWidth,
          previousPageChars: prevChars,
        );

        if (!_rangeHasNonWhitespace(effectiveText, start, best)) {
          start = best;
          while (start < len &&
              _isSkippableWhitespaceCu(effectiveText.codeUnitAt(start))) {
            start++;
          }
          continue;
        }

        ranges.add(TextRange(start: start, end: best));
        start = best;
        while (start < len &&
            _isSkippableWhitespaceCu(effectiveText.codeUnitAt(start))) {
          start++;
        }

        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
        if (_chapterTextPaginationTaskKeys[chapterIndex] != taskKey) return;
      }

      final complete = start >= len;
      if (!mounted) return;
      if (_chapterTextPaginationTaskKeys[chapterIndex] != taskKey) return;

      setState(() {
        _chapterPageRanges[chapterIndex] = ranges;
        _chapterPageRangeKeys[chapterIndex] = paginationKey;
        _chapterTextPaginationComplete[chapterIndex] = complete;
        _chapterPaginationLastMs[chapterIndex] =
            DateTime.now().millisecondsSinceEpoch;
        if (complete) {
          _chapterPageCounts[chapterIndex] = ranges.isEmpty ? 1 : ranges.length;
        } else {
          _chapterPageCounts[chapterIndex] = 999999;
        }

        final count = _chapterPageCounts[chapterIndex] ?? 999999;
        if (chapterIndex == _currentChapterIndex &&
            count != 999999 &&
            _currentPageInChapter >= count) {
          _currentPageInChapter = count - 1;
        }
        if (anchorIndex != null &&
            chapterIndex == _currentChapterIndex &&
            ranges.isNotEmpty) {
          int best = 0;
          for (int i = 0; i < ranges.length; i++) {
            if (anchorIndex! >= ranges[i].start &&
                anchorIndex! < ranges[i].end) {
              best = i;
              break;
            }
            if (ranges[i].start > anchorIndex!) {
              best = (i - 1).clamp(0, ranges.length - 1);
              break;
            }
            if (i == ranges.length - 1) best = i;
          }
          _currentPageInChapter = best;
        }
      });

      if (keyChanged) {
        _chapterFallbackPageRanges.remove(chapterIndex);
        _chapterFallbackPageRangeKeys.remove(chapterIndex);
        _chapterFallbackEffectiveText.remove(chapterIndex);
      }
    });
  }

  void _schedulePlainPaginationForChapter({
    required int chapterIndex,
    required double viewportHeight,
    required double contentWidth,
    int minPages = 6,
  }) {
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) return;

    final paginationKey = _paginationKey(
      viewportHeight: viewportHeight,
      contentWidth: contentWidth,
      textLength: plainText.length,
    );

    if (_chapterPlainPageRangeKeys[chapterIndex] != paginationKey) {
      _chapterPlainPageRanges.remove(chapterIndex);
      _chapterPlainPageRangeKeys.remove(chapterIndex);
      _chapterPlainPaginationComplete.remove(chapterIndex);
    }

    final alreadyComplete =
        _chapterPlainPaginationComplete[chapterIndex] ?? false;
    final existingRanges = _chapterPlainPageRanges[chapterIndex];
    if (alreadyComplete &&
        existingRanges != null &&
        existingRanges.isNotEmpty) {
      return;
    }

    final int target = minPages.clamp(1, 999999);
    final prevTarget = _chapterPlainPaginationTargetCounts[chapterIndex] ?? 0;
    if (target > prevTarget) {
      _chapterPlainPaginationTargetCounts[chapterIndex] = target;
    }

    final taskKey = '$paginationKey|t$target';
    final existingTaskKey = _chapterPlainPaginationTaskKeys[chapterIndex];
    if (existingTaskKey == taskKey &&
        _chapterPlainPaginationTasks[chapterIndex] != null) {
      return;
    }
    _chapterPlainPaginationTaskKeys[chapterIndex] = taskKey;

    final TextStyle textStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: _lineHeight,
      fontSize: _fontSize,
      color: _textColor,
    );
    final textScaler = MediaQuery.of(context).textScaler;

    _chapterPlainPaginationTasks[chapterIndex] = Future<void>(() async {
      if (!mounted) return;
      if (_chapterPlainPaginationTaskKeys[chapterIndex] != taskKey) return;

      final List<TextRange> ranges = List<TextRange>.from(
          _chapterPlainPageRanges[chapterIndex] ?? const []);
      int start = ranges.isEmpty ? 0 : ranges.last.end;
      final int len = plainText.length;
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        strutStyle: StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true),
      );

      while (start < len) {
        final currentTarget =
            _chapterPlainPaginationTargetCounts[chapterIndex] ?? 6;
        if (ranges.length >= currentTarget) break;

        final prevChars =
            ranges.isNotEmpty ? (ranges.last.end - ranges.last.start) : 800;
        int best = _bestEndForPage(
          text: plainText,
          start: start,
          textPainter: textPainter,
          textStyle: textStyle,
          viewportHeight: viewportHeight,
          contentWidth: contentWidth,
          previousPageChars: prevChars,
        );

        if (!_rangeHasNonWhitespace(plainText, start, best)) {
          start = best;
          while (start < len &&
              _isSkippableWhitespaceCu(plainText.codeUnitAt(start))) {
            start++;
          }
          continue;
        }

        ranges.add(TextRange(start: start, end: best));
        start = best;
        while (start < len &&
            _isSkippableWhitespaceCu(plainText.codeUnitAt(start))) {
          start++;
        }

        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
        if (_chapterPlainPaginationTaskKeys[chapterIndex] != taskKey) return;
      }

      final complete = start >= len;
      if (!mounted) return;
      if (_chapterPlainPaginationTaskKeys[chapterIndex] != taskKey) return;
      setState(() {
        _chapterPlainPageRanges[chapterIndex] = ranges;
        _chapterPlainPageRangeKeys[chapterIndex] = paginationKey;
        _chapterPlainPaginationComplete[chapterIndex] = complete;
      });
    });
  }

  void _invalidatePagination() {
    _chapterPageCounts.clear();
    _chapterPageRanges.clear();
    _chapterPageRangeKeys.clear();
    _chapterPlainPageRanges.clear();
    _chapterPlainPageRangeKeys.clear();
    _chapterTextPaginationTasks.clear();
    _chapterTextPaginationTaskKeys.clear();
    _chapterTextPaginationTargetCounts.clear();
    _chapterTextPaginationComplete.clear();
    _chapterPlainPaginationTasks.clear();
    _chapterPlainPaginationTaskKeys.clear();
    _chapterPlainPaginationTargetCounts.clear();
    _chapterPlainPaginationComplete.clear();
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
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return;
    if (_chapterContentCache[chapterIndex] != null ||
        _chapterPlainText[chapterIndex] != null) {
      return;
    }

    final chapter = _chapters[chapterIndex];
    if (chapter is _TextReaderChapter) {
      final loading = _chapterPlainLoading[chapterIndex];
      if (identical(loading, chapter)) return;
      _chapterPlainLoading[chapterIndex] = chapter;
      try {
        final plain = await chapter.readPlainText();
        if (!mounted) return;
        if (chapterIndex >= _chapters.length) return;
        if (!identical(_chapters[chapterIndex], chapter)) return;
        setState(() {
          _chapterPlainText[chapterIndex] = plain;
          final t = (chapter.title ?? '').trim();
          _chapterTitleLength[chapterIndex] = (t.isEmpty ? '正文' : t).length;
          _chapterParagraphsCache.remove(chapterIndex);
        });
      } finally {
        if (identical(_chapterPlainLoading[chapterIndex], chapter)) {
          _chapterPlainLoading.remove(chapterIndex);
        }
      }
      return;
    }

    final loading = _chapterHtmlLoading[chapterIndex];
    if (identical(loading, chapter)) return;
    _chapterHtmlLoading[chapterIndex] = chapter;
    try {
      String value = '';
      try {
        value = await chapter.readHtmlContent();
      } catch (_) {
        value = '';
      }
      if (!mounted) return;
      if (chapterIndex >= _chapters.length) return;
      if (!identical(_chapters[chapterIndex], chapter)) return;
      setState(() {
        _chapterContentCache[chapterIndex] = value;
      });
    } finally {
      if (identical(_chapterHtmlLoading[chapterIndex], chapter)) {
        _chapterHtmlLoading.remove(chapterIndex);
      }
    }
  }

  void _showTableOfContents() {
    const double itemExtent = 56;
    final int targetIndex = _chapters.isEmpty
        ? 0
        : _currentChapterIndex.clamp(0, _chapters.length - 1);
    final double initialOffset =
        ((targetIndex - 3).clamp(0, 999999) * itemExtent).toDouble();
    final ScrollController scrollController =
        ScrollController(initialScrollOffset: initialOffset);
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
                if (_currentBookFormat == 'txt' && _txtTocParsing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                _panelTextColor.withOpacity(0.6)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '解析中…',
                          style: TextStyle(
                            color: _panelTextColor.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                Divider(color: _panelTextColor.withOpacity(0.1)),
                Expanded(
                  child: Scrollbar(
                    controller: scrollController,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: scrollController,
                      itemExtent: itemExtent,
                      cacheExtent: itemExtent * 20,
                      itemCount: (_currentBookFormat == 'txt' && _txtTocParsing)
                          ? 1
                          : _chapters.length,
                      itemBuilder: (context, index) {
                        if (_currentBookFormat == 'txt' && _txtTocParsing) {
                          return ListTile(
                            title: Text(
                              '目录解析中…',
                              style: TextStyle(color: _panelTextColor),
                            ),
                          );
                        }
                        final chapter = _chapters[index];
                        return ListTile(
                          dense: true,
                          title: Text(
                            chapter.title ?? 'Chapter ${index + 1}',
                            style: TextStyle(
                              color: index == _currentChapterIndex
                                  ? AppColors.techBlue
                                  : _panelTextColor,
                              fontWeight: index == _currentChapterIndex
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
              if (!_pageController.hasClients) return;
              if (!mounted) return;
              if (_pageViewCenterIndex != 1000) {
                setState(() {
                  _pageViewCenterIndex = 1000;
                });
              }
              _pageController.jumpToPage(1000);
              _maybeAutoContinueReadAloudAfterPageTurn();
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
                return const SizedBox.shrink();
              }
            } else if (targetPage < 0) {
              if (targetChapter > 0) {
                targetChapter--;
                int prevCount = _pageCountForChapter(targetChapter);
                targetPage = prevCount - 1;
              } else {
                return const SizedBox.shrink();
              }
            }

            return _buildSinglePage(targetChapter, targetPage, padding);
          },
        ));
  }

  Widget _buildSinglePage(int chapterIndex, int pageIndex, EdgeInsets padding) {
    final chapter = _chapters[chapterIndex];

    if (chapter is _TextReaderChapter) {
      final cachedPlain = _chapterPlainText[chapterIndex];
      if (cachedPlain == null) {
        _ensureChapterContentCached(chapterIndex);
        return LayoutBuilder(
          builder: (context, constraints) {
            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) => _onReaderPointerDown(e.localPosition),
              onPointerMove: (e) => _onReaderPointerMove(e.localPosition),
              onPointerUp: (e) => _onReaderPointerUp(
                  pos: e.localPosition, width: constraints.maxWidth),
              child: const Center(child: CircularProgressIndicator()),
            );
          },
        );
      }
    } else {
      final content = _chapterContentCache[chapterIndex];
      if (content == null) {
        _ensureChapterContentCached(chapterIndex);
        return LayoutBuilder(
          builder: (context, constraints) {
            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) => _onReaderPointerDown(e.localPosition),
              onPointerMove: (e) => _onReaderPointerMove(e.localPosition),
              onPointerUp: (e) => _onReaderPointerUp(
                  pos: e.localPosition, width: constraints.maxWidth),
              child: const Center(child: CircularProgressIndicator()),
            );
          },
        );
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        double snap(double value) => (value * dpr).roundToDouble() / dpr;
        double snapDown(double value) => (value * dpr).floorToDouble() / dpr;

        final double topMargin = snap(padding.top + 16);
        final double bottomMargin = snap(padding.bottom + 8);

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

        _scheduleTextPaginationForChapter(
          chapterIndex: chapterIndex,
          viewportHeight: viewportHeight,
          contentWidth: contentWidth,
          minPages: (pageIndex + 3).clamp(6, 999999),
        );
        final tp = Provider.of<TranslationProvider>(context, listen: false);
        if (tp.applyToReader) {
          _schedulePlainPaginationForChapter(
            chapterIndex: chapterIndex,
            viewportHeight: viewportHeight,
            contentWidth: contentWidth,
            minPages: (pageIndex + 3).clamp(6, 999999),
          );
        }

        final ranges = _chapterPageRanges[chapterIndex];
        List<TextRange>? displayRanges = ranges;
        String? displayEffectiveText = _chapterEffectiveText[chapterIndex];
        if (displayRanges == null || displayRanges.isEmpty) {
          final fallbackRanges = _chapterFallbackPageRanges[chapterIndex];
          if (fallbackRanges != null && fallbackRanges.isNotEmpty) {
            displayRanges = fallbackRanges;
            displayEffectiveText = _chapterFallbackEffectiveText[chapterIndex];
          }
        }
        if (displayRanges == null || displayRanges.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (pageIndex >= displayRanges.length) {
          _scheduleTextPaginationForChapter(
            chapterIndex: chapterIndex,
            viewportHeight: viewportHeight,
            contentWidth: contentWidth,
            minPages: (pageIndex + 3).clamp(6, 999999),
          );
          if (tp.applyToReader) {
            _schedulePlainPaginationForChapter(
              chapterIndex: chapterIndex,
              viewportHeight: viewportHeight,
              contentWidth: contentWidth,
              minPages: (pageIndex + 3).clamp(6, 999999),
            );
          }
        }
        final String effectiveText =
            displayEffectiveText ?? _getPlainTextForChapter(chapterIndex);

        final pendingProgress = _pendingRestoreProgress;
        if (pendingProgress != null && chapterIndex == _currentChapterIndex) {
          final len = effectiveText.length;
          final complete =
              _chapterTextPaginationComplete[chapterIndex] ?? false;
          if (len > 0) {
            final int target =
                (pendingProgress.clamp(0.0, 1.0) * len).round().clamp(0, len);
            final int lastEnd = displayRanges.last.end;
            if (lastEnd < target && !complete) {
              _scheduleTextPaginationForChapter(
                chapterIndex: chapterIndex,
                viewportHeight: viewportHeight,
                contentWidth: contentWidth,
                minPages: (displayRanges.length + 30).clamp(30, 999999),
              );
              return const Center(child: CircularProgressIndicator());
            }
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_pendingRestoreProgress != pendingProgress) return;
            setState(() {
              _relocateCurrentPageToProgress(pendingProgress);
              _pageViewCenterIndex = 1000;
              _pendingRestoreProgress = null;
            });
            if (_pageController.hasClients) {
              _pageController.jumpToPage(1000);
            }
          });
          return const Center(child: CircularProgressIndicator());
        }

        final bool isCenterCurrent = chapterIndex == _currentChapterIndex &&
            pageIndex == _currentPageInChapter;
        if (isCenterCurrent && pageIndex >= displayRanges.length) {
          final complete =
              _chapterTextPaginationComplete[chapterIndex] ?? false;
          if (complete) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_currentChapterIndex != chapterIndex) return;
              final latest = _chapterPageRanges[chapterIndex] ??
                  _chapterFallbackPageRanges[chapterIndex];
              final int latestLen = latest?.length ?? 0;
              if (latestLen <= 0) return;
              final int nextPage =
                  _currentPageInChapter.clamp(0, latestLen - 1);
              if (nextPage == _currentPageInChapter) return;
              setState(() {
                _currentPageInChapter = nextPage;
                _pageViewCenterIndex = 1000;
              });
              if (_pageController.hasClients) {
                _pageController.jumpToPage(1000);
              }
            });
          }
          return const Center(child: CircularProgressIndicator());
        }

        final int safeIndex = pageIndex.clamp(0, displayRanges.length - 1);
        final range = displayRanges[safeIndex];
        final isCurrentPage = chapterIndex == _currentChapterIndex &&
            safeIndex == _currentPageInChapter;

        if (chapterIndex == _currentChapterIndex &&
            pageIndex == _currentPageInChapter) {
          final len = effectiveText.length;
          _currentPageProgressInChapter = len > 0 ? range.start / len : 0;
        }

        final int start = range.start.clamp(0, effectiveText.length);
        final int end = range.end.clamp(start, effectiveText.length);

        // For mixed text, we just style it as body, title logic is too complex to preserve for now
        final TextSpan span = _buildReaderSpan(
          text: effectiveText.substring(start, end),
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
    final translationProvider =
        Provider.of<TranslationProvider>(context, listen: false);

    // If we are in translation mode, we trigger translation requests for *visible* paragraphs.
    // But we RENDER what we have in effectiveText (which includes Cached Translations).

    if (translationProvider.applyToReader && isCurrentPage) {
      final currentVisible = chapterIndex == _currentChapterIndex
          ? _currentPageParagraphsByIndex()
          : const <int, String>{};
      if (currentVisible.isNotEmpty) {
        final nextVisible = _nextPageParagraphsByIndex();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final Map<int, String> toRequest = <int, String>{};

          void addOrdered(Map<int, String> source, int? offset) {
            final keys = source.keys.toList()..sort();
            for (final k in keys) {
              final t = source[k];
              if (t == null || t.trim().isEmpty) continue;
              if (translationProvider.getCachedTranslation(t) != null) continue;
              if (translationProvider.isTranslationPending(t)) continue;
              if (translationProvider.isTranslationFailed(t)) continue;
              final key = offset == null ? k : offset + k;
              if (toRequest.containsKey(key)) continue;
              toRequest[key] = t;
            }
          }

          addOrdered(currentVisible, null);
          if (nextVisible.isNotEmpty) {
            final nextRanges =
                _chapterPlainPageRanges[_currentChapterIndex] ?? const [];
            final isSameChapter = _currentPageInChapter + 1 < nextRanges.length;
            addOrdered(nextVisible, isSameChapter ? null : 100000);
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
          final tp = context.read<TranslationProvider>();
          final showReadCurrent = isCurrentPage && tp.aiReadAloudEnabled;

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
                if (showReadCurrent)
                  TextButton(
                    onPressed: () {
                      final text = state.textEditingValue.text;
                      final start = selection.start.clamp(0, text.length);
                      int seg = 0;
                      int scan = 0;
                      while (true) {
                        final idx = text.indexOf('\n\n', scan);
                        if (idx < 0 || idx >= start) break;
                        seg++;
                        scan = idx + 2;
                      }
                      final visible = _currentPageParagraphsByIndex();
                      final keys = visible.keys.toList()..sort();
                      if (keys.isEmpty) return;
                      final paragraphIndex =
                          keys[seg.clamp(0, keys.length - 1)];
                      final currentSelection = state.textEditingValue.selection;
                      state.hideToolbar();
                      state.userUpdateTextEditingValue(
                        state.textEditingValue.copyWith(
                          selection: TextSelection.collapsed(
                            offset: currentSelection.end,
                          ),
                        ),
                        SelectionChangedCause.toolbar,
                      );
                      unawaited(
                          _startReadAloudFromParagraphIndex(paragraphIndex));
                    },
                    child: const Text('读当前'),
                  ),
                TextButton(
                  onPressed: selectedText.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: selectedText));
                          final selection = state.textEditingValue.selection;
                          state.hideToolbar();
                          state.userUpdateTextEditingValue(
                            state.textEditingValue.copyWith(
                              selection: TextSelection.collapsed(
                                offset: selection.end,
                              ),
                            ),
                            SelectionChangedCause.toolbar,
                          );
                        },
                  child: const Text('复制'),
                ),
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

  Map<int, String> _paragraphsByIndexForPage({
    required int chapterIndex,
    required int pageIndex,
  }) {
    final ranges = _chapterPlainPageRanges[chapterIndex];
    if (ranges == null || ranges.isEmpty) return {};
    if (pageIndex < 0 || pageIndex >= ranges.length) return {};
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) {
      _ensureChapterContentCached(chapterIndex);
      return {};
    }
    final range = ranges[pageIndex];
    final end = range.end.clamp(0, plainText.length);
    return _paragraphsByIndexForRange(
      chapterIndex: chapterIndex,
      plainText: plainText,
      start: range.start,
      end: end,
    );
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

  int _currentPlainPageIndex() {
    final ranges = _chapterPlainPageRanges[_currentChapterIndex];
    if (ranges == null || ranges.isEmpty) return _currentPageInChapter;
    return _plainPageIndexForProgress(
      _currentChapterIndex,
      _currentPageProgressInChapter,
    );
  }

  Map<int, String> _nextPageParagraphsByIndex() {
    int chapterIndex = _currentChapterIndex;
    int pageIndex = _currentPageInChapter + 1;
    List<TextRange>? ranges = _chapterPlainPageRanges[chapterIndex];
    if (ranges == null || ranges.isEmpty) return {};
    if (pageIndex >= ranges.length) {
      chapterIndex++;
      pageIndex = 0;
      if (chapterIndex >= _chapters.length) return {};
      ranges = _chapterPlainPageRanges[chapterIndex];
      if (ranges == null || ranges.isEmpty) {
        _ensureChapterContentCached(chapterIndex);
        return {};
      }
    }

    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) {
      _ensureChapterContentCached(chapterIndex);
      return {};
    }
    final range = ranges[pageIndex];
    final end = range.end.clamp(0, plainText.length);
    return _paragraphsByIndexForRange(
      chapterIndex: chapterIndex,
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
    if (visibleSorted.isEmpty) return out;
    final int firstVisibleIdx = visibleSorted.first;
    final int lastVisibleIdx = visibleSorted.last;

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

  void _kickoffTranslationPrefetch(TranslationProvider provider) {
    _prefetchKickTimer?.cancel();
    _prefetchKickTimer = null;
    _prefetchKickAttempts = 0;

    void attempt() {
      if (!mounted) return;
      final visible = _currentPageParagraphsByIndex();
      if (visible.isEmpty) {
        _prefetchKickAttempts++;
        if (_prefetchKickAttempts < 12) {
          _prefetchKickTimer =
              Timer(const Duration(milliseconds: 120), attempt);
        }
        return;
      }

      final next = _nextParagraphsForPrefetch(count: 10);
      if (next.isNotEmpty) {
        provider.prefetchParagraphs(next);
      }
      _updatePrefetchCursorFromVisible();
      _startContinuousPrefetch();
    }

    attempt();
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
    _prefetchKickTimer?.cancel();
    _prefetchKickTimer = null;
    _prefetchKickAttempts = 0;
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
    if (currentVisible.isEmpty) return;
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

      if (_prefetchCursorChapterIndex == null) {
        _updatePrefetchCursorFromVisible();
      }
      final cursorChapter = _prefetchCursorChapterIndex;
      if (cursorChapter == null) return;
      int chapterIndex = cursorChapter;
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
    final currentReadAloudEngine = tp.readAloudEngine;
    final lastReadAloudEngine = _lastReadAloudEngine;
    bool engineChanged = false;
    bool ttsConfigChanged = false;
    if (lastReadAloudEngine == null) {
      _lastReadAloudEngine = currentReadAloudEngine;
    } else if (lastReadAloudEngine != currentReadAloudEngine) {
      engineChanged = true;
      _lastReadAloudEngine = currentReadAloudEngine;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_aiReadAloudPlaying && !_aiReadAloudPreparing) return;
        unawaited(() async {
          await _stopReadAloud(keepResume: true);
          if (!mounted) return;
          await _startReadAloud();
        }());
      });
    }
    final lastTtsSpeed = _lastTtsSpeed;
    if (lastTtsSpeed == null) {
      _lastTtsSpeed = tp.ttsSpeed;
    } else if (lastTtsSpeed != tp.ttsSpeed) {
      _lastTtsSpeed = tp.ttsSpeed;
      ttsConfigChanged = true;
    }
    final lastVoiceType = _lastTtsVoiceType;
    if (lastVoiceType == null) {
      _lastTtsVoiceType = tp.ttsVoiceType;
    } else if (lastVoiceType != tp.ttsVoiceType) {
      _lastTtsVoiceType = tp.ttsVoiceType;
      ttsConfigChanged = true;
    }
    final lastReadTranslation = _lastReadTranslationEnabled;
    if (lastReadTranslation == null) {
      _lastReadTranslationEnabled = tp.readTranslationEnabled;
    } else if (lastReadTranslation != tp.readTranslationEnabled) {
      _lastReadTranslationEnabled = tp.readTranslationEnabled;
      ttsConfigChanged = true;
    }
    if (ttsConfigChanged && !engineChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_aiReadAloudPlaying && !_aiReadAloudPreparing) return;
        unawaited(() async {
          await _stopReadAloud(keepResume: true);
          if (!mounted) return;
          await _startReadAloud();
        }());
      });
    }
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
      child: PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (didPop) return;
          _popReader();
        },
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
                if (_showControls)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleControls,
                      child: Container(color: Colors.transparent),
                    ),
                  ),
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
                          onTap: _popReader,
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
                                        spreadRadius:
                                            2 * _pulseController.value,
                                      ),
                                    ],
                                  ),
                                  child: child,
                                );
                              },
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: const BoxDecoration(
                                  color: Colors.transparent,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.auto_awesome,
                                    size: 24, color: AppColors.techBlue),
                              ),
                            ),
                          ),
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
      ),
    );
  }
}
