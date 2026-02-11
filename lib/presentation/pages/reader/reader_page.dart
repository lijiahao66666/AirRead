import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:epubx/epubx.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_tokens.dart';
import '../../widgets/ai_hud.dart';
import '../../widgets/glass_panel.dart';
import '../../widgets/illustration_panel.dart';
import '../../providers/books_provider.dart';
import '../../providers/ai_model_provider.dart';
import '../../providers/illustration_provider.dart';
import '../../providers/read_aloud_provider.dart';
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
  final bool hasSubChapters;
  final int? parentIndex;
  _EpubReaderChapter(this.ref,
      {String? titleOverride, this.hasSubChapters = false, this.parentIndex})
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
    // Always write the chapter title at the beginning
    final titleText = _title.trim().isEmpty ? '正文' : _title.trim();
    buffer.write(titleText);

    final int start = _start.clamp(0, _sourceText.length);
    final int end = _end.clamp(start, _sourceText.length);
    if (start >= end) return buffer.toString();
    buffer.write('\n\n');

    final paraBuffer = StringBuffer();
    String? prevLineInPara;
    int processedLines = 0;

    bool isFirstPara = true;
    void flushPara() {
      if (paraBuffer.isEmpty) return;
      if (isFirstPara) {
        isFirstPara = false;
      } else {
        buffer.write('\n\n');
      }
      buffer.write(paraBuffer.toString());
      paraBuffer.clear();
      prevLineInPara = null;
    }

    bool looksLikeParagraphStart(String rawLine, String t) {
      if (rawLine.startsWith('\u3000\u3000')) return true;
      if (rawLine.startsWith('  ')) return true;
      if (rawLine.startsWith('\t')) return true;
      if (RegExp(r'^[-*•]\s+').hasMatch(t)) return true;
      if (RegExp(r'^\d{1,3}[\.、]\s*').hasMatch(t)) return true;
      if (RegExp(r'^[一二三四五六七八九十]{1,3}[、\.]\s*').hasMatch(t)) {
        return true;
      }
      return false;
    }

    bool endsSentence(String s) {
      if (s.isEmpty) return false;
      final last = s.codeUnitAt(s.length - 1);
      if (last == 0x3002) return true;
      if (last == 0xFF01) return true;
      if (last == 0xFF1F) return true;
      if (last == 0x002E) return true;
      if (last == 0x003F) return true;
      if (last == 0x0021) return true;
      if (s.endsWith('……')) return true;
      if (s.endsWith('...')) return true;
      return false;
    }

    int sampleNonEmpty = 0;
    int sampleBlank = 0;
    int sampleIndent = 0;
    int sampleLenSum = 0;
    int sampleLines = 0;
    int j = start;
    while (j < end && sampleLines < 200) {
      int lineStart = j;
      int lineEnd = j;
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
        sampleBlank++;
      } else {
        sampleNonEmpty++;
        sampleLenSum += t.length;
        if (looksLikeParagraphStart(rawLine, t)) sampleIndent++;
      }
      sampleLines++;
      j = next;
    }

    final bool hasBlankLines = sampleBlank >= 2;
    final double avgLen =
        sampleNonEmpty == 0 ? 0 : (sampleLenSum / sampleNonEmpty);
    final double indentRatio =
        sampleNonEmpty == 0 ? 0 : (sampleIndent / sampleNonEmpty);

    final bool splitEachLine =
        !hasBlankLines && indentRatio < 0.12 && avgLen > 0 && avgLen <= 40;
    final bool wrapByPunctuation =
        !hasBlankLines && !splitEachLine && avgLen >= 55 && indentRatio < 0.08;

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
        if (paraBuffer.isNotEmpty && looksLikeParagraphStart(rawLine, t)) {
          flushPara();
        }
        if (splitEachLine) {
          if (paraBuffer.isNotEmpty) {
            flushPara();
          }
          paraBuffer.write(t);
          prevLineInPara = t;
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
          if (wrapByPunctuation && endsSentence(t)) {
            flushPara();
          }
        }
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

enum _TranslationQueueState {
  queued,
  translating,
  translated,
  inserted,
  failed,
}

class _TranslationQueueItem {
  final int chapterIndex;
  final int paragraphIndex;
  final String text;

  const _TranslationQueueItem({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.text,
  });

  String get key => '$chapterIndex:$paragraphIndex';
}

class _TranslatedResult {
  final _TranslationQueueItem item;
  final String? translated;
  final bool success;

  const _TranslatedResult({
    required this.item,
    required this.translated,
    required this.success,
  });
}

class _TranslationPageSlice {
  final int chapterIndex;
  final Map<int, String> paragraphsByIndex;

  const _TranslationPageSlice({
    required this.chapterIndex,
    required this.paragraphsByIndex,
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

  Timer? _centerToastTimer;
  String _centerToastText = '';
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
  bool _followSystemTheme = true;

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
  int _readAloudTranslationRevision = -1;
  Offset? _readAloudFabOffset;
  Offset? _illustrationFabOffset;
  double _readAloudBackSpinTurns = 0.0;
  double _readAloudForwardSpinTurns = 0.0;
  bool _readAloudFollow = true;
  int? _readAloudFollowChapter;
  int? _readAloudFollowPage;
  String? _readAloudAutoContinueHandledKey;
  bool _readAloudNavInFlight = false;
  int _selectionAreaResetToken = 0;

  final AudioPlayer _readAloudPlayer = AudioPlayer();
  final Map<String, Uint8List> _readAloudAudioCache = {};
  final Map<String, Future<Uint8List>> _readAloudAudioInFlight = {};
  String? _readAloudTempFilePath;
  TencentTtsClient? _tencentTtsClient;
  final WebSpeechTts _webSpeechTts = createWebSpeechTts();
  bool _currentPageTranslateResumeScheduled = false;
  bool _onlinePrefetchRunning = false;
  bool _onlinePrefetchNeedsRerun = false;
  final Queue<_TranslationQueueItem> _translationQueue = Queue();
  final Queue<_TranslatedResult> _translatedResultsQueue = Queue();
  final Map<String, _TranslationQueueState> _translationQueueStates = {};
  final Set<String> _translationQueueKeys = {};
  int _translationQueueSession = 0;
  String? _translationQueueAnchorKey;
  bool _translationQueueRunning = false;
  bool _translationInsertRunning = false;
  int _translationQueueTotal = 0;
  int _translationQueueCompleted = 0;
  int _translationQueueFailed = 0;
  int _translationInsertFailed = 0;
  int _translationQueuePendingExternal = 0;
  bool _translationQueueInFlight = false;

  List<_ReaderChapter> _chapters = [];
  int _currentChapterIndex = 0;
  final Set<int> _expandedChapterIndices = {};
  final Set<int> _illustrationAutoAnalyzeRequested = {};

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
  bool _readAloudSyncScheduled = false;
  String? _lastReadAloudSyncKey;

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
  int _suppressReaderTapUntilMs = 0;
  AiModelProvider? _aiModel;
  VoidCallback? _aiModelListener;
  bool _lastIllustrationEnabled = false;
  int _lastAiPointsBalance = 0;
  bool _lastAiLoaded = false;
  AiModelSource _lastAiSource = AiModelSource.none;
  String? _lastIllustrationUiLogKey;
  VoidCallback? _illustrationListener;
  Set<String> _lastAnalyzingChapterIds = {};
  final Set<String> _pendingIllustrationCompletionChapterIds = {};
  bool _lastAiReadAloudEnabled = false;
  Timer? _floatingUiAutoHideTimer;
  bool _readAloudFabCollapsed = false;
  bool _illustrationFabCollapsed = false;

  static const double _kFloatingCapsuleHeight = 52;
  static const double _kFloatingHandleWidth = 22;
  static const double _kReadAloudExpandedWidth = 150;
  static const double _kIllustrationExpandedWidth = 110;

  double _readAloudFabWidth(bool collapsed) {
    return collapsed
        ? _kFloatingHandleWidth
        : (_kReadAloudExpandedWidth + _kFloatingHandleWidth);
  }

  double _illustrationFabWidth(bool collapsed) {
    return collapsed
        ? _kFloatingHandleWidth
        : (_kIllustrationExpandedWidth + _kFloatingHandleWidth);
  }

  void _collapseFloatingUi() {
    final readOldW = _readAloudFabWidth(_readAloudFabCollapsed);
    final readNewW = _readAloudFabWidth(true);
    final illuOldW = _illustrationFabWidth(_illustrationFabCollapsed);
    final illuNewW = _illustrationFabWidth(true);
    final readOffset = _readAloudFabOffset;
    final illuOffset = _illustrationFabOffset;

    setState(() {
      if (!_readAloudFabCollapsed && readOffset != null) {
        _readAloudFabOffset = readOffset.translate(readOldW - readNewW, 0);
      }
      if (!_illustrationFabCollapsed && illuOffset != null) {
        _illustrationFabOffset = illuOffset.translate(illuOldW - illuNewW, 0);
      }
      _readAloudFabCollapsed = true;
      _illustrationFabCollapsed = true;
    });
  }

  void _setReadAloudFabCollapsed(bool value) {
    if (_readAloudFabCollapsed == value) return;
    final oldW = _readAloudFabWidth(_readAloudFabCollapsed);
    final newW = _readAloudFabWidth(value);
    final offset = _readAloudFabOffset;
    setState(() {
      _readAloudFabCollapsed = value;
      if (offset != null) {
        _readAloudFabOffset = offset.translate(oldW - newW, 0);
      }
    });
  }

  void _setIllustrationFabCollapsed(bool value) {
    if (_illustrationFabCollapsed == value) return;
    final oldW = _illustrationFabWidth(_illustrationFabCollapsed);
    final newW = _illustrationFabWidth(value);
    final offset = _illustrationFabOffset;
    setState(() {
      _illustrationFabCollapsed = value;
      if (offset != null) {
        _illustrationFabOffset = offset.translate(oldW - newW, 0);
      }
    });
  }

  void _armFloatingUiAutoHideIfNeeded() {
    if (_floatingUiAutoHideTimer?.isActive ?? false) return;
    _touchFloatingUi();
  }

  void _touchFloatingUi() {
    _floatingUiAutoHideTimer?.cancel();
    _floatingUiAutoHideTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      _collapseFloatingUi();
    });
  }

  void _showCenterToast(String msg) {
    if (!mounted) return;
    setState(() {
      _centerToastText = msg;
    });
    // Auto hide after 2.5s
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted && _centerToastText == msg) {
        setState(() {
          _centerToastText = '';
        });
      }
    });
  }

  void _showTopError(String msg, {bool isError = true}) {
    _showCenterToast(msg);
  }

  double _readerTopExtraForOverlay(BuildContext context) {
    final dpr = View.of(context).devicePixelRatio;
    double snap(double value) => (value * dpr).roundToDouble() / dpr;
    final TextStyle effectiveTextStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: _lineHeight,
      fontSize: _fontSize,
      color: _textColor,
    );
    final maxWidth = MediaQuery.of(context).size.width;
    final safeContentWidth =
        (maxWidth - 48).clamp(40.0, maxWidth <= 1 ? 1.0 : maxWidth);
    final textScaler = MediaQuery.of(context).textScaler;
    final probe = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
      strutStyle:
          StrutStyle.fromTextStyle(effectiveTextStyle, forceStrutHeight: true),
      text: TextSpan(text: '国Ay', style: effectiveTextStyle),
    )..layout(minWidth: 0, maxWidth: safeContentWidth);
    final minLineHeight = probe.height;
    return snap((minLineHeight * 0.18).clamp(4.0, 10.0));
  }

  void _consumePendingIllustrationCompletionToastForCurrentChapter() {
    final chapterId = '${widget.bookId}::$_currentChapterIndex';
    if (!_pendingIllustrationCompletionChapterIds.remove(chapterId)) return;
    final p = context.read<IllustrationProvider>();
    final analyzed = p.hasChapter(chapterId);
    if (!analyzed) {
      _showCenterToast('插图分析失败');
      return;
    }
    final scenes = p.getScenes(chapterId);
    _showCenterToast(scenes.isNotEmpty ? '插图分析完成' : '无适合插画的场景');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Setup IllustrationProvider listener
    final illuProvider = context.read<IllustrationProvider>();
    _lastAnalyzingChapterIds = illuProvider.analyzingChapterIds.toSet();
    _illustrationListener = () {
      if (!mounted) return;
      final p = context.read<IllustrationProvider>();
      final nowAnalyzing = p.analyzingChapterIds.toSet();
      final finished = _lastAnalyzingChapterIds.difference(nowAnalyzing);
      if (finished.isNotEmpty) {
        final currentChapterId = '${widget.bookId}::$_currentChapterIndex';
        for (final chapterId in finished) {
          final analyzed = p.hasChapter(chapterId);
          final scenes = p.getScenes(chapterId);
          final msg = !analyzed
              ? '插图分析失败'
              : (scenes.isNotEmpty ? '插图分析完成' : '无适合插画的场景');
          if (chapterId == currentChapterId) {
            _showCenterToast(msg);
          } else {
            _pendingIllustrationCompletionChapterIds.add(chapterId);
          }
        }
      }
      _lastAnalyzingChapterIds = nowAnalyzing;
    };
    illuProvider.addListener(_illustrationListener!);

    // Setup TranslationProvider error handler
    final transProvider = context.read<TranslationProvider>();
    _lastAiReadAloudEnabled = transProvider.aiReadAloudEnabled;
    transProvider.onError = (msg) {
      if (!mounted) return;
      _showTopError(msg);
    };
    unawaited(transProvider.bindBook(widget.bookId));

    final aiModel = context.read<AiModelProvider>();
    _aiModel = aiModel;
    _lastIllustrationEnabled = aiModel.illustrationEnabled;
    _lastAiPointsBalance = aiModel.pointsBalance;
    _lastAiLoaded = aiModel.loaded;
    _lastAiSource = aiModel.source;
    _aiModelListener = () {
      if (!mounted) return;
      final m = _aiModel;
      if (m == null) return;
      final nowIllustrationEnabled = m.illustrationEnabled;
      final nowPoints = m.pointsBalance;
      final nowLoaded = m.loaded;
      final nowSource = m.source;

      final shouldRetryAnalyze = nowIllustrationEnabled &&
          (!_lastIllustrationEnabled ||
              (nowPoints > 0 && _lastAiPointsBalance <= 0) ||
              (nowLoaded && !_lastAiLoaded) ||
              (nowSource != _lastAiSource));

      if (nowIllustrationEnabled && !_lastIllustrationEnabled) {
        _setIllustrationFabCollapsed(false);
        _touchFloatingUi();
      }

      _lastIllustrationEnabled = nowIllustrationEnabled;
      _lastAiPointsBalance = nowPoints;
      _lastAiLoaded = nowLoaded;
      _lastAiSource = nowSource;

      if (!shouldRetryAnalyze) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_maybeAnalyzeIllustrationsForChapter(_currentChapterIndex));
      });
    };
    aiModel.addListener(_aiModelListener!);

    _pageController = PageController(initialPage: 1000);
    _pageViewCenterIndex = 1000;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    // Controls Animation
    _controlsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _topBarOffset =
        Tween<Offset>(begin: const Offset(0, -1.12), end: Offset.zero).animate(
      CurvedAnimation(parent: _controlsController, curve: Curves.easeOut),
    );
    _bottomBarOffset =
        Tween<Offset>(begin: const Offset(0, 1.12), end: Offset.zero).animate(
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
  void didChangePlatformBrightness() {
    if (!mounted) return;
    if (!_followSystemTheme) return;
    final isSystemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    setState(() {
      if (isSystemDark) {
        _bgColor = const Color(0xFF121212);
        _textColor = const Color(0xFFEEEEEE);
      } else {
        _bgColor = const Color(0xFFF5F9FA);
        _textColor = const Color(0xFF2C3E50);
      }
    });
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

  // Keywords to identify cover/toc chapters that should be skipped
  static final Set<String> _skipChapterKeywords = {
    'cover',
    '封面',
    'toc',
    'table of contents',
    '目录',
    '目次',
  };

  bool _shouldSkipChapter(String? title, String? href) {
    final t = (title ?? '').toLowerCase().trim();
    final h = (href ?? '').toLowerCase().trim();

    // Check title keywords
    for (final keyword in _skipChapterKeywords) {
      if (t.contains(keyword)) return true;
    }

    // Check href patterns (common EPUB file naming)
    if (h.contains('cover') ||
        h.contains('toc') ||
        h.contains('titlepage') ||
        h.contains('copyright')) {
      return true;
    }

    return false;
  }

  List<_ReaderChapter> _buildEpubChapters(List<EpubChapterRef> roots) {
    final chapters = <_ReaderChapter>[];

    void walk(List<EpubChapterRef> items, int depth, int? parentIdx) {
      for (final c in items) {
        final rawTitle = (c.Title ?? '').trim();
        final href = c.ContentFileName ?? '';

        // Skip cover/toc chapters
        if (_shouldSkipChapter(rawTitle, href)) {
          // Still process sub-chapters if any
          final subs = c.SubChapters;
          if (subs != null && subs.isNotEmpty) {
            walk(subs, depth + 1, parentIdx);
          }
          continue;
        }

        // Check if this chapter has sub-chapters
        final subs = c.SubChapters;
        final hasSubs = subs != null && subs.isNotEmpty;

        // Add prefix based on depth for hierarchical display
        final prefix = depth > 0 ? ('  ' * depth) : '';
        final displayTitle = rawTitle.isEmpty ? null : '$prefix$rawTitle';

        final currentIdx = chapters.length;
        chapters.add(_EpubReaderChapter(c,
            titleOverride: displayTitle,
            hasSubChapters: hasSubs,
            parentIndex: parentIdx));

        if (hasSubs) {
          walk(subs, depth + 1, currentIdx);
        }
      }
    }

    walk(roots, 0, null);
    return chapters;
  }

  Future<void> _loadSettingsAndBook() async {
    _prefs = await SharedPreferences.getInstance();

    // Load Settings
    if (mounted) {
      // Check system brightness for default theme
      final brightness = MediaQuery.platformBrightnessOf(context);
      final isSystemDark = brightness == Brightness.dark;

      setState(() {
        _fontSize = _prefs?.getDouble('fontSize') ?? 18.0;
        _lineHeight = _prefs?.getDouble('lineHeight') ?? 1.4;
        _followSystemTheme = true;
        if (isSystemDark) {
          _bgColor = const Color(0xFF121212);
          _textColor = const Color(0xFFEEEEEE);
        } else {
          _bgColor = const Color(0xFFF5F9FA);
          _textColor = const Color(0xFF2C3E50);
        }

        _aiReadAloudPlaying = false;
      });
    }

    try {
      await _prefs?.remove('reader_follow_system_theme');
      await _prefs?.remove('bgColor');
      await _prefs?.remove('textColor');
    } catch (_) {}

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
      if (_illustrationListener != null) {
        context
            .read<IllustrationProvider>()
            .removeListener(_illustrationListener!);
      }
    } catch (_) {}
    try {
      context.read<TranslationProvider>().onError = null;
    } catch (_) {}
    try {
      _centerToastTimer?.cancel();
      if (_aiModelListener != null) {
        _aiModel?.removeListener(_aiModelListener!);
      }
    } catch (_) {}
    _saveSettings();
    _saveProgress();
    _progressSaveTimer?.cancel();
    _floatingUiAutoHideTimer?.cancel();
    _localTtsSub?.cancel();
    unawaited(_webSpeechTts.stop());
    unawaited(_cleanupReadAloudTempFile());
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
    try {
      await prefs.remove('reader_follow_system_theme');
      await prefs.remove('bgColor');
      await prefs.remove('textColor');
    } catch (_) {}

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
      final overall = _computeOverallProgress().clamp(0.0, 1.0);
      await booksProvider.saveReadingProgress(
        bookId: widget.bookId,
        chapterIndex: _currentChapterIndex,
        pageInChapter: _currentPageInChapter,
        progress: _currentPageProgressInChapter.clamp(0.0, 1.0),
        overallProgress: overall,
      );
      _currentBook = _currentBook?.copyWith(
        readingChapter: _currentChapterIndex,
        readingPage: _currentPageInChapter,
        readingProgress: _currentPageProgressInChapter.clamp(0.0, 1.0),
        percentage: overall,
        lastRead: DateTime.now(),
      );
    } catch (_) {}
  }

  double _computeOverallProgress() {
    final totalChapters = _chapters.length;
    if (totalChapters <= 0) return 0.0;
    final chapterIndex = _currentChapterIndex.clamp(0, totalChapters - 1);
    final within = _computeChapterProgressByParagraphs(chapterIndex);
    if (totalChapters == 1) return within;
    return (chapterIndex + within) / totalChapters;
  }

  double _computeChapterProgressByParagraphs(int chapterIndex) {
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) return 0.0;
    final paragraphs = _getParagraphsForChapter(chapterIndex, plainText);
    final totalParas = paragraphs.length;
    if (totalParas <= 0) return 0.0;

    final ranges = _chapterPageRanges[chapterIndex] ??
        _chapterFallbackPageRanges[chapterIndex];
    final effectiveText = _chapterEffectiveText[chapterIndex] ?? plainText;
    if (ranges == null || ranges.isEmpty) {
      final p = _currentPageProgressInChapter.clamp(0.0, 1.0);
      return p;
    }
    final safeIndex = _currentPageInChapter.clamp(0, ranges.length - 1);
    final offset = ranges[safeIndex].start.clamp(0, effectiveText.length);

    int paraIndex = 0;
    int i = 0;
    final int limit = offset.clamp(0, effectiveText.length);
    while (i + 1 < limit) {
      if (effectiveText.codeUnitAt(i) == 10 &&
          effectiveText.codeUnitAt(i + 1) == 10) {
        paraIndex++;
        i += 2;
      } else {
        i++;
      }
    }
    if (paraIndex <= 0) return 0.0;
    if (paraIndex >= totalParas) return 1.0;
    return (paraIndex / totalParas).clamp(0.0, 1.0);
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

  // Patterns to identify TOC/front matter lines in TXT files
  static final RegExp _txtTocPattern = RegExp(
    r'^(目\s*录|contents|目录|目次|table of contents)|'
    r'^(第[一二三四五六七八九十百千零〇两\d]+章.*|Chapter\s+\d+.*)|'
    r'^(序\s*(章|言)|前\s*言|楔\s*子|引\s*子)',
    caseSensitive: false,
  );

  int _txtBodyStart({required String text, required String bookTitle}) {
    final trimmedBookTitle = bookTitle.trim();
    final int bomOffset =
        text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;

    // Keywords that indicate front matter / TOC sections
    final frontMatterKeywords = [
      '封面',
      '书名',
      '作者',
      '版权',
      '出版',
      '简介',
      '目录',
      'contents',
      'cover',
      'title',
      'author',
      'copyright',
      'introduction',
      'preface',
      '前言',
      '序言',
      '说明',
    ];

    int i = bomOffset;
    int scanned = 0;
    int firstContentPos = bomOffset;
    bool foundTitle = false;

    while (i < text.length && scanned < 300) {
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
          // Check if this is the book title
          if (!foundTitle &&
              trimmedBookTitle.isNotEmpty &&
              t == trimmedBookTitle) {
            foundTitle = true;
            i = next;
            scanned++;
            continue;
          }

          // Check if this looks like TOC or front matter
          final lowerT = t.toLowerCase();
          bool isFrontMatter = false;
          for (final keyword in frontMatterKeywords) {
            if (lowerT.contains(keyword)) {
              isFrontMatter = true;
              break;
            }
          }

          // Check if it matches TOC patterns
          if (!isFrontMatter && _txtTocPattern.hasMatch(t)) {
            isFrontMatter = true;
          }

          if (!isFrontMatter) {
            // This looks like actual content, return this position
            return lineStart;
          }
        }
      }
      scanned++;
      i = next;
    }

    return firstContentPos;
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

    // Toggle Animation
    if (next) {
      _controlsController.forward();
    } else {
      _controlsController.reverse();
    }
  }

  void _onReaderPointerDown(Offset pos) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs <= _suppressReaderTapUntilMs) return;
    _tapDownPos = pos;
    _tapDownMs = nowMs;
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
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs <= _suppressReaderTapUntilMs) {
      _tapDownMs = null;
      _tapDownPos = null;
      _tapMoved = false;
      return;
    }
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

  void _suppressReaderTap() {
    _tapDownMs = null;
    _tapDownPos = null;
    _tapMoved = false;
    _suppressReaderTapUntilMs = DateTime.now().millisecondsSinceEpoch + 800;
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
      if (mounted) {
        // Force hide controls when returning from AI HUD
        setState(() {
          _showControls = false;
        });
        _controlsController.reverse();
      }
    });
  }

  Future<void> _showSelectionTranslation(String sourceText) async {
    final text = sourceText.trim();
    if (text.isEmpty) return;
    final tp = context.read<TranslationProvider>();
    Map<int, String> result;
    try {
      result = await tp.translateParagraphsByIndex({0: text});
    } catch (e) {
      if (!mounted) return;
      _showTopError(e.toString());
      return;
    }
    if (!mounted) return;
    final translated =
        result.values.isNotEmpty ? result.values.first.trim() : '';
    final displayTranslation = translated.isEmpty ? '翻译失败' : translated;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final media = MediaQuery.of(context);
        final panelText = _panelTextColor;
        final panelBg = _panelBgColor;
        final cardBg = panelBg.computeLuminance() < 0.5
            ? Colors.white.withOpacityCompat(0.06)
            : AppColors.mistWhite;
        return GlassPanel.sheet(
          surfaceColor: panelBg,
          opacity: AppTokens.glassOpacityDense,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height:
                  (media.size.height * 0.62).clamp(320.0, media.size.height),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
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
                          icon: Icon(Icons.close,
                              color: panelText.withOpacityCompat(0.7)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '原文',
                              style: TextStyle(
                                  color: panelText,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: cardBg,
                                borderRadius:
                                    BorderRadius.circular(AppTokens.radiusMd),
                                border: Border.all(
                                  color: panelText.withOpacityCompat(0.08),
                                  width: AppTokens.stroke,
                                ),
                              ),
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                text,
                                style: TextStyle(
                                  color: panelText.withOpacityCompat(0.9),
                                  height: 1.5,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '译文',
                              style: TextStyle(
                                  color: panelText,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: cardBg,
                                borderRadius:
                                    BorderRadius.circular(AppTokens.radiusMd),
                                border: Border.all(
                                  color: panelText.withOpacityCompat(0.08),
                                  width: AppTokens.stroke,
                                ),
                              ),
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                displayTranslation,
                                style: TextStyle(
                                  color: panelText.withOpacityCompat(0.9),
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _hideControls() {
    if (_showControls) {
      setState(() {
        _showControls = false;
      });
    }
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
      _translationQueue.clear();
      _translatedResultsQueue.clear();
      _translationQueueStates.clear();
      _translationQueueKeys.clear();
      _translationQueueTotal = 0;
      _translationQueueCompleted = 0;
      _translationQueueFailed = 0;
      _translationQueuePendingExternal = 0;
      _translationQueueInFlight = false;
      _translationQueueRunning = false;
      _translationInsertRunning = false;
      setState(() {});
      _syncTranslationQueueStatus(provider);
    }
    if (enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final currentPage =
            _paragraphsByIndexForPageOffsetForTranslation(0, provider);
        if (currentPage.isNotEmpty) {
          provider.clearFailedForParagraphs(currentPage.values);
        }
        _translateCurrentPageIfNeeded(provider);
      });
    }
  }

  Future<void> _setAiReadAloudEnabled({
    required TranslationProvider provider,
    required bool enabled,
  }) async {
    if (!mounted) return;
    final rap = context.read<ReadAloudProvider>();

    try {
      await provider.setAiReadAloudEnabled(enabled);
    } catch (e) {
      if (!mounted) return;
      _showTopError(e.toString());
      return;
    }

    if (!enabled) {
      await rap.stop(keepResume: true);
      return;
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<List<ReaderParagraph>> _paragraphsForChapter(int chapterIndex) async {
    await _ensureChapterContentCached(chapterIndex);
    if (!mounted) return const [];
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) return const [];
    return _getParagraphsForChapter(chapterIndex, plainText);
  }

  Future<void> _startReadAloudFromSelection(String selectedText) async {
    if (!mounted) return;
    final tp = context.read<TranslationProvider>();
    final rap = context.read<ReadAloudProvider>();
    if (!tp.aiReadAloudEnabled) return;
    final Map<int, String> pageParas = _currentPageParagraphsByIndex();
    int? startParagraphIndex;
    final trimmed = selectedText.trim();
    if (trimmed.isNotEmpty && pageParas.isNotEmpty) {
      final entries = pageParas.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final e in entries) {
        final t = e.value;
        if (t.contains(trimmed) || trimmed.contains(t.trim())) {
          startParagraphIndex = e.key;
          break;
        }
      }
      startParagraphIndex ??= entries.first.key;
    }
    startParagraphIndex ??= 0;

    final chapterIndex = _currentChapterIndex;
    final paras = await _paragraphsForChapter(chapterIndex);
    if (!mounted) return;
    await rap.startOrResume(
      bookId: widget.bookId,
      chapterIndex: chapterIndex,
      paragraphs: paras,
      startParagraphIndex: startParagraphIndex,
    );
  }

  void _scheduleSyncToReadAloudPosition(ReadAloudPosition pos) {
    final key =
        '${pos.bookId}|${pos.chapterIndex}|${pos.paragraphIndex}|${pos.chunkIndexInParagraph}';
    if (key == _lastReadAloudSyncKey) return;
    if (_readAloudSyncScheduled) return;
    _readAloudSyncScheduled = true;
    _lastReadAloudSyncKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        _readAloudSyncScheduled = false;
        if (!mounted) return;
        final rap = context.read<ReadAloudProvider>();
        final latest = rap.position;
        if (latest == null) return;
        final latestKey =
            '${latest.bookId}|${latest.chapterIndex}|${latest.paragraphIndex}|${latest.chunkIndexInParagraph}';
        if (latestKey != key) return;
        if (latest.bookId != widget.bookId) return;

        final targetChapter = latest.chapterIndex;
        await _ensureChapterContentCached(targetChapter);
        if (!mounted) return;
        final plainText = _getPlainTextForChapter(targetChapter);
        if (plainText.isEmpty) return;
        final effectiveText = _chapterEffectiveText[targetChapter] ?? plainText;
        final ranges = _chapterPageRanges[targetChapter] ??
            _chapterFallbackPageRanges[targetChapter];
        if (ranges == null || ranges.isEmpty) return;
        final tp = context.read<TranslationProvider>();
        final int effectiveOffset = _effectiveOffsetForReadAloudPosition(
          chapterIndex: targetChapter,
          tp: tp,
          pos: latest,
          plainText: plainText,
          effectiveText: effectiveText,
        );

        int desiredPage = 0;
        int low = 0;
        int high = ranges.length - 1;
        int best = 0;
        while (low <= high) {
          final mid = (low + high) >> 1;
          final r = ranges[mid];
          if (effectiveOffset < r.start) {
            high = mid - 1;
          } else if (effectiveOffset >= r.end) {
            low = mid + 1;
            best = mid;
          } else {
            best = mid;
            break;
          }
        }
        desiredPage = best.clamp(0, ranges.length - 1);

        _readAloudFollowChapter ??= _currentChapterIndex;
        _readAloudFollowPage ??= _currentPageInChapter;

        if (targetChapter != _currentChapterIndex) {
          if (!_readAloudFollow) return;
          setState(() {
            _currentChapterIndex = targetChapter;
            _currentPageInChapter = desiredPage;
            _pageViewCenterIndex = 1000;
          });
          _readAloudFollowChapter = targetChapter;
          _readAloudFollowPage = desiredPage;
          if (_pageController.hasClients) _pageController.jumpToPage(1000);
          return;
        }

        final bool isOnDesired = _currentChapterIndex == targetChapter &&
            _currentPageInChapter == desiredPage;
        if (isOnDesired) {
          _readAloudFollow = true;
          _readAloudFollowChapter = targetChapter;
          _readAloudFollowPage = desiredPage;
          return;
        }

        final bool isOnFollowPage =
            _readAloudFollowChapter == _currentChapterIndex &&
                _readAloudFollowPage == _currentPageInChapter;
        if (_readAloudFollow && isOnFollowPage) {
          final beforePage = _currentPageInChapter;
          setState(() {
            _currentPageInChapter = desiredPage;
            _pageViewCenterIndex = 1000;
          });
          _readAloudFollowChapter = targetChapter;
          _readAloudFollowPage = desiredPage;
          if (_pageController.hasClients && beforePage != desiredPage) {
            _pageController.jumpToPage(1000);
          }
          return;
        }

        _readAloudFollow = false;
      }());
    });
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

  int? _paragraphIndexAtOffset({
    required String effectiveText,
    required int absoluteOffset,
  }) {
    final safeOffset = absoluteOffset.clamp(0, effectiveText.length);
    final matches = RegExp(r'\n{2,}').allMatches(effectiveText);
    int startPos = 0;
    int paraIndex = 0;
    for (final m in matches) {
      final endPos = m.start;
      final raw = effectiveText.substring(startPos, endPos);
      final cleaned = raw
          .replaceAll(RegExp(r'^\n+'), '')
          .replaceAll(RegExp(r'\n+$'), '')
          .replaceAll(RegExp(r'^[ \t\u3000]+'), '');
      if (cleaned.trim().isNotEmpty) {
        if (safeOffset <= endPos) return paraIndex;
        paraIndex++;
      }
      startPos = m.end;
    }
    if (startPos <= effectiveText.length) {
      final raw = effectiveText.substring(startPos);
      final cleaned = raw
          .replaceAll(RegExp(r'^\n+'), '')
          .replaceAll(RegExp(r'\n+$'), '')
          .replaceAll(RegExp(r'^[ \t\u3000]+'), '');
      if (cleaned.trim().isNotEmpty) {
        return paraIndex;
      }
    }
    return null;
  }

  Future<void> _openIllustrationFromSelection({
    required int chapterIndex,
    required String selectionText,
  }) async {
    _hideControls();
    final chapter = _chapters[chapterIndex];
    final chapterTitle = (chapter.title ?? '正文').trim();
    final chapterId = '${widget.bookId}::$chapterIndex';
    final plain = _getPlainTextForChapter(chapterIndex);

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final media = MediaQuery.of(context);
        final panelText = _panelTextColor;
        final panelBg = _panelBgColor;
        final aiModel = context.watch<AiModelProvider>();
        final usingPersonal = usingPersonalTencentKeys();
        return GlassPanel.sheet(
          surfaceColor: panelBg,
          opacity: AppTokens.glassOpacityDense,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height:
                  (media.size.height * 0.78).clamp(360.0, media.size.height),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.image_outlined,
                            color: AppColors.techBlue),
                        const SizedBox(width: 8),
                        Text(
                          '插图',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: panelText,
                          ),
                        ),
                        if (!usingPersonal)
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              '剩余积分：${aiModel.pointsBalance}（生图2万/张）',
                              style: TextStyle(
                                color: panelBg.computeLuminance() < 0.5
                                    ? const Color(0xFFE6A23C)
                                    : const Color(0xFFF57C00),
                                fontSize: 12,
                                height: 1.0,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(Icons.close,
                              color: panelText.withOpacityCompat(0.7)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: IllustrationPanel(
                        isDark: panelBg.computeLuminance() < 0.5,
                        bgColor: panelBg,
                        textColor: panelText,
                        bookId: widget.bookId,
                        chapterId: chapterId,
                        chapterTitle: chapterTitle,
                        chapterContent: plain,
                        initialSelectionText: selectionText,
                        autoGenerateFromSelection: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  int _effectiveOffsetForReadAloudPosition({
    required int chapterIndex,
    required TranslationProvider tp,
    required ReadAloudPosition pos,
    required String plainText,
    required String effectiveText,
  }) {
    if (!tp.applyToReader) {
      return pos.chapterTextOffset.clamp(0, plainText.length);
    }
    if (plainText.isEmpty || effectiveText.isEmpty) return 0;

    final paragraphs = _getParagraphsForChapter(chapterIndex, plainText);
    if (paragraphs.isEmpty) return 0;

    final bool isBilingual =
        tp.config.displayMode == TranslationDisplayMode.bilingual;
    final bool isTransOnly =
        tp.config.displayMode == TranslationDisplayMode.translationOnly;

    int cursor = 0;
    for (int i = 0; i < paragraphs.length; i++) {
      final p = paragraphs[i];
      final trans = tp.getCachedTranslation(p.text);
      final pending = tp.isTranslationPending(p.text);
      final failed = tp.isTranslationFailed(p.text);

      String render;
      if (trans != null && trans.isNotEmpty) {
        if (isTransOnly) {
          render = trans;
        } else {
          render = '${p.text}\n$trans';
        }
      } else if (pending) {
        if (isTransOnly || isBilingual) {
          render = '${p.text}\n翻译中...';
        } else {
          render = p.text;
        }
      } else if (failed) {
        if (isTransOnly || isBilingual) {
          render = '${p.text}\n翻译失败';
        } else {
          render = p.text;
        }
      } else {
        render = p.text;
      }

      final paraStart = cursor;
      if (p.index == pos.paragraphIndex) {
        int inside = 0;
        final h = pos.highlightText.trim();
        if (h.isNotEmpty) {
          final idx = render.indexOf(h);
          if (idx >= 0) {
            inside = idx;
          } else if (!isTransOnly) {
            inside = pos.highlightOffsetInParagraph.clamp(0, p.text.length);
          }
        } else if (!isTransOnly) {
          inside = pos.highlightOffsetInParagraph.clamp(0, p.text.length);
        }

        final out = (paraStart + inside).clamp(0, paraStart + render.length);
        return out.clamp(0, effectiveText.length);
      }

      cursor = paraStart + render.length;
      if (i < paragraphs.length - 1) {
        cursor += 2;
      }
      if (cursor >= effectiveText.length) break;
    }
    return pos.chapterTextOffset
        .clamp(0, plainText.isEmpty ? 0 : plainText.length);
  }

  void _scheduleUpdateReadAloudFollowFromCurrentView() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        if (!mounted) return;
        final tp = context.read<TranslationProvider>();
        final rap = context.read<ReadAloudProvider>();
        final pos = rap.position;
        if (pos == null || pos.bookId != widget.bookId) {
          _readAloudFollow = false;
          return;
        }
        final targetChapter = pos.chapterIndex;
        await _ensureChapterContentCached(targetChapter);
        if (!mounted) return;
        final plainText = _getPlainTextForChapter(targetChapter);
        if (plainText.isEmpty) return;
        final effectiveText = _chapterEffectiveText[targetChapter] ?? plainText;
        final ranges = _chapterPageRanges[targetChapter] ??
            _chapterFallbackPageRanges[targetChapter];
        if (ranges == null || ranges.isEmpty) return;

        final int effectiveOffset = _effectiveOffsetForReadAloudPosition(
          chapterIndex: targetChapter,
          tp: tp,
          pos: pos,
          plainText: plainText,
          effectiveText: effectiveText,
        );

        int desiredPage = 0;
        int low = 0;
        int high = ranges.length - 1;
        int best = 0;
        while (low <= high) {
          final mid = (low + high) >> 1;
          final r = ranges[mid];
          if (effectiveOffset < r.start) {
            high = mid - 1;
          } else if (effectiveOffset >= r.end) {
            low = mid + 1;
            best = mid;
          } else {
            best = mid;
            break;
          }
        }
        desiredPage = best.clamp(0, ranges.length - 1);

        final isOnDesired = _currentChapterIndex == targetChapter &&
            _currentPageInChapter == desiredPage;
        _readAloudFollow = isOnDesired;
        if (isOnDesired) {
          _readAloudFollowChapter = targetChapter;
          _readAloudFollowPage = desiredPage;
        }
      }());
    });
  }

  void _maybeAutoContinueToNextChapter(
    ReadAloudProvider rap,
    ReadAloudPosition pos,
  ) {
    if (!rap.endedNaturally) return;
    final key =
        '${pos.bookId}|${pos.chapterIndex}|${pos.paragraphIndex}|${pos.chunkIndexInParagraph}';
    if (_readAloudAutoContinueHandledKey == key) return;
    _readAloudAutoContinueHandledKey = key;

    final nextChapter = pos.chapterIndex + 1;
    if (nextChapter < 0 || nextChapter >= _chapters.length) return;

    if (_readAloudFollow) {
      final isOnFollowPage = _readAloudFollowChapter == _currentChapterIndex &&
          _readAloudFollowPage == _currentPageInChapter;
      if (isOnFollowPage) {
        setState(() {
          _currentChapterIndex = nextChapter;
          _currentPageInChapter = 0;
          _pageViewCenterIndex = 1000;
        });
        _readAloudFollowChapter = nextChapter;
        _readAloudFollowPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(1000);
      }
    }

    unawaited(() async {
      final tp = context.read<TranslationProvider>();
      final paras = await _paragraphsForChapter(nextChapter);
      if (!mounted) return;
      if (paras.isEmpty) return;
      await _prefetchChapterTranslations(
        tp: tp,
        chapterIndex: nextChapter,
        paragraphs: paras,
        purpose: 'read_aloud_enter',
        waitForCache: true,
      );
      await rap.startOrResume(
        bookId: widget.bookId,
        chapterIndex: nextChapter,
        paragraphs: paras,
        startParagraphIndex: 0,
      );
    }());
  }

  final Map<String, String> _chapterPrefetchKeys = {};

  int _nextChapterPrefetchCount(TranslationProvider tp) {
    if (tp.translationMode == TranslationMode.bigModel) return 3;
    return 8;
  }

  void _scheduleChapterTranslationPrefetch({
    required TranslationProvider tp,
    required int chapterIndex,
    required String purpose,
  }) {
    if (!tp.applyToReader) return;
    if (tp.config.displayMode != TranslationDisplayMode.bilingual &&
        tp.config.displayMode != TranslationDisplayMode.translationOnly) {
      return;
    }
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return;
    unawaited(() async {
      final paras = await _paragraphsForChapter(chapterIndex);
      if (!mounted) return;
      if (paras.isEmpty) return;
      await _prefetchChapterTranslations(
        tp: tp,
        chapterIndex: chapterIndex,
        paragraphs: paras,
        purpose: purpose,
        waitForCache: false,
      );
    }());
  }

  Future<void> _prefetchChapterTranslations({
    required TranslationProvider tp,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
    required String purpose,
    bool waitForCache = false,
  }) async {
    if (!tp.applyToReader) return;
    if (tp.config.displayMode != TranslationDisplayMode.bilingual &&
        tp.config.displayMode != TranslationDisplayMode.translationOnly) {
      return;
    }
    if (paragraphs.isEmpty) return;

    final key =
        '$purpose|${widget.bookId}|$chapterIndex|${tp.config.displayMode.name}|${tp.translationMode.name}|${tp.config.sourceLang}|${tp.config.targetLang}';
    final alreadyPrefetched = _chapterPrefetchKeys[purpose] == key;
    if (!alreadyPrefetched) _chapterPrefetchKeys[purpose] = key;

    final maxCount = _nextChapterPrefetchCount(tp);
    final takeCount =
        paragraphs.length < maxCount ? paragraphs.length : maxCount;
    final texts = <String>[];
    for (int i = 0; i < takeCount; i++) {
      final t = paragraphs[i].text.trim();
      if (t.isNotEmpty) texts.add(t);
    }
    if (texts.isEmpty) return;

    if (!alreadyPrefetched) {
      tp.prefetchParagraphs(texts);
    }

    if (!waitForCache) return;

    // Best-effort: wait a short time so ReadAloud queue can include translations
    // when entering a new chapter.
    final deadline = DateTime.now().add(const Duration(milliseconds: 1200));
    while (DateTime.now().isBefore(deadline)) {
      bool anyReady = false;
      for (final t in texts.take(3)) {
        final cached = tp.getCachedTranslation(t);
        if (cached != null && cached.trim().isNotEmpty) {
          anyReady = true;
          break;
        }
      }
      if (anyReady) return;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> _handleReadAloudBackTap() async {
    if (_readAloudNavInFlight) return;
    _readAloudNavInFlight = true;
    try {
      final rap = context.read<ReadAloudProvider>();
      if (rap.bookId != widget.bookId || !rap.isActiveForBook) {
        final tp = context.read<TranslationProvider>();
        final chapterIndex = _currentChapterIndex;
        final paras = await _paragraphsForChapter(chapterIndex);
        if (!mounted) return;
        if (paras.isNotEmpty) {
          int startPara = 0;
          final visibleMap =
              _paragraphsByIndexForPageOffsetForTranslation(0, tp);
          if (visibleMap.isNotEmpty) {
            final sortedKeys = visibleMap.keys.toList()..sort();
            startPara = sortedKeys.first;
          }
          await rap.prepare(
            bookId: widget.bookId,
            chapterIndex: chapterIndex,
            paragraphs: paras,
            startParagraphIndex: startPara,
          );
        }
      }
      if (rap.bookId != widget.bookId) return;
      final keepPaused = rap.paused && !rap.playing && !rap.preparing;
      final moved = await rap.stepToPreviousChunk(keepPaused: keepPaused);
      if (moved) {
        final pos = rap.position;
        if (pos != null && pos.bookId == widget.bookId) {
          _readAloudFollow = true;
          _readAloudFollowChapter = _currentChapterIndex;
          _readAloudFollowPage = _currentPageInChapter;
          _scheduleSyncToReadAloudPosition(pos);
        }
        return;
      }
      final pos = rap.position;
      if (pos == null || pos.bookId != widget.bookId) return;
      final prevChapter = pos.chapterIndex - 1;
      if (prevChapter < 0) return;
      final tp = context.read<TranslationProvider>();
      final paras = await _paragraphsForChapter(prevChapter);
      if (!mounted) return;
      if (paras.isEmpty) return;
      _readAloudFollow = true;
      await _prefetchChapterTranslations(
        tp: tp,
        chapterIndex: prevChapter,
        paragraphs: paras,
        purpose: 'read_aloud_enter',
        waitForCache: true,
      );
      await _ensureChapterContentCached(prevChapter);
      if (!mounted) return;
      final ranges = _chapterPageRanges[prevChapter] ??
          _chapterFallbackPageRanges[prevChapter];
      final desiredPage =
          (ranges == null || ranges.isEmpty) ? 0 : ranges.length - 1;
      setState(() {
        _currentChapterIndex = prevChapter;
        _currentPageInChapter = desiredPage;
        _pageViewCenterIndex = 1000;
      });
      _readAloudFollowChapter = prevChapter;
      _readAloudFollowPage = desiredPage;
      if (_pageController.hasClients) _pageController.jumpToPage(1000);
      await rap.seekToChapterEnd(
        bookId: widget.bookId,
        chapterIndex: prevChapter,
        paragraphs: paras,
        keepPaused: keepPaused,
      );
    } finally {
      _readAloudNavInFlight = false;
    }
  }

  Future<void> _handleReadAloudForwardTap() async {
    if (_readAloudNavInFlight) return;
    _readAloudNavInFlight = true;
    try {
      final rap = context.read<ReadAloudProvider>();
      if (rap.bookId != widget.bookId || !rap.isActiveForBook) {
        final tp = context.read<TranslationProvider>();
        final chapterIndex = _currentChapterIndex;
        final paras = await _paragraphsForChapter(chapterIndex);
        if (!mounted) return;
        if (paras.isNotEmpty) {
          int startPara = 0;
          final visibleMap =
              _paragraphsByIndexForPageOffsetForTranslation(0, tp);
          if (visibleMap.isNotEmpty) {
            final sortedKeys = visibleMap.keys.toList()..sort();
            startPara = sortedKeys.first;
          }
          await rap.prepare(
            bookId: widget.bookId,
            chapterIndex: chapterIndex,
            paragraphs: paras,
            startParagraphIndex: startPara,
          );
        }
      }
      if (rap.bookId != widget.bookId) return;
      final keepPaused = rap.paused && !rap.playing && !rap.preparing;
      final moved = await rap.stepToNextChunk(keepPaused: keepPaused);
      if (moved) {
        final pos = rap.position;
        if (pos != null && pos.bookId == widget.bookId) {
          _readAloudFollow = true;
          _readAloudFollowChapter = _currentChapterIndex;
          _readAloudFollowPage = _currentPageInChapter;
          _scheduleSyncToReadAloudPosition(pos);
        }
        return;
      }
      final pos = rap.position;
      if (pos == null || pos.bookId != widget.bookId) return;
      final nextChapter = pos.chapterIndex + 1;
      if (nextChapter >= _chapters.length) return;
      final tp = context.read<TranslationProvider>();
      final paras = await _paragraphsForChapter(nextChapter);
      if (!mounted) return;
      if (paras.isEmpty) return;
      _readAloudFollow = true;
      await _prefetchChapterTranslations(
        tp: tp,
        chapterIndex: nextChapter,
        paragraphs: paras,
        purpose: 'read_aloud_enter',
        waitForCache: true,
      );
      setState(() {
        _currentChapterIndex = nextChapter;
        _currentPageInChapter = 0;
        _pageViewCenterIndex = 1000;
      });
      _readAloudFollowChapter = nextChapter;
      _readAloudFollowPage = 0;
      if (_pageController.hasClients) _pageController.jumpToPage(1000);
      await rap.seekToChapterStart(
        bookId: widget.bookId,
        chapterIndex: nextChapter,
        paragraphs: paras,
        keepPaused: keepPaused,
      );
    } finally {
      _readAloudNavInFlight = false;
    }
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

  void _refreshReadAloudQueueIfNeeded(TranslationProvider tp) {
    if (!_aiReadAloudPlaying) return;
    if (!tp.readTranslationEnabled) return;
    final rev = tp.cacheRevision;
    if (_readAloudTranslationRevision == rev) return;
    _readAloudTranslationRevision = rev;
    if (_readAloudQueue.isEmpty) return;
    int? currentParagraphIndex;
    if (_readAloudQueuePos >= 0 &&
        _readAloudQueuePos < _readAloudQueue.length) {
      currentParagraphIndex =
          _readAloudQueue[_readAloudQueuePos].paragraphIndex;
    }
    final queue = _buildReadAloudQueue();
    if (queue.isEmpty) return;
    int pos = 0;
    if (currentParagraphIndex != null) {
      final idx = queue
          .lastIndexWhere((e) => e.paragraphIndex == currentParagraphIndex);
      if (idx >= 0) pos = idx;
    }
    _readAloudQueue = queue;
    _readAloudQueuePos = pos;
    _readAloudResumeParagraphIndex = currentParagraphIndex;
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

    // Split by punctuation first (sentence/phrase level)
    final sentenceRegex = RegExp(r'[^。！？；，.!?;,]+[。！？；，.!?;,]*\s*');
    final parts = sentenceRegex
        .allMatches(base)
        .map((m) => m.group(0) ?? '')
        .where((e) => e.trim().isNotEmpty)
        .toList();

    if (parts.isEmpty) {
      return [
        _TtsSegment(
          speech: _normalizeSpeechText(base),
          highlight: base,
        ),
      ];
    }

    // Accumulate parts into chunks up to 120 characters
    final out = <_TtsSegment>[];
    final buffer = StringBuffer();
    int currentLen = 0;
    const int maxLen = 120;

    for (final part in parts) {
      final partLen = _ttsUnitCount(part);

      // If adding this part exceeds the limit and we have something in buffer, flush first
      if (buffer.isNotEmpty && (currentLen + partLen > maxLen)) {
        final combined = buffer.toString();
        out.add(_TtsSegment(
          speech: _normalizeSpeechText(combined),
          highlight: combined.trim(),
        ));
        buffer.clear();
        currentLen = 0;
      }

      buffer.write(part);
      currentLen += partLen;
    }

    // Flush remaining
    if (buffer.isNotEmpty) {
      final combined = buffer.toString();
      out.add(_TtsSegment(
        speech: _normalizeSpeechText(combined),
        highlight: combined.trim(),
      ));
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
      await _cleanupReadAloudTempFile();
      if (kIsWeb) {
        await _readAloudPlayer.play(BytesSource(bytes));
      } else {
        final dir = await getTemporaryDirectory();
        final file = File(
            '${dir.path}/tts_${session}_${DateTime.now().microsecondsSinceEpoch}.mp3');
        await file.writeAsBytes(bytes, flush: true);
        _readAloudTempFilePath = file.path;
        await _readAloudPlayer.play(DeviceFileSource(file.path));
      }
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
          rate: cfg.localTtsSpeed,
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
          'rate': cfg.localTtsSpeed,
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

    // Ensure plain pagination is ready if needed
    if (cfg.applyToReader) {
      var ranges = _chapterPlainPageRanges[_currentChapterIndex];
      if (ranges == null || ranges.isEmpty) {
        if (_lastPaginationViewportHeight != null &&
            _lastPaginationContentWidth != null) {
          _schedulePlainPaginationForChapter(
            chapterIndex: _currentChapterIndex,
            viewportHeight: _lastPaginationViewportHeight!,
            contentWidth: _lastPaginationContentWidth!,
          );
        }

        final task = _chapterPlainPaginationTasks[_currentChapterIndex];
        if (task != null) {
          setState(() {
            _aiReadAloudPreparing = true;
          });
          try {
            await task;
          } catch (_) {}
          if (!mounted) return false;
          // If stopped by user during wait
          if (!_aiReadAloudPreparing) return false;
        }
      }
    }

    final queue = _buildReadAloudQueue();
    if (queue.isEmpty) {
      if (_aiReadAloudPreparing) {
        setState(() {
          _aiReadAloudPreparing = false;
        });
      }
      return false;
    }

    int pos = 0;
    final resume = _readAloudResumeParagraphIndex;
    if (resume != null) {
      final idx = queue.indexWhere((e) => e.key == resume);
      if (idx >= 0) pos = idx;
    }

    final session = ++_readAloudSession;
    _readAloudQueue = queue;
    _readAloudQueuePos = pos;
    _readAloudTranslationRevision = cfg.cacheRevision;

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
    _readAloudTranslationRevision = -1;
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
    await _cleanupReadAloudTempFile();
    if (!mounted) return;
    setState(() {
      _aiReadAloudPlaying = false;
      _aiReadAloudPreparing = false;
    });
  }

  Future<void> _cleanupReadAloudTempFile() async {
    final path = _readAloudTempFilePath;
    if (path == null || path.isEmpty) return;
    _readAloudTempFilePath = null;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  void _onReadAloudPlayerComplete() {
    if (!mounted) return;
    final cfg = context.read<TranslationProvider>();
    if (!_aiReadAloudPlaying) return;
    if (cfg.readAloudEngine != ReadAloudEngine.online) return;

    final session = _readAloudSession;
    _refreshReadAloudQueueIfNeeded(cfg);
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
    _refreshReadAloudQueueIfNeeded(cfg);
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

    final cfg = context.read<TranslationProvider>();
    _readAloudQueue = queue;
    _readAloudQueuePos = 0;
    _readAloudResumeParagraphIndex = null;
    _readAloudTranslationRevision = cfg.cacheRevision;
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
    _showCenterToast(text);
  }

  Widget _buildReadAloudFloatingButton() {
    if (_isLoading || _error != null) return const SizedBox.shrink();
    final tp = context.watch<TranslationProvider>();
    if (!tp.aiReadAloudEnabled) {
      return const SizedBox.shrink();
    }
    final readAloud = context.watch<ReadAloudProvider>();
    final bool hasChapters = _chapters.isNotEmpty;
    final visibleParas = _paragraphsByIndexForPageOffsetForTranslation(0, tp);
    int? firstVisibleParaIndex;
    int? lastVisibleParaIndex;
    if (visibleParas.isNotEmpty) {
      final keys = visibleParas.keys.toList()..sort();
      firstVisibleParaIndex = keys.first;
      lastVisibleParaIndex = keys.last;
    }
    int? lastParaIndexInChapter;
    final currentPlainText = _getPlainTextForChapter(_currentChapterIndex);
    if (currentPlainText.isNotEmpty) {
      final paras =
          _getParagraphsForChapter(_currentChapterIndex, currentPlainText);
      if (paras.isNotEmpty) {
        lastParaIndexInChapter = paras.length - 1;
      }
    }

    final rapActiveThisBook =
        readAloud.bookId == widget.bookId && readAloud.isActiveForBook;
    final rapPos = rapActiveThisBook ? readAloud.position : null;
    final bool atBookStart = rapPos != null
        ? (rapPos.chapterIndex <= 0 && readAloud.atQueueStart)
        : (hasChapters &&
            _currentChapterIndex <= 0 &&
            (firstVisibleParaIndex ?? 1) <= 0);
    final bool atBookEnd = rapPos != null
        ? (hasChapters &&
            rapPos.chapterIndex >= _chapters.length - 1 &&
            readAloud.atQueueEnd)
        : (hasChapters &&
            _currentChapterIndex >= _chapters.length - 1 &&
            lastParaIndexInChapter != null &&
            (lastVisibleParaIndex ?? -1) >= lastParaIndexInChapter);

    final Color surface = _panelBgColor;
    final Color onSurface = _panelTextColor;

    final mq = MediaQuery.of(context);
    final size = mq.size;
    const marginX = 0.0;
    const marginY = 12.0;
    final storedBottomInset = _contentBottomInset ?? 0.0;
    final bottomInset = storedBottomInset > mq.viewPadding.bottom
        ? storedBottomInset
        : mq.viewPadding.bottom;
    final topInset = mq.viewPadding.top;

    final bool collapsed = _readAloudFabCollapsed;
    if (!collapsed) {
      _armFloatingUiAutoHideIfNeeded();
    }
    final double capsuleW = _readAloudFabWidth(collapsed);
    const double capsuleH = _kFloatingCapsuleHeight;

    final defaultX = size.width - marginX - capsuleW;
    final defaultY = size.height - bottomInset - 120 - capsuleH;
    final current = _readAloudFabOffset ?? Offset(defaultX, defaultY);

    final maxX = size.width - marginX - capsuleW;
    final maxY = size.height - bottomInset - 80 - capsuleH;
    final clamped = Offset(
      current.dx.clamp(marginX, maxX),
      current.dy.clamp(topInset + marginY, maxY),
    );

    final isDarkBg = _bgColor.computeLuminance() < 0.5;
    final shadow = <BoxShadow>[
      BoxShadow(
        color: Colors.black.withOpacityCompat(isDarkBg ? 0.55 : 0.22),
        blurRadius: 18,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: Colors.white.withOpacityCompat(isDarkBg ? 0.06 : 0.75),
        blurRadius: 10,
        offset: const Offset(0, -4),
      ),
    ];

    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: GestureDetector(
        onPanStart: (_) => _touchFloatingUi(),
        onPanUpdate: (details) {
          final base = _readAloudFabOffset ?? Offset(defaultX, defaultY);
          final next = base + details.delta;
          final nextClamped = Offset(
            next.dx.clamp(marginX, maxX),
            next.dy.clamp(topInset + marginY, maxY),
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
            child: GlassPanel(
              borderRadius: BorderRadius.circular(999),
              surfaceColor: surface,
              opacity: 0.92,
              blurSigma: 14,
              border: Border.all(
                color: onSurface.withOpacityCompat(0.08),
                width: AppTokens.stroke,
              ),
              child: SizedBox(
                width: capsuleW,
                height: capsuleH,
                child: Row(
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: collapsed
                            ? const SizedBox.shrink()
                            : Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _readAloudCapsuleButton(
                                        icon: Icons.replay_rounded,
                                        spinTurns: _readAloudBackSpinTurns,
                                        enabled: tp.aiReadAloudEnabled &&
                                            !atBookStart,
                                        onTap: () {
                                          _touchFloatingUi();
                                          setState(() =>
                                              _readAloudBackSpinTurns -= 1.0);
                                          unawaited(_handleReadAloudBackTap());
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      _readAloudCapsuleButton(
                                        icon: Icons.volume_up_rounded,
                                        highlight: readAloud.playing ||
                                            readAloud.preparing,
                                        enabled: true,
                                        showProgress: readAloud.preparing,
                                        onTap: () {
                                          _touchFloatingUi();
                                          if (readAloud.bookId ==
                                                  widget.bookId &&
                                              (readAloud.playing ||
                                                  readAloud.preparing)) {
                                            unawaited(readAloud.pause());
                                            return;
                                          }
                                          if (readAloud.bookId ==
                                                  widget.bookId &&
                                              readAloud.paused) {
                                            unawaited(readAloud.resume());
                                            return;
                                          }
                                          unawaited(() async {
                                            final tp = context
                                                .read<TranslationProvider>();
                                            final rap = context
                                                .read<ReadAloudProvider>();
                                            if (!tp.aiReadAloudEnabled) return;
                                            final resume = rap.position;
                                            int targetChapter =
                                                _currentChapterIndex;
                                            int? startPara;

                                            if (resume != null &&
                                                resume.bookId ==
                                                    widget.bookId) {
                                              targetChapter =
                                                  resume.chapterIndex;
                                            } else {
                                              final visibleMap =
                                                  _paragraphsByIndexForPageOffsetForTranslation(
                                                      0, tp);
                                              if (visibleMap.isNotEmpty) {
                                                final sortedKeys =
                                                    visibleMap.keys.toList()
                                                      ..sort();
                                                startPara = sortedKeys.first;
                                              }
                                            }

                                            final paras =
                                                await _paragraphsForChapter(
                                                    targetChapter);
                                            if (!mounted) return;
                                            await rap.startOrResume(
                                              bookId: widget.bookId,
                                              chapterIndex: targetChapter,
                                              paragraphs: paras,
                                              startParagraphIndex: startPara,
                                            );
                                          }());
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      _readAloudCapsuleButton(
                                        icon: Icons.replay_rounded,
                                        spinTurns: _readAloudForwardSpinTurns,
                                        mirrorX: true,
                                        enabled:
                                            tp.aiReadAloudEnabled && !atBookEnd,
                                        onTap: () {
                                          _touchFloatingUi();
                                          setState(() =>
                                              _readAloudForwardSpinTurns +=
                                                  1.0);
                                          unawaited(
                                              _handleReadAloudForwardTap());
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                    SizedBox(
                      width: _kFloatingHandleWidth,
                      height: capsuleH,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () {
                            _touchFloatingUi();
                            _setReadAloudFabCollapsed(!collapsed);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: onSurface.withOpacityCompat(0.05),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Center(
                              child: Icon(
                                collapsed
                                    ? Icons.chevron_left_rounded
                                    : Icons.chevron_right_rounded,
                                size: 22,
                                color: AppColors.techBlue,
                              ),
                            ),
                          ),
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
    );
  }

  Widget _buildIllustrationFloatingButton() {
    if (_isLoading || _error != null) return const SizedBox.shrink();
    final aiModel = context.watch<AiModelProvider>();
    if (!aiModel.illustrationEnabled) return const SizedBox.shrink();
    if (aiModel.source != AiModelSource.online) return const SizedBox.shrink();

    final illuProvider = context.watch<IllustrationProvider>();
    final String chapterId = '${widget.bookId}::$_currentChapterIndex';
    final bool analyzing = illuProvider.isAnalyzing(chapterId);
    final bool analyzingOrQueued = illuProvider.isAnalyzingOrQueued(chapterId);

    final tp = context.read<TranslationProvider>();
    final usingPersonal = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;
    final bool canUseOnline = usingPersonal || aiModel.pointsBalance > 0;
    final bool canAnalyze = !analyzingOrQueued &&
        (aiModel.illustrationForceLocalAnalyze
            ? aiModel.localModelReadyForIllustrationAnalysis
            : canUseOnline);

    final Color surface = _panelBgColor;
    final Color onSurface = _panelTextColor;

    final mq = MediaQuery.of(context);
    final size = mq.size;
    const marginX = 0.0;
    const marginY = 12.0;
    final storedBottomInset = _contentBottomInset ?? 0.0;
    final bottomInset = storedBottomInset > mq.viewPadding.bottom
        ? storedBottomInset
        : mq.viewPadding.bottom;
    final topInset = mq.viewPadding.top;

    final bool collapsed = _illustrationFabCollapsed;
    if (!collapsed) {
      _armFloatingUiAutoHideIfNeeded();
    }
    final double capsuleW = _illustrationFabWidth(collapsed);
    const double capsuleH = _kFloatingCapsuleHeight;

    final defaultX = size.width - marginX - capsuleW;
    final defaultY = size.height - bottomInset - 120 - capsuleH - 64;
    final current = _illustrationFabOffset ?? Offset(defaultX, defaultY);

    final maxX = size.width - marginX - capsuleW;
    final maxY = size.height - bottomInset - 80 - capsuleH;
    final clamped = Offset(
      current.dx.clamp(marginX, maxX),
      current.dy.clamp(topInset + marginY, maxY),
    );

    final isDarkBg = _bgColor.computeLuminance() < 0.5;
    final shadow = <BoxShadow>[
      BoxShadow(
        color: Colors.black.withOpacityCompat(isDarkBg ? 0.55 : 0.22),
        blurRadius: 18,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: Colors.white.withOpacityCompat(isDarkBg ? 0.06 : 0.75),
        blurRadius: 10,
        offset: const Offset(0, -4),
      ),
    ];

    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: GestureDetector(
        onPanStart: (_) => _touchFloatingUi(),
        onPanUpdate: (details) {
          final base = _illustrationFabOffset ?? Offset(defaultX, defaultY);
          final next = base + details.delta;
          final nextClamped = Offset(
            next.dx.clamp(marginX, maxX),
            next.dy.clamp(topInset + marginY, maxY),
          );
          setState(() => _illustrationFabOffset = nextClamped);
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: shadow,
          ),
          child: GlassPanel(
            borderRadius: BorderRadius.circular(999),
            surfaceColor: surface,
            opacity: 0.92,
            blurSigma: 14,
            border: Border.all(
              color: onSurface.withOpacityCompat(0.08),
              width: AppTokens.stroke,
            ),
            child: SizedBox(
              width: capsuleW,
              height: capsuleH,
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: collapsed
                          ? const SizedBox.shrink()
                          : Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _readAloudCapsuleButton(
                                      icon: Icons.auto_awesome_rounded,
                                      enabled: canAnalyze,
                                      showProgress: analyzing,
                                      highlight: analyzingOrQueued,
                                      onTap: () {
                                        _touchFloatingUi();
                                        unawaited(() async {
                                          final provider = context
                                              .read<IllustrationProvider>();
                                          final ai =
                                              context.read<AiModelProvider>();
                                          final chapterIndex =
                                              _currentChapterIndex;
                                          final chapter =
                                              _chapters[chapterIndex];
                                          final chapterTitle =
                                              (chapter.title ?? '正文').trim();
                                          final plain = _getPlainTextForChapter(
                                              chapterIndex);
                                          if (plain.trim().isEmpty) {
                                            unawaited(
                                                _ensureChapterContentCached(
                                                    chapterIndex));
                                            _showTopError('章节内容为空');
                                            return;
                                          }

                                          Future<String> Function(
                                              String prompt)? run;
                                          if (ai
                                              .illustrationForceLocalAnalyze) {
                                            if (!ai
                                                .localModelReadyForIllustrationAnalysis) {
                                              _showTopError('本地模型未就绪，需下载模型');
                                              return;
                                            }
                                            run = (prompt) => ai.generate(
                                                  prompt: prompt,
                                                  maxTokens: 1024,
                                                  temperature: 0.2,
                                                );
                                          }

                                          final chapterId =
                                              '${widget.bookId}::$chapterIndex';
                                          provider.clearChapter(chapterId);
                                          _illustrationAutoAnalyzeRequested
                                              .remove(chapterIndex);
                                          try {
                                            await provider.analyzeChapter(
                                              chapterId: chapterId,
                                              chapterTitle: chapterTitle.isEmpty
                                                  ? '正文'
                                                  : chapterTitle,
                                              content: plain,
                                              maxScenes:
                                                  ai.maxIllustrationsPerChapter,
                                              force: true,
                                              pointsBalance: ai.pointsBalance,
                                              generateText: run,
                                            );
                                          } catch (e) {
                                            _showTopError(e.toString());
                                          }
                                        }());
                                      },
                                    ),
                                    const SizedBox(width: 6),
                                    _readAloudCapsuleButton(
                                      icon: Icons.collections_outlined,
                                      enabled: true,
                                      onTap: () {
                                        _touchFloatingUi();
                                        unawaited(
                                          _openIllustrationPanelForChapter(
                                            chapterIndex: _currentChapterIndex,
                                            onlySceneId: null,
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                  SizedBox(
                    width: _kFloatingHandleWidth,
                    height: capsuleH,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          _touchFloatingUi();
                          _setIllustrationFabCollapsed(!collapsed);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: onSurface.withOpacityCompat(0.05),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Center(
                            child: Icon(
                              collapsed
                                  ? Icons.chevron_left_rounded
                                  : Icons.chevron_right_rounded,
                              size: 22,
                              color: AppColors.techBlue,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _readAloudCapsuleButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    double spinTurns = 0.0,
    bool highlight = false,
    bool showProgress = false,
    bool mirrorX = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = highlight
        ? AppColors.techBlue
        : cs.onSurface.withOpacityCompat(enabled ? 0.70 : 0.28);
    final Color bg = cs.surface.withOpacityCompat(isDark ? 0.40 : 0.65);
    Widget baseIcon = Icon(icon, color: fg, size: 22);
    if (mirrorX) {
      baseIcon = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: baseIcon,
      );
    }
    baseIcon = AnimatedRotation(
      turns: spinTurns,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      child: baseIcon,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        splashColor: AppColors.techBlue.withOpacityCompat(0.14),
        highlightColor: AppColors.techBlue.withOpacityCompat(0.08),
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onTap();
              }
            : null,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: cs.onSurface.withOpacityCompat(isDark ? 0.10 : 0.08),
              width: AppTokens.stroke,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              baseIcon,
              if (showProgress)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppColors.techBlue.withOpacityCompat(0.65),
                    ),
                    backgroundColor: cs.onSurface.withOpacityCompat(0.08),
                  ),
                ),
            ],
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

    text = text.replaceAll('&nbsp;', ' ');
    text = text.replaceAll('&#160;', ' ');
    text = text.replaceAll('&#xA0;', ' ');
    text = text.replaceAll('&ensp;', ' ');
    text = text.replaceAll('&emsp;', ' ');
    text = text.replaceAll('&#12288;', ' ');
    text = text.replaceAll('&#x3000;', ' ');

    text = text.replaceAll(RegExp(r'\r\n?'), '\n');
    text = text.replaceAll(String.fromCharCode(0x00A0), ' ');
    text = text.replaceAll(String.fromCharCode(0x3000), ' ');
    text = text.replaceAll(String.fromCharCode(0xFEFF), ' ');
    text = text.replaceAll(String.fromCharCode(0x200B), '');
    text = text.replaceAll(RegExp(r'[\u2000-\u200A\u202F\u205F]'), ' ');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r' *\n *'), '\n');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.trim();

    final parts = text.split(RegExp(r'\n+'));
    final paragraphs = <String>[];
    for (int i = 0; i < parts.length; i++) {
      final raw = parts[i].trim();
      if (raw.isEmpty) continue;
      paragraphs.add(raw.replaceAll(RegExp(r'\s+'), ' '));
    }

    final buffer = StringBuffer();
    int titleLength = 0;
    bool firstWritten = false;
    final chapterTitle = _chapters[chapterIndex].title;
    final String? normalizedTitle =
        (chapterTitle != null && chapterTitle.trim().isNotEmpty)
            ? chapterTitle.trim().replaceAll(RegExp(r'\s+'), ' ')
            : null;

    int skipPrefix = 0;
    String? detectedTitle;
    if (paragraphs.isNotEmpty) {
      String joinPrefix(int k) =>
          paragraphs.take(k).join().replaceAll(RegExp(r'\s+'), '');

      int findPrefixMatch(String target) {
        final t = target.replaceAll(RegExp(r'\s+'), '');
        final maxK = paragraphs.length < 8 ? paragraphs.length : 8;
        for (int k = 2; k <= maxK; k++) {
          bool ok = true;
          for (int i = 0; i < k; i++) {
            if (paragraphs[i].length > 2) {
              ok = false;
              break;
            }
          }
          if (!ok) continue;
          if (joinPrefix(k) == t) return k;
        }
        return 0;
      }

      if (normalizedTitle != null) {
        final k = findPrefixMatch(normalizedTitle);
        if (k > 0) {
          detectedTitle = normalizedTitle;
          skipPrefix = k;
        }
      } else {
        const commonHeadings = <String>[
          '简介',
          '前言',
          '序言',
          '引子',
          '楔子',
          '后记',
          '致谢',
          '目录',
          'contents',
          'tableofcontents',
          'introduction',
          'preface',
        ];
        final lowerJoined = joinPrefix(8).toLowerCase();
        for (final h in commonHeadings) {
          final target = h.replaceAll(' ', '');
          final k = findPrefixMatch(target);
          if (k > 0) {
            detectedTitle = h == target ? h : target;
            skipPrefix = k;
            break;
          }
          if (lowerJoined.startsWith(target.toLowerCase())) {
            final maxK = paragraphs.length < 8 ? paragraphs.length : 8;
            for (int k2 = 2; k2 <= maxK; k2++) {
              if (joinPrefix(k2).toLowerCase() == target.toLowerCase()) {
                detectedTitle = h;
                skipPrefix = k2;
                break;
              }
            }
            if (skipPrefix > 0) break;
          }
        }
      }
    }

    if (detectedTitle != null && detectedTitle.trim().isNotEmpty) {
      buffer.write(detectedTitle);
      titleLength = detectedTitle.length;
      firstWritten = true;
    }

    for (int i = skipPrefix; i < paragraphs.length; i++) {
      final normalizedRaw = paragraphs[i];

      if (normalizedTitle != null && normalizedRaw == normalizedTitle) {
        if (!firstWritten) {
          buffer.write(normalizedRaw);
          titleLength = normalizedRaw.length;
          firstWritten = true;
        }
        continue;
      }

      if (firstWritten) {
        buffer.write('\n\n');
      } else if (normalizedTitle != null) {
        buffer.write(normalizedTitle);
        buffer.write('\n\n');
      }
      buffer.write(normalizedRaw);
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
      const String indent = '';

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
    String? highlightText,
  }) {
    const marker = '翻译中...';
    const int markerLen = marker.length;
    const paraSep = '\n\n';

    final List<InlineSpan> children = [];

    highlightText ??= _readAloudHighlightText;
    int hiStart = -1;
    int hiEnd = -1;
    if (highlightText != null && highlightText.trim().isNotEmpty) {
      hiStart = text.indexOf(highlightText);
      if (hiStart >= 0) {
        hiEnd = hiStart + highlightText.length;
      } else {
        // Handle partial overlap for cross-page highlighting
        // We compare trimmed versions to ignore surrounding whitespace differences
        final trimmedTextRight = text.trimRight();
        final trimmedTextLeft = text.trimLeft();
        final int leftTrimLen = text.length - trimmedTextLeft.length;

        int maxLen = text.length < highlightText.length
            ? text.length
            : highlightText.length;

        // 1. Text ends with start of highlightText (Page 1 case)
        for (int len = maxLen; len >= 1; len--) {
          final sub = highlightText.substring(0, len);
          // Check if trimmed page text ends with the start of highlight text
          if (trimmedTextRight.endsWith(sub)) {
            hiStart = trimmedTextRight.length - len;
            hiEnd = trimmedTextRight.length;
            break;
          }
        }

        // 2. Text starts with end of highlightText (Page 2 case)
        if (hiStart < 0) {
          for (int len = maxLen; len >= 1; len--) {
            final sub = highlightText.substring(highlightText.length - len);
            // Check if trimmed page text starts with the end of highlight text
            if (trimmedTextLeft.startsWith(sub)) {
              hiStart = leftTrimLen;
              hiEnd = leftTrimLen + len;
              break;
            }
          }
        }

        // 3. Text contained in highlightText (page smaller than sentence)
        if (hiStart < 0 &&
            text.length > 3 &&
            highlightText.contains(text.trim())) {
          hiStart = 0;
          hiEnd = text.length;
        }
      }

      if (hiStart >= 0) {
        hiEnd = hiEnd.clamp(0, text.length);
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
      color: (bodyStyle.color ?? _textColor).withOpacityCompat(0.55),
    );

    final highlightStyle = bodyStyle.copyWith(
      backgroundColor: AppColors.techBlue.withOpacityCompat(0.12),
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
    if (viewportHeight <= 0 || contentWidth <= 0) return minEnd;

    int probeChars = previousPageChars.clamp(512, 16000);
    int probeEnd = (start + probeChars).clamp(minEnd, len);

    while (true) {
      final slice = text.substring(start, probeEnd);
      textPainter.text = _buildReaderSpan(
        text: slice,
        bodyStyle: textStyle,
        highlightText: null,
      );
      textPainter.layout(minWidth: 0, maxWidth: contentWidth);

      if (probeEnd >= len) break;
      if (textPainter.height >= viewportHeight) break;

      final int curChars = probeEnd - start;
      final int nextChars = (curChars * 2).clamp(curChars + 1, 65536);
      final int nextEnd = (start + nextChars).clamp(probeEnd + 1, len);
      if (nextEnd == probeEnd) break;
      probeEnd = nextEnd;
    }

    final localLen = (probeEnd - start).clamp(1, 1 << 30);
    final lines = textPainter.computeLineMetrics();
    if (lines.isEmpty) return minEnd;

    final double lineHeight = textPainter.preferredLineHeight;
    final double safetyPx = (lineHeight * 0.10).clamp(2.0, 8.0);
    final double dyLimit = (viewportHeight - safetyPx).clamp(0, viewportHeight);

    int lastVisibleLine = 0;
    for (int i = 0; i < lines.length; i++) {
      final lineBottom = lines[i].baseline + lines[i].descent;
      if (lineBottom <= dyLimit) {
        lastVisibleLine = i;
      } else {
        break;
      }
    }

    final double dx = (contentWidth - 1).clamp(0, contentWidth);
    final double dy = (lines[lastVisibleLine].baseline +
            (lines[lastVisibleLine].descent * 0.5))
        .clamp(0, dyLimit);
    final pos = textPainter.getPositionForOffset(Offset(dx, dy));
    int localEnd = pos.offset.clamp(1, localLen);

    final boundary =
        textPainter.getLineBoundary(TextPosition(offset: localEnd));
    localEnd = boundary.end.clamp(1, localLen);

    int end = (start + localEnd).clamp(minEnd, len);
    while (end > minEnd && _isSkippableWhitespaceCu(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (end <= start) return minEnd;
    return end;
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
    int? anchorPageIndex;
    if (keyChanged && chapterIndex == _currentChapterIndex) {
      final ranges = _chapterPageRanges[chapterIndex];
      if (ranges != null &&
          ranges.isNotEmpty &&
          _currentPageInChapter < ranges.length) {
        anchorIndex = ranges[_currentPageInChapter].start;
        anchorPageIndex = _currentPageInChapter;
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
      while (start < len &&
          _isSkippableWhitespaceCu(effectiveText.codeUnitAt(start))) {
        start++;
      }
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

      final bool preventBackward = tp.applyToReader;
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
            if (anchorIndex >= ranges[i].start && anchorIndex < ranges[i].end) {
              best = i;
              break;
            }
            if (ranges[i].start > anchorIndex) {
              best = (i - 1).clamp(0, ranges.length - 1);
              break;
            }
            if (i == ranges.length - 1) best = i;
          }
          if (preventBackward && anchorPageIndex != null) {
            if (best < anchorPageIndex) {
              best = anchorPageIndex;
            }
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
      while (start < len &&
          _isSkippableWhitespaceCu(plainText.codeUnitAt(start))) {
        start++;
      }
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
    if (apply) return;

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

  Future<void> _maybeAnalyzeIllustrationsForChapter(int chapterIndex) async {
    if (!mounted) return;
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return;
    if (_illustrationAutoAnalyzeRequested.contains(chapterIndex)) return;
    final aiModel = context.read<AiModelProvider>();
    if (!aiModel.illustrationEnabled) return;
    if (!aiModel.illustrationAutoAnalyzeEnabled) return;
    if (aiModel.source == AiModelSource.none) return;

    final tp = context.read<TranslationProvider>();
    final usingPersonal = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;

    Future<String> Function(String prompt)? generateText;
    if (aiModel.illustrationForceLocalAnalyze) {
      if (!aiModel.localModelReadyForIllustrationAnalysis) return;
      generateText = (prompt) => aiModel.generate(
            prompt: prompt,
            maxTokens: 1024,
            temperature: 0.2,
          );
    } else if (aiModel.source == AiModelSource.local) {
      if (!aiModel.loaded) return;
      generateText = (prompt) => aiModel.generate(
            prompt: prompt,
            maxTokens: 1024,
            temperature: 0.2,
          );
    } else if (aiModel.source == AiModelSource.online && !usingPersonal) {
      if (aiModel.pointsBalance <= 0) return;
    }

    final chapter = _chapters[chapterIndex];
    final chapterTitle = (chapter.title ?? '正文').trim();
    final chapterContent = _getPlainTextForChapter(chapterIndex);
    if (chapterContent.trim().isEmpty) {
      unawaited(_ensureChapterContentCached(chapterIndex));
      return;
    }

    _illustrationAutoAnalyzeRequested.add(chapterIndex);
    debugPrint(
      '[ILLU][autoAnalyze] start bookId=${widget.bookId} chapterIndex=$chapterIndex source=${aiModel.source.name} points=${aiModel.pointsBalance} contentLen=${chapterContent.length}',
    );
    try {
      await context.read<IllustrationProvider>().analyzeChapter(
            chapterId: '${widget.bookId}::$chapterIndex',
            chapterTitle: chapterTitle.isEmpty ? '正文' : chapterTitle,
            content: chapterContent,
            maxScenes: aiModel.maxIllustrationsPerChapter,
            pointsBalance: aiModel.pointsBalance,
            generateText: generateText,
          );
      final chapterId = '${widget.bookId}::$chapterIndex';
      final scenes = context.read<IllustrationProvider>().getScenes(chapterId);
      debugPrint(
        '[ILLU][autoAnalyze] done chapterId=$chapterId scenes=${scenes.length}',
      );
    } catch (e) {
      _illustrationAutoAnalyzeRequested.remove(chapterIndex);
      _showTopError(e.toString());
      debugPrint(
        '[ILLU][autoAnalyze] failed bookId=${widget.bookId} chapterIndex=$chapterIndex err=$e',
      );
      return;
    }
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
        unawaited(_maybeAnalyzeIllustrationsForChapter(chapterIndex));
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
      unawaited(_maybeAnalyzeIllustrationsForChapter(chapterIndex));
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
                                _panelTextColor.withOpacityCompat(0.6)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '解析中…',
                          style: TextStyle(
                            color: _panelTextColor.withOpacityCompat(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                Divider(color: _panelTextColor.withOpacityCompat(0.1)),
                Expanded(
                  child: StatefulBuilder(
                    builder: (context, setModalState) {
                      // Filter visible chapters based on expand/collapse state
                      final visibleChapters = <Map<String, dynamic>>[];
                      for (int i = 0; i < _chapters.length; i++) {
                        final chapter = _chapters[i];
                        // Check if this chapter's parent is expanded
                        bool shouldShow = true;
                        if (chapter is _EpubReaderChapter) {
                          int? parentIdx = chapter.parentIndex;
                          while (parentIdx != null) {
                            if (!_expandedChapterIndices.contains(parentIdx)) {
                              shouldShow = false;
                              break;
                            }
                            // Check grandparent
                            final parentChapter = _chapters[parentIdx];
                            if (parentChapter is _EpubReaderChapter) {
                              parentIdx = parentChapter.parentIndex;
                            } else {
                              break;
                            }
                          }
                        }
                        if (shouldShow) {
                          visibleChapters.add({
                            'index': i,
                            'chapter': chapter,
                          });
                        }
                      }

                      return Scrollbar(
                        controller: scrollController,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: scrollController,
                          itemExtent: itemExtent,
                          cacheExtent: itemExtent * 20,
                          itemCount:
                              (_currentBookFormat == 'txt' && _txtTocParsing)
                                  ? 1
                                  : visibleChapters.length,
                          itemBuilder: (context, listIndex) {
                            if (_currentBookFormat == 'txt' && _txtTocParsing) {
                              return ListTile(
                                title: Text(
                                  '目录解析中…',
                                  style: TextStyle(color: _panelTextColor),
                                ),
                              );
                            }
                            final item = visibleChapters[listIndex];
                            final index = item['index'] as int;
                            final chapter = item['chapter'] as _ReaderChapter;
                            final isExpanded =
                                _expandedChapterIndices.contains(index);
                            final isEpubWithSubs =
                                chapter is _EpubReaderChapter &&
                                    chapter.hasSubChapters;

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
                              trailing: isEpubWithSubs
                                  ? GestureDetector(
                                      onTap: () {
                                        setModalState(() {
                                          if (_expandedChapterIndices
                                              .contains(index)) {
                                            _expandedChapterIndices
                                                .remove(index);
                                          } else {
                                            _expandedChapterIndices.add(index);
                                          }
                                        });
                                      },
                                      child: Icon(
                                        isExpanded
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        color: _panelTextColor
                                            .withOpacityCompat(0.6),
                                        size: 20,
                                      ),
                                    )
                                  : null,
                              onTap: () {
                                if (isEpubWithSubs) {
                                  // Toggle expand/collapse for parent chapters
                                  setModalState(() {
                                    if (_expandedChapterIndices
                                        .contains(index)) {
                                      _expandedChapterIndices.remove(index);
                                    } else {
                                      _expandedChapterIndices.add(index);
                                    }
                                  });
                                } else {
                                  // Navigate to leaf chapters
                                  setState(() {
                                    _currentChapterIndex = index;
                                    _currentPageInChapter = 0;
                                    _pageViewCenterIndex = 1000;
                                  });
                                  if (_pageController.hasClients) {
                                    _pageController.jumpToPage(1000);
                                  }
                                  final translationProvider =
                                      Provider.of<TranslationProvider>(context,
                                          listen: false);
                                  if (translationProvider.applyToReader) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (!mounted) return;
                                      _translateCurrentPageIfNeeded(
                                          translationProvider);
                                    });
                                  }
                                  _hideControls();
                                  Navigator.pop(context);
                                }
                              },
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

                    Row(
                      children: [
                        Icon(Icons.brightness_4_rounded,
                            color: _panelTextColor.withOpacityCompat(0.5)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            '跟随系统深色模式',
                            style:
                                TextStyle(fontSize: 14, color: _panelTextColor),
                          ),
                        ),
                        Switch(
                          value: _followSystemTheme,
                          activeThumbColor: AppColors.techBlue,
                          onChanged: (v) {
                            setSheetState(() {});
                            setState(() {
                              _followSystemTheme = v;
                              if (_followSystemTheme) {
                                final isSystemDark =
                                    MediaQuery.platformBrightnessOf(context) ==
                                        Brightness.dark;
                                if (isSystemDark) {
                                  _bgColor = const Color(0xFF121212);
                                  _textColor = const Color(0xFFEEEEEE);
                                } else {
                                  _bgColor = const Color(0xFFF5F9FA);
                                  _textColor = const Color(0xFF2C3E50);
                                }
                              }
                            });
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Font Size
                    Row(
                      children: [
                        Icon(Icons.format_size,
                            color: _panelTextColor.withOpacityCompat(0.5)),
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
                            color: _panelTextColor.withOpacityCompat(0.5)),
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
    bool isSelected = _bgColor.toARGB32() == color.toARGB32();
    return GestureDetector(
      onTap: () {
        setState(() {
          _followSystemTheme = false;
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
                      : _panelTextColor.withOpacityCompat(0.5),
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
                ? AppColors.techBlue.withOpacityCompat(0.1)
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
            _hideControls();
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
            _scheduleUpdateReadAloudFollowFromCurrentView();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _consumePendingIllustrationCompletionToastForCurrentChapter();
            });

            final translationProvider =
                Provider.of<TranslationProvider>(context, listen: false);
            if (translationProvider.applyToReader) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final currentPage =
                    _paragraphsByIndexForPageOffsetForTranslation(
                        0, translationProvider);
                if (currentPage.isNotEmpty) {
                  translationProvider
                      .clearFailedForParagraphs(currentPage.values);
                }
                _translateCurrentPageIfNeeded(translationProvider);
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
        double snapUp(double value) => (value * dpr).ceilToDouble() / dpr;
        double snapDown(double value) => (value * dpr).floorToDouble() / dpr;

        final storedBottomInset = _contentBottomInset ?? 0.0;
        final double safeBottom = storedBottomInset > padding.bottom
            ? storedBottomInset
            : padding.bottom;

        final TextStyle effectiveTextStyle =
            (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
                .copyWith(
          height: _lineHeight,
          fontSize: _fontSize,
          color: _textColor,
        );

        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final double rawContentWidth = (maxWidth - 48);
        final double safeMaxWidth = maxWidth <= 1 ? 1 : maxWidth;
        final double safeContentWidth = rawContentWidth.isFinite
            ? rawContentWidth.clamp(
                safeMaxWidth < 40 ? 1.0 : 40.0, safeMaxWidth)
            : (safeMaxWidth < 40 ? 1.0 : 40.0);

        final textScaler = MediaQuery.of(context).textScaler;
        final probe = TextPainter(
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
          strutStyle: StrutStyle.fromTextStyle(effectiveTextStyle,
              forceStrutHeight: true),
          text: TextSpan(text: '国Ay', style: effectiveTextStyle),
        )..layout(minWidth: 0, maxWidth: safeContentWidth);
        final double minLineHeight = probe.height;
        final double topExtra = snap((minLineHeight * 0.18).clamp(4.0, 10.0));
        final bool needsExtraBottomPadding = !kIsWeb &&
            (Platform.isIOS || Platform.isAndroid) &&
            safeBottom > 0.5;

        // Use standard padding for better screen utilization.
        // We will explicitly handle the footer position to avoid overlap.
        final double minBottomExtra = needsExtraBottomPadding ? 16.0 : 10.0;
        final double maxBottomExtra = needsExtraBottomPadding ? 24.0 : 18.0;
        final double bottomExtra =
            snap((minLineHeight * 0.28).clamp(minBottomExtra, maxBottomExtra));
        final double topMargin = snapUp(padding.top + topExtra);

        // Calculate Footer Position (closer to bottom)
        // User feedback: "Whitespace too large, reduce it."
        // Adjusted from 32.0 to 24.0. This is still well above the Home Indicator (~8-10pt).
        final double footerBottomPos = safeBottom > 20 ? 24.0 : 12.0;
        final double footerHeight = 20.0;
        final double footerTopEdge = footerBottomPos + footerHeight;

        // Ensure text doesn't overlap footer
        // User feedback: "Whitespace too large."
        // Buffer reduced from 20.0 to 12.0.
        final double minBottomMargin = snapUp(footerTopEdge + 12.0);

        double bottomMargin = snapUp(safeBottom + bottomExtra);
        // If the calculated bottom margin (based on safe area) is less than what we need for the footer,
        // use the footer-based margin.
        // Note: safeBottom is usually ~34. bottomExtra ~16. Total ~50.
        // footerTopEdge ~32. minBottomMargin ~40.
        // So normally bottomMargin (50) > minBottomMargin (40), meaning text is naturally high enough.
        // This ensures we don't artificially push text too high if not needed.
        if (bottomMargin < minBottomMargin) {
          bottomMargin = minBottomMargin;
        }

        double viewportHeight = snapDown(
          constraints.maxHeight - topMargin - bottomMargin - (1 / dpr),
        );
        if (viewportHeight <= 0) {
          viewportHeight = minLineHeight > 0 ? minLineHeight : 500;
        } else if (minLineHeight > 0 && viewportHeight < minLineHeight) {
          viewportHeight = minLineHeight;
        }

        // Safety buffer for pagination:
        // User feedback: "Last line slightly clipped."
        // Reserve extra pixels so line glyphs never get clipped by the viewport bounds on some devices.
        final double paginationViewportHeight = viewportHeight - 12.0;

        _lastPaginationViewportHeight = paginationViewportHeight;
        _lastPaginationContentWidth = safeContentWidth;

        _scheduleTextPaginationForChapter(
          chapterIndex: chapterIndex,
          viewportHeight: paginationViewportHeight,
          contentWidth: safeContentWidth,
          minPages: (pageIndex + 3).clamp(6, 999999),
        );
        final tp = Provider.of<TranslationProvider>(context, listen: false);
        if (tp.applyToReader) {
          _schedulePlainPaginationForChapter(
            chapterIndex: chapterIndex,
            viewportHeight: paginationViewportHeight,
            contentWidth: safeContentWidth,
            minPages: (pageIndex + 3).clamp(6, 999999),
          );
        }

        final ranges = _chapterPageRanges[chapterIndex];
        List<TextRange>? displayRanges = ranges;
        String? displayEffectiveText = _chapterEffectiveText[chapterIndex];
        if (displayRanges == null || displayRanges.isEmpty) {
          final fallbackRanges = _chapterFallbackPageRanges[chapterIndex];
          final fallbackKey = _chapterFallbackPageRangeKeys[chapterIndex];
          final fallbackEffectiveText =
              _chapterFallbackEffectiveText[chapterIndex];
          final expectedTextLength = (fallbackEffectiveText != null &&
                  fallbackEffectiveText.isNotEmpty)
              ? fallbackEffectiveText.length
              : _getPlainTextForChapter(chapterIndex).length;
          final expectedKey = _paginationKey(
            viewportHeight: paginationViewportHeight,
            contentWidth: safeContentWidth,
            textLength: expectedTextLength,
          );
          if (fallbackRanges != null &&
              fallbackRanges.isNotEmpty &&
              fallbackKey == expectedKey) {
            displayRanges = fallbackRanges;
            displayEffectiveText = fallbackEffectiveText;
          }
        }
        if (displayRanges == null || displayRanges.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (pageIndex >= displayRanges.length) {
          _scheduleTextPaginationForChapter(
            chapterIndex: chapterIndex,
            viewportHeight: paginationViewportHeight,
            contentWidth: safeContentWidth,
            minPages: (pageIndex + 3).clamp(6, 999999),
          );
          if (tp.applyToReader) {
            _schedulePlainPaginationForChapter(
              chapterIndex: chapterIndex,
              viewportHeight: paginationViewportHeight,
              contentWidth: safeContentWidth,
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
                contentWidth: safeContentWidth,
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
        String pageText = effectiveText.substring(start, end);
        final rap = context.watch<ReadAloudProvider>();
        final String? highlightText = (tp.aiReadAloudEnabled &&
                rap.position?.bookId == widget.bookId &&
                rap.position?.chapterIndex == chapterIndex)
            ? rap.highlightText
            : null;
        final TextSpan span = _buildReaderSpan(
          text: pageText,
          bodyStyle: effectiveTextStyle,
          highlightText: highlightText,
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
                child: ClipRect(
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
                        highlightText: highlightText,
                        isLastPage: safeIndex == displayRanges.length - 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Footer with Page Number
            if (!_showControls)
              Positioned(
                left: 24,
                right: 24,
                bottom: footerBottomPos,
                height: footerHeight,
                child: DefaultTextStyle(
                  style: effectiveTextStyle.copyWith(
                    fontSize: 10,
                    height: 1.2,
                    color: effectiveTextStyle.color?.withOpacity(0.5),
                  ),
                  child: Row(
                    children: [
                      // Chapter Title (Left)
                      Expanded(
                        child: Text(
                          _chapters[chapterIndex].title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Page Number (Right)
                      Text('${pageIndex + 1}/${displayRanges.length}'),
                    ],
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
    required String? highlightText,
    required bool isLastPage,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Builder(
        builder: (context) {
          String selectedText = '';
          final chapterId = '${widget.bookId}::$chapterIndex';
          final scenes =
              context.watch<IllustrationProvider>().getScenes(chapterId);
          final List<({int offset, String sceneId})> hintOffsets = [];
          if (scenes.isNotEmpty) {
            final Map<int, int> paraEndOffset = {};
            final matches =
                RegExp(r'\n{2,}').allMatches(effectiveText).toList();
            int startPos = 0;
            int paraIndex = 0;
            for (final m in matches) {
              final endPos = m.start;
              final raw = effectiveText.substring(startPos, endPos);
              final cleaned = raw
                  .replaceAll(RegExp(r'^\n+'), '')
                  .replaceAll(RegExp(r'\n+$'), '')
                  .replaceAll(RegExp(r'^[ \t\u3000]+'), '');
              if (cleaned.trim().isNotEmpty) {
                paraEndOffset[paraIndex] = endPos;
                paraIndex++;
              }
              startPos = m.end;
            }
            if (startPos < effectiveText.length) {
              final raw = effectiveText.substring(startPos);
              final cleaned = raw
                  .replaceAll(RegExp(r'^\n+'), '')
                  .replaceAll(RegExp(r'\n+$'), '')
                  .replaceAll(RegExp(r'^[ \t\u3000]+'), '');
              if (cleaned.trim().isNotEmpty) {
                paraEndOffset[paraIndex] = effectiveText.length;
              }
            }
            final List<({int offset, String sceneId})> rawHints = [];
            for (final s in scenes) {
              final endIdx = s.endParagraphIndex;
              if (endIdx == null) continue;
              final absoluteEnd = paraEndOffset[endIdx];
              if (absoluteEnd == null) continue;
              if (absoluteEnd <= range.start || absoluteEnd > end) continue;
              final rel =
                  (absoluteEnd - range.start).clamp(0, end - range.start);
              rawHints.add((offset: rel, sceneId: s.id));
            }
            rawHints.sort((a, b) => a.offset.compareTo(b.offset));
            hintOffsets.addAll(rawHints);
          }
          TextSpan effectiveBodySpan = bodySpan;
          if (kDebugMode) {
            final uiKey =
                '$chapterId|cur=$isCurrentPage|last=$isLastPage|scenes=${scenes.length}|hints=${hintOffsets.length}';
            if (uiKey != _lastIllustrationUiLogKey &&
                (isCurrentPage || isLastPage)) {
              _lastIllustrationUiLogKey = uiKey;
              debugPrint('[ILLU][ui] $uiKey range=${range.start}-${end}');
            }
          }
          if (hintOffsets.isNotEmpty) {
            final pageText = effectiveText.substring(
                range.start.clamp(0, effectiveText.length), end);
            final children = <InlineSpan>[];
            int cursor = 0;
            for (final h in hintOffsets) {
              if (h.offset < cursor || h.offset > pageText.length) continue;
              final seg = pageText.substring(cursor, h.offset);
              if (seg.isNotEmpty) {
                children.add(
                  _buildReaderSpan(
                    text: seg,
                    bodyStyle: bodyStyle,
                    highlightText: highlightText,
                  ),
                );
              }
              children.add(
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) => _suppressReaderTap(),
                      child: GestureDetector(
                        onTapDown: (_) => _suppressReaderTap(),
                        onTap: () {
                          _suppressReaderTap();
                          unawaited(
                            _openIllustrationPanelForChapter(
                              chapterIndex: chapterIndex,
                              onlySceneId: h.sceneId,
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.techBlue.withOpacityCompat(0.12),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: AppColors.techBlue.withOpacityCompat(0.28),
                              width: AppTokens.stroke,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.image_outlined,
                                size: 14,
                                color: AppColors.techBlue,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '查看插图',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.techBlue,
                                  height: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              cursor = h.offset;
            }
            final tail = pageText.substring(cursor);
            if (tail.isNotEmpty) {
              children.add(
                _buildReaderSpan(
                  text: tail,
                  bodyStyle: bodyStyle,
                  highlightText: highlightText,
                ),
              );
            }

            effectiveBodySpan = TextSpan(style: bodyStyle, children: children);
          }
          return SelectionArea(
            key: ValueKey(
                'sel_${chapterIndex}_${range.start}_$_selectionAreaResetToken'),
            onSelectionChanged: (value) {
              selectedText =
                  ((value as dynamic)?.plainText as String?)?.trim() ?? '';
            },
            contextMenuBuilder: (context, selectableRegionState) {
              final text = selectedText.trim();
              final tp = context.read<TranslationProvider>();
              final readAloud = context.read<ReadAloudProvider>();
              final aiModel = context.read<AiModelProvider>();
              final personalUsable = tp.usingPersonalTencentKeys &&
                  getEmbeddedPublicHunyuanCredentials().isUsable;
              final canReadCurrent = tp.aiReadAloudEnabled && text.isNotEmpty;
              final canTranslate = text.isNotEmpty &&
                  (tp.translationMode == TranslationMode.machine ||
                      (tp.translationMode == TranslationMode.bigModel &&
                          (aiModel.pointsBalance > 0 || personalUsable)));
              final canExplain = text.isNotEmpty &&
                  ((aiModel.source == AiModelSource.local && aiModel.loaded) ||
                      (aiModel.source == AiModelSource.online &&
                          (aiModel.pointsBalance > 0 || personalUsable)));
              final selectionIllustrationErr =
                  _validateSelectionForIllustration(text);
              final canIllustrate = text.isNotEmpty &&
                  ((aiModel.illustrationForceLocalAnalyze &&
                          aiModel.localModelReadyForIllustrationAnalysis) ||
                      (aiModel.source == AiModelSource.local &&
                          aiModel.loaded) ||
                      (aiModel.source == AiModelSource.online &&
                          (aiModel.pointsBalance > 0 || personalUsable)));
              final isDarkBg = _bgColor.computeLuminance() < 0.5;
              final toolbarBg = isDarkBg
                  ? Colors.white.withOpacityCompat(0.94)
                  : AppColors.deepSpace.withOpacityCompat(0.92);
              final toolbarFg = isDarkBg ? AppColors.deepSpace : Colors.white;
              final disabledFg = toolbarFg.withOpacityCompat(0.38);
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

              final items = <ContextMenuButtonItem>[
                if (canReadCurrent)
                  ContextMenuButtonItem(
                    onPressed: () {
                      ContextMenuController.removeAny();
                      selectableRegionState.hideToolbar();
                      if (mounted) {
                        setState(() {
                          _selectionAreaResetToken++;
                        });
                      }
                      unawaited(() async {
                        await readAloud.stop(keepResume: true);
                        if (!mounted) return;
                        await _startReadAloudFromSelection(text);
                      }());
                    },
                    type: ContextMenuButtonType.custom,
                    label: '读当前',
                  ),
                if (canTranslate)
                  ContextMenuButtonItem(
                    onPressed: () {
                      ContextMenuController.removeAny();
                      selectableRegionState.hideToolbar();
                      if (mounted) {
                        setState(() {
                          _selectionAreaResetToken++;
                        });
                      }
                      unawaited(_showSelectionTranslation(text));
                    },
                    type: ContextMenuButtonType.custom,
                    label: '翻译',
                  ),
                if (canExplain)
                  ContextMenuButtonItem(
                    onPressed: () {
                      ContextMenuController.removeAny();
                      selectableRegionState.hideToolbar();
                      if (mounted) {
                        setState(() {
                          _selectionAreaResetToken++;
                        });
                      }
                      unawaited(_openAiHud(
                        initialRoute: AiHudRoute.qa,
                        initialQaText: text,
                        autoSendInitialQa: true,
                      ));
                    },
                    type: ContextMenuButtonType.custom,
                    label: '解释',
                  ),
                if (canIllustrate)
                  ContextMenuButtonItem(
                    onPressed: () {
                      ContextMenuController.removeAny();
                      selectableRegionState.hideToolbar();
                      if (mounted) {
                        setState(() {
                          _selectionAreaResetToken++;
                        });
                      }
                      unawaited(() async {
                        final err = selectionIllustrationErr;
                        if (err != null) {
                          _showCenterToast(err);
                          return;
                        }
                        final pageText = effectiveText.substring(
                          range.start.clamp(0, effectiveText.length),
                          end,
                        );
                        int rel = pageText.indexOf(text);
                        int abs = -1;
                        if (rel >= 0) {
                          abs = range.start + rel;
                        } else {
                          abs = effectiveText.indexOf(text);
                        }
                        if (abs < 0) {
                          _showCenterToast('无法定位段落');
                          return;
                        }
                        final paraIndex = _paragraphIndexAtOffset(
                          effectiveText: effectiveText,
                          absoluteOffset: abs,
                        );
                        if (paraIndex == null) {
                          _showCenterToast('无法定位段落');
                          return;
                        }

                        final chapter = _chapters[chapterIndex];
                        final chapterTitle = (chapter.title ?? '正文').trim();
                        final chapterId = '${widget.bookId}::$chapterIndex';

                        Future<String> Function(String prompt)? generateText;
                        if (aiModel.illustrationForceLocalAnalyze) {
                          if (!aiModel.localModelReadyForIllustrationAnalysis) {
                            _showCenterToast('本地模型未就绪，需下载模型');
                            return;
                          }
                          generateText = (prompt) => aiModel.generate(
                                prompt: prompt,
                                maxTokens: 1024,
                                temperature: 0.2,
                              );
                        } else if (aiModel.source == AiModelSource.local) {
                          if (!aiModel.loaded) {
                            _showCenterToast('本地模型未就绪');
                            return;
                          }
                          generateText = (prompt) => aiModel.generate(
                                prompt: prompt,
                                maxTokens: 1024,
                                temperature: 0.2,
                              );
                        } else if (aiModel.source == AiModelSource.online &&
                            !personalUsable &&
                            aiModel.pointsBalance <= 0) {
                          _showCenterToast('积分不足，无法插图分析');
                          return;
                        }

                        try {
                          final cards = await context
                              .read<IllustrationProvider>()
                              .analyzeSelectionForChapter(
                                chapterId: chapterId,
                                chapterTitle:
                                    chapterTitle.isEmpty ? '正文' : chapterTitle,
                                selectionText: text,
                                paragraphIndex: paraIndex,
                                pointsBalance: aiModel.pointsBalance,
                                generateText: generateText,
                              );
                          _showCenterToast(
                            cards.isNotEmpty ? '插图分析完成' : '无适合插画的场景',
                          );
                        } catch (e) {
                          _showCenterToast(e.toString());
                        }
                      }());
                    },
                    type: ContextMenuButtonType.custom,
                    label: '插图',
                  ),
              ];
              final ContextMenuButtonItem? copyItem = selectableRegionState
                  .contextMenuButtonItems
                  .where((e) => e.type == ContextMenuButtonType.copy)
                  .cast<ContextMenuButtonItem?>()
                  .firstWhere((e) => e != null, orElse: () => null);
              final ContextMenuButtonItem? selectAllItem = selectableRegionState
                  .contextMenuButtonItems
                  .where((e) => e.type == ContextMenuButtonType.selectAll)
                  .cast<ContextMenuButtonItem?>()
                  .firstWhere((e) => e != null, orElse: () => null);
              if (copyItem != null) {
                items.add(
                  ContextMenuButtonItem(
                    onPressed: () {
                      copyItem.onPressed?.call();
                      ContextMenuController.removeAny();
                      selectableRegionState.hideToolbar();
                      if (mounted) {
                        setState(() {
                          _selectionAreaResetToken++;
                        });
                      }
                    },
                    type: copyItem.type,
                    label: '复制',
                  ),
                );
              }
              if (selectAllItem != null) {
                items.add(
                  ContextMenuButtonItem(
                    onPressed: selectAllItem.onPressed,
                    type: selectAllItem.type,
                    label: '全选',
                  ),
                );
              }

              return Theme(
                data: themed,
                child: AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: selectableRegionState.contextMenuAnchors,
                  buttonItems: items,
                ),
              );
            },
            child: Text.rich(
              effectiveBodySpan,
              style: bodyStyle,
              strutStyle:
                  StrutStyle.fromTextStyle(bodyStyle, forceStrutHeight: true),
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: false,
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openIllustrationPanelForChapter({
    required int chapterIndex,
    required String? onlySceneId,
  }) async {
    _hideControls();
    final chapter = _chapters[chapterIndex];
    final chapterTitle = (chapter.title ?? '正文').trim();
    final chapterId = '${widget.bookId}::$chapterIndex';
    final plain = _getPlainTextForChapter(chapterIndex);
    final panelTitle = onlySceneId == null ? '本章插图' : '插图';
    if (kDebugMode) {
      final scenes = context.read<IllustrationProvider>().getScenes(chapterId);
      debugPrint(
        '[ILLU][openPanel] chapterId=$chapterId onlySceneId=$onlySceneId scenes=${scenes.length} plainLen=${plain.length}',
      );
    }

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final media = MediaQuery.of(context);
        final panelText = _panelTextColor;
        final panelBg = _panelBgColor;
        final aiModel = context.watch<AiModelProvider>();
        final usingPersonal = usingPersonalTencentKeys();
        return GlassPanel.sheet(
          surfaceColor: panelBg,
          opacity: AppTokens.glassOpacityDense,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height:
                  (media.size.height * 0.78).clamp(360.0, media.size.height),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.image_outlined,
                            color: AppColors.techBlue),
                        const SizedBox(width: 8),
                        Text(
                          panelTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: panelText,
                          ),
                        ),
                        if (!usingPersonal)
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              '剩余积分：${aiModel.pointsBalance}（生图2万/张）',
                              style: TextStyle(
                                color: panelBg.computeLuminance() < 0.5
                                    ? const Color(0xFFE6A23C)
                                    : const Color(0xFFF57C00),
                                fontSize: 12,
                                height: 1.0,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(Icons.close,
                              color: panelText.withOpacityCompat(0.7)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: IllustrationPanel(
                        isDark: panelBg.computeLuminance() < 0.5,
                        bgColor: panelBg,
                        textColor: panelText,
                        bookId: widget.bookId,
                        chapterId: chapterId,
                        chapterTitle: chapterTitle,
                        chapterContent: plain,
                        autoGenerateFromSelection: false,
                        onlySceneId: onlySceneId,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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

  Map<int, String> _paragraphsByIndexForRangeStartingInside({
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
      if (p.start >= start && p.start < end) {
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

  Map<int, String> _paragraphsByIndexForPageForTranslation({
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
    return _paragraphsByIndexForRangeStartingInside(
      chapterIndex: chapterIndex,
      plainText: plainText,
      start: range.start,
      end: end,
    );
  }

  List<TextRange>? _displayRangesForChapter(int chapterIndex) {
    final ranges = _chapterPageRanges[chapterIndex];
    if (ranges != null && ranges.isNotEmpty) return ranges;
    final fallback = _chapterFallbackPageRanges[chapterIndex];
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return null;
  }

  Map<int, String> _paragraphsByIndexForPageForTranslationWithProvider({
    required int chapterIndex,
    required int pageIndex,
    required TranslationProvider tp,
  }) {
    final displayRanges = _displayRangesForChapter(chapterIndex);
    if (tp.applyToReader && displayRanges != null && displayRanges.isNotEmpty) {
      if (pageIndex < 0 || pageIndex >= displayRanges.length) return {};
      final effectiveText = _chapterEffectiveText[chapterIndex] ??
          _getEffectiveTextForChapter(chapterIndex, tp);
      if (effectiveText.isEmpty) return {};
      final range = displayRanges[pageIndex];
      final end = range.end.clamp(0, effectiveText.length);
      return _paragraphsByIndexForEffectiveRangeStartingInside(
        chapterIndex: chapterIndex,
        start: range.start,
        end: end,
        tp: tp,
      );
    }
    return _paragraphsByIndexForPageForTranslation(
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
    );
  }

  Map<int, String> _paragraphsByIndexForEffectiveRangeStartingInside({
    required int chapterIndex,
    required int start,
    required int end,
    required TranslationProvider tp,
  }) {
    final plainText = _getPlainTextForChapter(chapterIndex);
    if (plainText.isEmpty) return {};
    final paragraphs = _getParagraphsForChapter(chapterIndex, plainText);
    if (paragraphs.isEmpty) return {};

    final bool isBilingual =
        tp.config.displayMode == TranslationDisplayMode.bilingual;
    final bool isTransOnly =
        tp.config.displayMode == TranslationDisplayMode.translationOnly;

    int cursor = 0;
    final Map<int, String> out = {};
    for (int i = 0; i < paragraphs.length; i++) {
      final p = paragraphs[i];
      final trans = tp.getCachedTranslation(p.text);
      final pending = tp.isTranslationPending(p.text);
      final failed = tp.isTranslationFailed(p.text);
      // final String indent = '';

      String render;
      if (trans != null && trans.isNotEmpty) {
        if (isTransOnly) {
          render = trans;
        } else {
          render = '${p.text}\n$trans';
        }
      } else if (pending) {
        if (isTransOnly || isBilingual) {
          render = '${p.text}\n翻译中...';
        } else {
          render = p.text;
        }
      } else if (failed) {
        if (isTransOnly || isBilingual) {
          render = '${p.text}\n翻译失败';
        } else {
          render = p.text;
        }
      } else {
        render = p.text;
      }

      final paraStart = cursor;
      // if (paraStart >= end) break;
      if (paraStart >= start && paraStart < end) {
        out[p.index] = p.text;
      }
      cursor = paraStart + render.length;
      if (i < paragraphs.length - 1) {
        cursor += 2;
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
      final cleaned = raw
          .replaceAll(RegExp(r'^\n+'), '')
          .replaceAll(RegExp(r'\n+$'), '')
          .replaceAll(RegExp(r'^[ \t\u3000]+'), '');
      if (cleaned.trim().isNotEmpty) {
        out.add(
            ReaderParagraph(index: idx, start: start, end: end, text: cleaned));
        idx++;
      }
      start = m.end;
    }

    if (start < plainText.length) {
      final raw = plainText.substring(start);
      final cleaned = raw
          .replaceAll(RegExp(r'^\n+'), '')
          .replaceAll(RegExp(r'\n+$'), '')
          .replaceAll(RegExp(r'^[ \t\u3000]+'), '');
      if (cleaned.trim().isNotEmpty) {
        out.add(ReaderParagraph(
            index: idx, start: start, end: plainText.length, text: cleaned));
      }
    }

    _chapterParagraphsCache[chapterIndex] = out;
    return out;
  }

  Map<int, String> _currentPageParagraphsByIndex() {
    final tp = context.read<TranslationProvider>();
    if (tp.applyToReader) {
      final displayRanges = _displayRangesForChapter(_currentChapterIndex);
      if (displayRanges != null && displayRanges.isNotEmpty) {
        final pageIndex =
            _currentPageInChapter.clamp(0, displayRanges.length - 1);
        final range = displayRanges[pageIndex];
        final effectiveText = _chapterEffectiveText[_currentChapterIndex] ??
            _getEffectiveTextForChapter(_currentChapterIndex, tp);
        if (effectiveText.isEmpty) return {};
        final end = range.end.clamp(0, effectiveText.length);
        return _paragraphsByIndexForEffectiveRangeStartingInside(
          chapterIndex: _currentChapterIndex,
          start: range.start,
          end: end,
          tp: tp,
        );
      }
    }

    var ranges = _chapterPlainPageRanges[_currentChapterIndex];
    if (ranges == null || ranges.isEmpty) {
      ranges = _chapterPageRanges[_currentChapterIndex];
    }
    if (ranges == null || ranges.isEmpty) return {};

    final plainText = _getPlainTextForChapter(_currentChapterIndex);
    if (plainText.isEmpty) return {};

    int pageIndex;
    if (_chapterPlainPageRanges[_currentChapterIndex]?.isNotEmpty == true) {
      pageIndex = _plainPageIndexForProgress(
        _currentChapterIndex,
        _currentPageProgressInChapter,
      );
    } else {
      pageIndex = _currentPageInChapter;
    }

    final range = ranges[pageIndex.clamp(0, ranges.length - 1)];
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

  _TranslationPageSlice? _pageSliceForTranslationOffset(
      int offset, TranslationProvider tp) {
    int chapterIndex = _currentChapterIndex;
    final hasDisplayRanges =
        tp.applyToReader && _displayRangesForChapter(chapterIndex) != null;
    int pageIndex =
        hasDisplayRanges ? _currentPageInChapter : _currentPlainPageIndex();
    final currentRanges = tp.applyToReader
        ? (_displayRangesForChapter(chapterIndex) ??
            _chapterPlainPageRanges[chapterIndex])
        : _chapterPlainPageRanges[chapterIndex];
    if (currentRanges != null && currentRanges.isNotEmpty) {
      pageIndex = pageIndex.clamp(0, currentRanges.length - 1);
    }
    pageIndex += offset;
    while (true) {
      final ranges = tp.applyToReader
          ? (_displayRangesForChapter(chapterIndex) ??
              _chapterPlainPageRanges[chapterIndex])
          : _chapterPlainPageRanges[chapterIndex];
      if (ranges == null || ranges.isEmpty) return null;
      if (pageIndex < ranges.length) {
        final map = _paragraphsByIndexForPageForTranslationWithProvider(
          chapterIndex: chapterIndex,
          pageIndex: pageIndex,
          tp: tp,
        );
        return _TranslationPageSlice(
          chapterIndex: chapterIndex,
          paragraphsByIndex: map,
        );
      }
      pageIndex -= ranges.length;
      chapterIndex++;
      if (chapterIndex >= _chapters.length) return null;
    }
  }

  Map<int, String> _paragraphsByIndexForPageOffsetForTranslation(
      int offset, TranslationProvider tp) {
    int chapterIndex = _currentChapterIndex;
    final hasDisplayRanges =
        tp.applyToReader && _displayRangesForChapter(chapterIndex) != null;
    int pageIndex =
        hasDisplayRanges ? _currentPageInChapter : _currentPlainPageIndex();
    final currentRanges = tp.applyToReader
        ? (_displayRangesForChapter(chapterIndex) ??
            _chapterPlainPageRanges[chapterIndex])
        : _chapterPlainPageRanges[chapterIndex];
    if (currentRanges != null && currentRanges.isNotEmpty) {
      pageIndex = pageIndex.clamp(0, currentRanges.length - 1);
    }
    pageIndex += offset;
    while (true) {
      final ranges = tp.applyToReader
          ? (_displayRangesForChapter(chapterIndex) ??
              _chapterPlainPageRanges[chapterIndex])
          : _chapterPlainPageRanges[chapterIndex];
      if (ranges == null || ranges.isEmpty) return {};
      if (pageIndex < ranges.length) {
        return _paragraphsByIndexForPageForTranslationWithProvider(
          chapterIndex: chapterIndex,
          pageIndex: pageIndex,
          tp: tp,
        );
      }
      pageIndex -= ranges.length;
      chapterIndex++;
      if (chapterIndex >= _chapters.length) return {};
    }
  }

  void _syncTranslationQueueStatus(TranslationProvider tp) {
    tp.updateReaderTranslationQueueStatus(
      total: _translationQueueTotal,
      completed: _translationQueueCompleted,
      failed: _translationQueueFailed,
      insertFailed: _translationInsertFailed,
      pendingExternal: _translationQueuePendingExternal,
      running: _translationQueueRunning,
      inserting: _translationInsertRunning,
      inFlight: _translationQueueInFlight,
    );
  }

  void _rebuildTranslationQueueForCurrentPage(TranslationProvider tp) {
    final session = ++_translationQueueSession;
    _translationQueue.clear();
    _translatedResultsQueue.clear();
    _translationQueueStates.clear();
    _translationQueueKeys.clear();
    _translationQueueTotal = 0;
    _translationQueueCompleted = 0;
    _translationQueueFailed = 0;
    _translationInsertFailed = 0;
    _translationQueuePendingExternal = 0;
    _translationQueueInFlight = false;

    final slices = <_TranslationPageSlice?>[
      _pageSliceForTranslationOffset(0, tp),
      _pageSliceForTranslationOffset(1, tp),
    ];

    for (final slice in slices) {
      if (slice == null) continue;
      final entries = slice.paragraphsByIndex.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in entries) {
        final text = entry.value;
        if (text.trim().isEmpty) continue;
        final key = '${slice.chapterIndex}:${entry.key}';
        if (_translationQueueKeys.contains(key)) continue;
        _translationQueueKeys.add(key);
        _translationQueueTotal++;
        if (tp.getCachedTranslation(text) != null) {
          _translationQueueCompleted++;
          _translationQueueStates[key] = _TranslationQueueState.inserted;
          continue;
        }
        if (tp.isTranslationFailed(text)) {
          _translationQueueFailed++;
          _translationQueueStates[key] = _TranslationQueueState.failed;
          continue;
        }
        if (tp.isTranslationPending(text)) {
          _translationQueuePendingExternal++;
          _translationQueueStates[key] = _TranslationQueueState.translating;
          continue;
        }
        final item = _TranslationQueueItem(
          chapterIndex: slice.chapterIndex,
          paragraphIndex: entry.key,
          text: text,
        );
        _translationQueue.add(item);
        _translationQueueStates[key] = _TranslationQueueState.queued;
      }
    }

    if (mounted) setState(() {});
    _syncTranslationQueueStatus(tp);
    _startTranslationQueueIfNeeded(tp, session);
    _startTranslatedResultInsertIfNeeded(tp, session);
  }

  void _startTranslationQueueIfNeeded(TranslationProvider tp, int session) {
    if (_translationQueueRunning) return;
    if (_translationQueue.isEmpty) return;
    _translationQueueRunning = true;
    unawaited(_runTranslationQueue(tp, session));
    if (mounted) setState(() {});
    _syncTranslationQueueStatus(tp);
  }

  Future<void> _runTranslationQueue(TranslationProvider tp, int session) async {
    while (mounted && session == _translationQueueSession) {
      if (_translationQueue.isEmpty) break;
      final item = _translationQueue.removeFirst();
      _translationQueueStates[item.key] = _TranslationQueueState.translating;
      _translationQueueInFlight = true;
      if (mounted) setState(() {});
      _syncTranslationQueueStatus(tp);
      String? translated;
      bool success = false;
      try {
        translated = await tp
            .translateParagraphWithState(item.text)
            .timeout(const Duration(seconds: 70));
        if (translated != null && translated.trim().isNotEmpty) {
          success = true;
        }
      } catch (_) {}
      if (session != _translationQueueSession) break;
      _translationQueueInFlight = false;
      if (success) {
        _translationQueueStates[item.key] = _TranslationQueueState.translated;
        _translationQueueCompleted++;
        _translatedResultsQueue.add(_TranslatedResult(
          item: item,
          translated: translated?.trim(),
          success: true,
        ));
        _startTranslatedResultInsertIfNeeded(tp, session);
      } else {
        _translationQueueStates[item.key] = _TranslationQueueState.failed;
        _translationQueueFailed++;
      }
      if (mounted) setState(() {});
      _syncTranslationQueueStatus(tp);
    }
    _translationQueueRunning = false;
    _translationQueueInFlight = false;
    if (mounted) setState(() {});
    _syncTranslationQueueStatus(tp);
  }

  void _startTranslatedResultInsertIfNeeded(
      TranslationProvider tp, int session) {
    if (_translationInsertRunning) return;
    if (_translatedResultsQueue.isEmpty) return;
    _translationInsertRunning = true;
    unawaited(_runTranslatedResultInsert(tp, session));
    if (mounted) setState(() {});
    _syncTranslationQueueStatus(tp);
  }

  Future<void> _runTranslatedResultInsert(
      TranslationProvider tp, int session) async {
    while (mounted && session == _translationQueueSession) {
      if (_translatedResultsQueue.isEmpty) break;
      final result = _translatedResultsQueue.removeFirst();
      if (!result.success) continue;
      final key = result.item.key;

      // Removed intermediate setState here to prevent flash
      // _translationQueueStates[key] = _TranslationQueueState.translated;
      // if (mounted) setState(() {});
      // _syncTranslationQueueStatus(tp);

      final inserted =
          await _applyTranslatedResultAndWaitPagination(result.item, session);

      if (session != _translationQueueSession) break;
      if (inserted) {
        _translationQueueStates[key] = _TranslationQueueState.inserted;
      } else {
        _translationQueueStates[key] = _TranslationQueueState.failed;
        _translationInsertFailed++;
      }
      if (mounted) setState(() {});
      _syncTranslationQueueStatus(tp);
    }
    _translationInsertRunning = false;
    if (mounted) setState(() {});
    _syncTranslationQueueStatus(tp);
  }

  Future<bool> _applyTranslatedResultAndWaitPagination(
      _TranslationQueueItem item, int session) async {
    final viewportHeight = _lastPaginationViewportHeight;
    final contentWidth = _lastPaginationContentWidth;
    if (viewportHeight == null || contentWidth == null) return false;
    _scheduleTextPaginationForChapter(
      chapterIndex: item.chapterIndex,
      viewportHeight: viewportHeight,
      contentWidth: contentWidth,
      minPages: 6,
    );
    return _waitForTextPaginationComplete(item.chapterIndex, session);
  }

  Future<bool> _waitForTextPaginationComplete(
      int chapterIndex, int session) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (mounted &&
        session == _translationQueueSession &&
        DateTime.now().isBefore(deadline)) {
      if (_chapterTextPaginationComplete[chapterIndex] == true) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return false;
  }

  void _translateCurrentPageIfNeeded(TranslationProvider tp) {
    if (!tp.applyToReader) return;
    final anchorKey =
        '$_currentChapterIndex|$_currentPageInChapter|${tp.config.displayMode.name}|${tp.config.sourceLang}|${tp.config.targetLang}';
    if (anchorKey == _translationQueueAnchorKey) {
      if (_translationQueueRunning || _translationInsertRunning) return;
      if (_translationQueue.isNotEmpty) {
        _startTranslationQueueIfNeeded(tp, _translationQueueSession);
        _startTranslatedResultInsertIfNeeded(tp, _translationQueueSession);
        return;
      }
      if (_translationQueueTotal > 0) return;
    }
    _translationQueueAnchorKey = anchorKey;
    _rebuildTranslationQueueForCurrentPage(tp);
  }

  void _scheduleCurrentPageTranslateResume(TranslationProvider tp) {
    if (!tp.applyToReader) return;
    if (_currentPageTranslateResumeScheduled) return;
    _currentPageTranslateResumeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _currentPageTranslateResumeScheduled = false;
      if (!mounted) return;
      if (!tp.applyToReader) return;
      _translateCurrentPageIfNeeded(tp);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<TranslationProvider>();
    final aiModel = context.watch<AiModelProvider>();
    final readAloud = context.watch<ReadAloudProvider>();

    if (tp.aiReadAloudEnabled && !_lastAiReadAloudEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _setReadAloudFabCollapsed(false);
        _touchFloatingUi();
      });
    }
    _lastAiReadAloudEnabled = tp.aiReadAloudEnabled;

    final pos = readAloud.position;
    final canUseOnlineWithPersonalKeys = tp.usingPersonalTencentKeys &&
        getEmbeddedPublicHunyuanCredentials().isUsable;
    if (aiModel.illustrationEnabled &&
        aiModel.source == AiModelSource.online &&
        !canUseOnlineWithPersonalKeys &&
        aiModel.pointsBalance <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showCenterToast('积分不足，暂停插图生成');
        unawaited(aiModel.setIllustrationEnabled(false));
      });
    }
    if (!aiModel.illustrationEnabled) {
      _illustrationAutoAnalyzeRequested.clear();
    } else if (_chapters.isNotEmpty &&
        !_illustrationAutoAnalyzeRequested.contains(_currentChapterIndex)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_maybeAnalyzeIllustrationsForChapter(_currentChapterIndex));
      });
    }
    _scheduleChapterTranslationPrefetch(
      tp: tp,
      chapterIndex: _currentChapterIndex + 1,
      purpose: 'reader_next',
    );
    if (pos != null && pos.bookId == widget.bookId && tp.aiReadAloudEnabled) {
      _scheduleSyncToReadAloudPosition(pos);
      _maybeAutoContinueToNextChapter(readAloud, pos);
      _scheduleChapterTranslationPrefetch(
        tp: tp,
        chapterIndex: pos.chapterIndex + 1,
        purpose: 'read_aloud_next',
      );
    }
    _scheduleRelocateAfterTranslationChange(tp);
    _scheduleCurrentPageTranslateResume(tp);

    // IMPORTANT: Get padding from MediaQuery BEFORE removing it
    final mq = MediaQuery.of(context);
    final padding = mq.padding;
    final viewPadding = mq.viewPadding;
    final systemGestureInsets = mq.systemGestureInsets;
    final view = View.of(context);
    final dpr = view.devicePixelRatio;
    final stablePadding = view.padding;
    final stableViewPadding = view.viewPadding;
    final stableSystemGestureInsets = view.systemGestureInsets;
    double contentTopInset = viewPadding.top;
    if (padding.top > contentTopInset) contentTopInset = padding.top;
    final overlayTop = contentTopInset + _readerTopExtraForOverlay(context);

    double contentBottomInset = viewPadding.bottom;
    if (padding.bottom > contentBottomInset) {
      contentBottomInset = padding.bottom;
    }
    if (systemGestureInsets.bottom > contentBottomInset) {
      contentBottomInset = systemGestureInsets.bottom;
    }
    final stableBottomCandidates = <double>[
      stablePadding.bottom / dpr,
      stableViewPadding.bottom / dpr,
      stableSystemGestureInsets.bottom / dpr,
    ];
    for (final v in stableBottomCandidates) {
      if (v > contentBottomInset) contentBottomInset = v;
    }
    if (!kIsWeb && Platform.isIOS) {
      final stableTopCandidates = <double>[
        stablePadding.top / dpr,
        stableViewPadding.top / dpr,
      ];
      final hasNotch = contentTopInset > 20.5 ||
          padding.top > 20.5 ||
          viewPadding.top > 20.5 ||
          stableTopCandidates.any((e) => e > 20.5);
      final hasHomeIndicator = hasNotch ||
          contentBottomInset > 0.5 ||
          padding.bottom > 0.5 ||
          viewPadding.bottom > 0.5 ||
          systemGestureInsets.bottom > 0.5 ||
          stableBottomCandidates.any((e) => e > 0.5);
      if (hasHomeIndicator && contentBottomInset < 34.0) {
        contentBottomInset = 34.0;
      }
    }
    if (!kIsWeb && Platform.isAndroid) {
      if (contentBottomInset < 16.0) {
        contentBottomInset = 16.0;
      }
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
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: systemIconBrightness,
        systemNavigationBarIconBrightness: systemIconBrightness,
        systemNavigationBarContrastEnforced: false,
      ),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
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
                // Illustration analyzing status
                Consumer<IllustrationProvider>(
                  builder: (context, illuProvider, _) {
                    final chapterId = '${widget.bookId}::$_currentChapterIndex';
                    final isAnalyzing = illuProvider.isAnalyzing(chapterId);

                    // Prevent overlapping with toast: only show analyzing if no toast is visible
                    if (!isAnalyzing || _centerToastText.trim().isNotEmpty) {
                      return const SizedBox.shrink();
                    }

                    return AnimatedBuilder(
                      animation: _controlsController,
                      builder: (context, child) {
                        return Positioned(
                          top: overlayTop + (48 * _controlsController.value),
                          right: 16,
                          child: child!,
                        );
                      },
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacityCompat(0.72),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                "正在分析插图...",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  height: 1.1,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_centerToastText.trim().isNotEmpty)
                  AnimatedBuilder(
                    animation: _controlsController,
                    builder: (context, child) {
                      return Positioned(
                        top: overlayTop + (48 * _controlsController.value),
                        right: 16,
                        child: child!,
                      );
                    },
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _centerToastText.trim().isNotEmpty ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.7,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacityCompat(0.72),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _centerToastText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              height: 1.1,
                              decoration: TextDecoration.none,
                              fontWeight: FontWeight.normal,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),

                if (_showControls)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleControls,
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                AnimatedBuilder(
                  animation: _controlsController,
                  child: Container(
                    height: contentTopInset + 48,
                    padding: EdgeInsets.only(
                        top: contentTopInset, left: 16, right: 16),
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
                  builder: (context, child) {
                    if (!_showControls && _controlsController.value <= 0.001) {
                      return const SizedBox.shrink();
                    }
                    return SlideTransition(
                        position: _topBarOffset, child: child);
                  },
                ),
                AnimatedBuilder(
                  animation: _controlsController,
                  builder: (context, child) {
                    if (!_showControls && _controlsController.value <= 0.001) {
                      return const SizedBox.shrink();
                    }
                    return Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: SlideTransition(
                        position: _bottomBarOffset,
                        child: child!,
                      ),
                    );
                  },
                  child: Container(
                    padding: EdgeInsets.only(
                        bottom: contentBottomInset,
                        top: 4,
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
                                      color: AppColors.techBlue
                                          .withOpacityCompat(
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
                _buildIllustrationFloatingButton(),
                _buildReadAloudFloatingButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
