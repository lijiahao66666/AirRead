import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/tencent_tts/tencent_tts_client.dart';
import '../../ai/tencentcloud/embedded_public_hunyuan_credentials.dart';
import '../../ai/translation/translation_types.dart';
import '../pages/reader/tts_web_speech.dart';
import '../pages/reader/widgets/reader_paragraph.dart';
import 'translation_provider.dart';

class ReadAloudPosition {
  final String bookId;
  final int chapterIndex;
  final int paragraphIndex;
  final int chunkIndexInParagraph;
  final int highlightOffsetInParagraph;
  final int chapterTextOffset;
  final String highlightText;

  const ReadAloudPosition({
    required this.bookId,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.chunkIndexInParagraph,
    required this.highlightOffsetInParagraph,
    required this.chapterTextOffset,
    required this.highlightText,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'chunkIndexInParagraph': chunkIndexInParagraph,
        'highlightOffsetInParagraph': highlightOffsetInParagraph,
        'chapterTextOffset': chapterTextOffset,
        'highlightText': highlightText,
      };

  static ReadAloudPosition? tryParse(dynamic value) {
    if (value is! Map) return null;
    final bookId = (value['bookId'] ?? '').toString();
    final chapterIndex = _asInt(value['chapterIndex']);
    final paragraphIndex = _asInt(value['paragraphIndex']);
    final chunkIndexInParagraph = _asInt(value['chunkIndexInParagraph']);
    final highlightOffsetInParagraph =
        _asInt(value['highlightOffsetInParagraph']) ?? 0;
    final chapterTextOffset = _asInt(value['chapterTextOffset']) ?? 0;
    final highlightText = (value['highlightText'] ?? '').toString();
    if (bookId.isEmpty ||
        chapterIndex == null ||
        paragraphIndex == null ||
        chunkIndexInParagraph == null) {
      return null;
    }
    return ReadAloudPosition(
      bookId: bookId,
      chapterIndex: chapterIndex,
      paragraphIndex: paragraphIndex,
      chunkIndexInParagraph: chunkIndexInParagraph,
      highlightOffsetInParagraph: highlightOffsetInParagraph,
      chapterTextOffset: chapterTextOffset,
      highlightText: highlightText,
    );
  }

  static int? _asInt(dynamic v) {
    return switch (v) {
      int x => x,
      num x => x.toInt(),
      String x => int.tryParse(x),
      _ => null,
    };
  }
}

class ReadAloudProvider extends ChangeNotifier {
  static const MethodChannel _localTtsChannel =
      MethodChannel('airread/local_tts');
  static const EventChannel _localTtsEvents =
      EventChannel('airread/local_tts_events');

  TranslationProvider? _tp;
  ReadAloudEngine? _lastEngine;
  int? _lastVoiceType;
  double? _lastTtsSpeed;
  double? _lastLocalTtsSpeed;
  bool? _lastApplyToReader;
  TranslationDisplayMode? _lastDisplayMode;
  String? _lastSourceLang;
  String? _lastTargetLang;
  int? _lastCacheRevision;
  bool? _lastAiReadAloudEnabled;
  int? _lastPointsBalance;
  bool? _lastUsingPersonalTencentKeys;
  bool _queueDirty = false;
  SharedPreferences? _prefs;
  StreamSubscription<dynamic>? _localTtsSub;
  StreamSubscription<void>? _playerCompleteSub;

  final AudioPlayer _player = AudioPlayer();
  final WebSpeechTts _webSpeechTts = createWebSpeechTts();
  String? _tempFilePath;
  String? _currentLocalToken;
  String? _lastLocalDoneToken;
  int? _lastLocalDoneSession;
  int? _lastLocalDoneQueuePos;
  DateTime? _lastLocalDoneAt;
  Timer? _localSpeakingPollTimer;
  bool _localSpeakingPollInFlight = false;
  int _localSpeakingPollSession = 0;
  String? _localSpeakingPollToken;
  bool _localSpeakingPollEverSpeaking = false;
  DateTime? _localSpeakingPollStartedAt;
  int _localSpeakingPollErrorCount = 0;

  TencentTtsClient? _tencentTtsClient;
  final Map<String, Uint8List> _onlineAudioCache = {};
  final Map<String, Future<Uint8List>> _onlineAudioInFlight = {};
  final int _onlinePrefetchDistance = 3;
  bool _onlineTransitioning = false;

  bool _initialized = false;
  bool _playing = false;
  bool _preparing = false;
  bool _paused = false;
  bool _endedNaturally = false;
  int _session = 0;

  String? _bookId;
  int? _chapterIndex;
  List<ReaderParagraph> _paragraphs = const [];

  List<_ReadAloudChunk> _queue = const [];
  int _queuePos = 0;

  ReadAloudPosition? _position;

  ReadAloudProvider() {
    unawaited(_init());
  }

  bool get playing => _playing;
  bool get preparing => _preparing;
  bool get paused => _paused;
  bool get endedNaturally => _endedNaturally;

  String? get bookId => _bookId;
  int? get chapterIndex => _chapterIndex;
  ReadAloudPosition? get position => _position;

  String? get highlightText =>
      (_playing || _preparing || _paused) ? _position?.highlightText : null;
  int? get highlightParagraphIndex =>
      (_playing || _preparing || _paused) ? _position?.paragraphIndex : null;

  void updateTranslationProvider(TranslationProvider tp) {
    if (identical(_tp, tp)) return;
    final old = _tp;
    _tp = tp;
    if (old != null) {
      try {
        old.removeListener(_onTtsConfigChanged);
      } catch (_) {}
    }
    _lastEngine = tp.readAloudEngine;
    _lastVoiceType = tp.ttsVoiceType;
    _lastTtsSpeed = tp.ttsSpeed;
    _lastLocalTtsSpeed = tp.localTtsSpeed;
    _lastApplyToReader = tp.applyToReader;
    _lastDisplayMode = tp.config.displayMode;
    _lastSourceLang = tp.config.sourceLang;
    _lastTargetLang = tp.config.targetLang;
    _lastCacheRevision = tp.cacheRevision;
    _lastAiReadAloudEnabled = tp.aiReadAloudEnabled;
    _lastPointsBalance = tp.pointsBalance;
    _lastUsingPersonalTencentKeys = tp.usingPersonalTencentKeys;
    tp.addListener(_onTtsConfigChanged);
  }

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    _prefs = await SharedPreferences.getInstance();
    _restoreLastPosition();
    _playerCompleteSub = _player.onPlayerComplete.listen((_) {
      _onOnlineChunkDone();
    });
    if (!kIsWeb) {
      try {
        _localTtsSub = _localTtsEvents.receiveBroadcastStream().listen((event) {
          if (event is Map) {
            final type = event['type'];
            final int? session = switch (event['session']) {
              int v => v,
              num v => v.toInt(),
              String v => int.tryParse(v),
              _ => null,
            };
            final token = event['token'];
            final tokenStr = token is String ? token : null;
            final curToken = _currentLocalToken;
            if (tokenStr != null &&
                tokenStr.isNotEmpty &&
                curToken != null &&
                curToken.isNotEmpty &&
                tokenStr != curToken) {
              return;
            }
            if (session != null && session != _session) return;
            if (type == 'done') {
              if (tokenStr != null &&
                  tokenStr.isNotEmpty &&
                  tokenStr == _lastLocalDoneToken) {
                return;
              }
              _lastLocalDoneToken =
                  (tokenStr != null && tokenStr.isNotEmpty) ? tokenStr : null;
              _onLocalChunkDone();
            } else if (type == 'error') {
              final msg = (event['message'] ?? '').toString();
              _onLocalChunkError(msg);
            }
          }
        });
      } catch (_) {}
    }
  }

  void _onTtsConfigChanged() {
    final tp = _tp;
    if (tp == null) return;
    final engineChanged = _lastEngine != tp.readAloudEngine;
    final voiceChanged = _lastVoiceType != tp.ttsVoiceType;
    final speedChanged = _lastTtsSpeed != tp.ttsSpeed;
    final localSpeedChanged = _lastLocalTtsSpeed != tp.localTtsSpeed;
    final applyToReaderChanged = _lastApplyToReader != tp.applyToReader;
    final displayModeChanged = _lastDisplayMode != tp.config.displayMode;
    final fromChanged = _lastSourceLang != tp.config.sourceLang;
    final toChanged = _lastTargetLang != tp.config.targetLang;
    final cacheChanged = _lastCacheRevision != tp.cacheRevision;
    final aiReadAloudEnabledChanged =
        _lastAiReadAloudEnabled != tp.aiReadAloudEnabled;
    final pointsBalanceChanged = _lastPointsBalance != tp.pointsBalance;
    final personalKeysChanged =
        _lastUsingPersonalTencentKeys != tp.usingPersonalTencentKeys;

    final changed = engineChanged ||
        voiceChanged ||
        speedChanged ||
        localSpeedChanged ||
        applyToReaderChanged ||
        displayModeChanged ||
        fromChanged ||
        toChanged ||
        aiReadAloudEnabledChanged ||
        pointsBalanceChanged ||
        personalKeysChanged;
    if (!changed && !cacheChanged) return;

    _lastEngine = tp.readAloudEngine;
    _lastVoiceType = tp.ttsVoiceType;
    _lastTtsSpeed = tp.ttsSpeed;
    _lastLocalTtsSpeed = tp.localTtsSpeed;
    _lastApplyToReader = tp.applyToReader;
    _lastDisplayMode = tp.config.displayMode;
    _lastSourceLang = tp.config.sourceLang;
    _lastTargetLang = tp.config.targetLang;
    _lastCacheRevision = tp.cacheRevision;
    _lastAiReadAloudEnabled = tp.aiReadAloudEnabled;
    _lastPointsBalance = tp.pointsBalance;
    _lastUsingPersonalTencentKeys = tp.usingPersonalTencentKeys;

    if (!_playing && !_preparing && !_paused) return;

    if (tp.readAloudEngine == ReadAloudEngine.online &&
        !tp.usingPersonalTencentKeys &&
        tp.pointsBalance <= 0) {
      tp.onError?.call('在线朗读积分已用尽，已停止朗读与预取');
      unawaited(stop(keepResume: true, endedNaturally: false, stopEngine: false));
      return;
    }

    if (!tp.aiReadAloudEnabled) {
      unawaited(stop(keepResume: true, endedNaturally: false, stopEngine: false));
      return;
    }

    if (cacheChanged && !changed) {
      if (!tp.applyToReader) return;
      if (tp.config.displayMode != TranslationDisplayMode.translationOnly &&
          tp.config.displayMode != TranslationDisplayMode.bilingual) {
        return;
      }
      _queueDirty = true;
      if (_paused && !_playing && !_preparing) {
        if (_queue.isEmpty || _queuePos < 0 || _queuePos >= _queue.length) {
          return;
        }
        if (_bookId == null || _chapterIndex == null || _paragraphs.isEmpty) {
          return;
        }
        _queueDirty = false;
        final entry = _queue[_queuePos];
        unawaited(seekToChapterPosition(
          bookId: _bookId!,
          chapterIndex: _chapterIndex!,
          paragraphs: _paragraphs,
          paragraphIndex: entry.paragraphIndex,
          chunkIndexInParagraph: entry.chunkIndexInParagraph,
          keepPaused: true,
        ));
      }
      return;
    }

    if (_paused && !_playing && !_preparing) {
      final pos = _position;
      if (pos == null) return;
      if (_bookId == null || _chapterIndex == null || _paragraphs.isEmpty) {
        return;
      }
      unawaited(seekToChapterPosition(
        bookId: pos.bookId,
        chapterIndex: pos.chapterIndex,
        paragraphs: _paragraphs,
        paragraphIndex: pos.paragraphIndex,
        chunkIndexInParagraph: pos.chunkIndexInParagraph,
        keepPaused: true,
      ));
      return;
    }
    unawaited(restartFromCurrentPosition());
  }

  void _restoreLastPosition() {
    final raw = _prefs?.getString('read_aloud_last_position');
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      _position = ReadAloudPosition.tryParse(decoded);
      if (_position != null) {
        _bookId = _position!.bookId;
        _chapterIndex = _position!.chapterIndex;
      }
    } catch (_) {}
  }

  Future<void> _persistPosition(ReadAloudPosition p) async {
    _position = p;
    try {
      await _prefs?.setString(
          'read_aloud_last_position', jsonEncode(p.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  void attachChapter({
    required String bookId,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
  }) {
    _bookId = bookId;
    _chapterIndex = chapterIndex;
    _paragraphs = List<ReaderParagraph>.unmodifiable(paragraphs);
  }

  bool get isActiveForBook =>
      _bookId != null && _chapterIndex != null && _queue.isNotEmpty;

  bool get atQueueStart => _queue.isEmpty || _queuePos <= 0;

  bool get atQueueEnd =>
      _queue.isEmpty || _queuePos >= (_queue.length - 1).clamp(0, 999999);

  Future<bool> prepare({
    required String bookId,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
    int? startParagraphIndex,
  }) async {
    await _init();
    _endedNaturally = false;
    attachChapter(
        bookId: bookId, chapterIndex: chapterIndex, paragraphs: paragraphs);
    final tp = _tp;
    if (tp == null) return false;
    if (!tp.aiReadAloudEnabled) return false;
    if (paragraphs.isEmpty) return false;

    final startPara = (startParagraphIndex ?? 0)
        .clamp(0, paragraphs.isEmpty ? 0 : paragraphs.length - 1);
    final queue = _buildQueue(paragraphs: paragraphs, startParagraphIndex: 0);
    if (queue.isEmpty) return false;

    _queue = queue;
    _queuePos = _findQueueStartPos(
      queue: queue,
      paragraphIndex: startPara,
      chunkIndexInParagraph: 0,
    );
    _paused = true;
    _playing = false;
    _preparing = false;
    await _persistCurrentQueuePosition();
    notifyListeners();
    return true;
  }

  Future<bool> startOrResume({
    required String bookId,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
    int? startParagraphIndex,
  }) async {
    await _init();
    _endedNaturally = false;
    attachChapter(
        bookId: bookId, chapterIndex: chapterIndex, paragraphs: paragraphs);

    final tp = _tp;
    if (tp == null) return false;
    if (!tp.aiReadAloudEnabled) return false;

    if (_playing && _bookId == bookId && _chapterIndex == chapterIndex) {
      return true;
    }

    if (_paused && _bookId == bookId && _chapterIndex == chapterIndex) {
      await resume();
      return true;
    }

    final savedPosition = _position;
    int startPara = startParagraphIndex ??
        ((savedPosition != null &&
                savedPosition.bookId == bookId &&
                savedPosition.chapterIndex == chapterIndex)
            ? savedPosition.paragraphIndex
            : 0);
    startPara =
        startPara.clamp(0, paragraphs.isEmpty ? 0 : paragraphs.length - 1);

    final resumeChunkIndex = (startParagraphIndex == null &&
            savedPosition != null &&
            savedPosition.bookId == bookId &&
            savedPosition.chapterIndex == chapterIndex &&
            savedPosition.paragraphIndex == startPara)
        ? savedPosition.chunkIndexInParagraph
        : 0;

    final queue = _buildQueue(paragraphs: paragraphs, startParagraphIndex: 0);
    if (queue.isEmpty) return false;

    final session = ++_session;
    _queue = queue;
    _queuePos = _findQueueStartPos(
      queue: queue,
      paragraphIndex: startPara,
      chunkIndexInParagraph: resumeChunkIndex,
    );
    _paused = false;
    _playing = true;
    _preparing = true;
    notifyListeners();

    await _playCurrentChunk(session);
    return true;
  }

  Future<void> pause() async {
    if (!_playing && !_preparing) return;
    final tp = _tp;
    if (tp == null) return;
    _stopLocalSpeakingPoll();
    if (tp.readAloudEngine == ReadAloudEngine.online) {
      try {
        await _player.pause();
      } catch (_) {}
    } else {
      try {
        if (kIsWeb) {
          await _webSpeechTts.stop();
        } else {
          await _localTtsChannel.invokeMethod('stop');
        }
      } catch (_) {}
    }
    _playing = false;
    _preparing = false;
    _paused = true;
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_paused) return;
    if (_queue.isEmpty) return;
    _endedNaturally = false;
    final session = ++_session;
    _paused = false;
    _playing = true;
    _preparing = true;
    notifyListeners();
    await _playCurrentChunk(session);
  }

  Future<void> skipToPreviousChunk() async {
    await stepToPreviousChunk(keepPaused: false);
  }

  Future<void> skipToNextChunk() async {
    await stepToNextChunk(keepPaused: false);
  }

  Future<bool> stepToPreviousChunk({required bool keepPaused}) async {
    if (_queue.isEmpty) return false;
    final prev = (_queuePos - 1).clamp(0, _queue.length - 1);
    if (prev == _queuePos) return false;
    await _cancelCurrentOutput();
    _queuePos = prev;
    _endedNaturally = false;
    if (keepPaused) {
      await _persistCurrentQueuePosition();
      _paused = true;
      _playing = false;
      _preparing = false;
      notifyListeners();
      return true;
    }
    final session = ++_session;
    _paused = false;
    _playing = true;
    _preparing = true;
    notifyListeners();
    await _playCurrentChunk(session);
    return true;
  }

  Future<bool> stepToNextChunk({required bool keepPaused}) async {
    if (_queue.isEmpty) return false;
    final next = (_queuePos + 1).clamp(0, _queue.length - 1);
    if (next == _queuePos) return false;
    await _cancelCurrentOutput();
    _queuePos = next;
    _endedNaturally = false;
    if (keepPaused) {
      await _persistCurrentQueuePosition();
      _paused = true;
      _playing = false;
      _preparing = false;
      notifyListeners();
      return true;
    }
    final session = ++_session;
    _paused = false;
    _playing = true;
    _preparing = true;
    notifyListeners();
    await _playCurrentChunk(session);
    return true;
  }

  Future<bool> seekToChapterStart({
    required String bookId,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
    required bool keepPaused,
  }) async {
    return seekToChapterPosition(
      bookId: bookId,
      chapterIndex: chapterIndex,
      paragraphs: paragraphs,
      paragraphIndex: 0,
      chunkIndexInParagraph: 0,
      keepPaused: keepPaused,
    );
  }

  Future<bool> seekToChapterEnd({
    required String bookId,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
    required bool keepPaused,
  }) async {
    await _init();
    _endedNaturally = false;
    attachChapter(
        bookId: bookId, chapterIndex: chapterIndex, paragraphs: paragraphs);
    final tp = _tp;
    if (tp == null) return false;
    if (!tp.aiReadAloudEnabled) return false;

    final queue = _buildQueue(paragraphs: paragraphs, startParagraphIndex: 0);
    if (queue.isEmpty) return false;
    await _cancelCurrentOutput();
    _queue = queue;
    _queuePos = queue.length - 1;
    if (keepPaused) {
      await _persistCurrentQueuePosition();
      _paused = true;
      _playing = false;
      _preparing = false;
      notifyListeners();
      return true;
    }
    final session = ++_session;
    _paused = false;
    _playing = true;
    _preparing = true;
    notifyListeners();
    await _playCurrentChunk(session);
    return true;
  }

  Future<bool> seekToChapterPosition({
    required String bookId,
    required int chapterIndex,
    required List<ReaderParagraph> paragraphs,
    required int paragraphIndex,
    required int chunkIndexInParagraph,
    required bool keepPaused,
  }) async {
    await _init();
    _endedNaturally = false;
    attachChapter(
        bookId: bookId, chapterIndex: chapterIndex, paragraphs: paragraphs);
    final tp = _tp;
    if (tp == null) return false;
    if (!tp.aiReadAloudEnabled) return false;

    final queue = _buildQueue(paragraphs: paragraphs, startParagraphIndex: 0);
    if (queue.isEmpty) return false;
    await _cancelCurrentOutput();
    _queue = queue;
    _queuePos = _findQueueStartPos(
      queue: queue,
      paragraphIndex: paragraphIndex,
      chunkIndexInParagraph: chunkIndexInParagraph,
    );
    if (keepPaused) {
      await _persistCurrentQueuePosition();
      _paused = true;
      _playing = false;
      _preparing = false;
      notifyListeners();
      return true;
    }
    final session = ++_session;
    _paused = false;
    _playing = true;
    _preparing = true;
    notifyListeners();
    await _playCurrentChunk(session);
    return true;
  }

  Future<void> seekBack15Seconds({bool keepPaused = false}) async {
    await stepToPreviousChunk(keepPaused: keepPaused);
  }

  Future<void> seekForward15Seconds({bool keepPaused = false}) async {
    await stepToNextChunk(keepPaused: keepPaused);
  }

  Future<void> _persistCurrentQueuePosition() async {
    if (_queue.isEmpty) return;
    if (_queuePos < 0 || _queuePos >= _queue.length) return;
    final entry = _queue[_queuePos];
    final para = _paragraphs.cast<ReaderParagraph?>().firstWhere(
          (p) => p?.index == entry.paragraphIndex,
          orElse: () => null,
        );
    int highlightOffsetInParagraph = 0;
    if (para != null) {
      final h = entry.highlightText.trim();
      if (h.isNotEmpty) {
        final idx = para.text.indexOf(h);
        if (idx >= 0) highlightOffsetInParagraph = idx;
      }
    }
    final chapterTextOffset = para == null
        ? 0
        : (para.start + highlightOffsetInParagraph).clamp(0, para.end);
    await _persistPosition(
      ReadAloudPosition(
        bookId: _bookId ?? '',
        chapterIndex: _chapterIndex ?? 0,
        paragraphIndex: entry.paragraphIndex,
        chunkIndexInParagraph: entry.chunkIndexInParagraph,
        highlightOffsetInParagraph: highlightOffsetInParagraph,
        chapterTextOffset: chapterTextOffset,
        highlightText: entry.highlightText,
      ),
    );
  }

  Future<void> _cancelCurrentOutput() async {
    _endedNaturally = false;
    _onlineTransitioning = true;
    _stopLocalSpeakingPoll();
    try {
      if (kIsWeb) {
        await _webSpeechTts.stop();
      } else {
        await _localTtsChannel.invokeMethod('stop');
      }
    } catch (_) {}
    try {
      await _player.stop();
    } catch (_) {}
    await _cleanupTempFile();
    _session++;
  }

  Future<void> stop({
    bool keepResume = true,
    bool endedNaturally = false,
    bool stopEngine = true,
  }) async {
    await _init();
    _session++;
    _stopLocalSpeakingPoll();
    _paused = false;
    _playing = false;
    _preparing = false;
    _endedNaturally = endedNaturally;
    _onlineAudioInFlight.clear();
    if (!keepResume) {
      _position = null;
      try {
        await _prefs?.remove('read_aloud_last_position');
      } catch (_) {}
    }
    notifyListeners();
    if (stopEngine) {
      try {
        if (kIsWeb) {
          await _webSpeechTts.stop();
        } else {
          await _localTtsChannel.invokeMethod('stop');
        }
      } catch (_) {}
      try {
        await _player.stop();
      } catch (_) {}
    }
    await _cleanupTempFile();
  }

  Future<void> _cleanupTempFile() async {
    final path = _tempFilePath;
    if (path == null || path.isEmpty) return;
    _tempFilePath = null;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> restartFromCurrentPosition() async {
    if (_bookId == null || _chapterIndex == null) return;
    if (_paragraphs.isEmpty) return;
    final pos = _position;
    if (pos == null) return;
    final wasPlaying = _playing || _preparing;
    await stop(keepResume: true);
    if (!wasPlaying) return;
    await startOrResume(
      bookId: _bookId!,
      chapterIndex: _chapterIndex!,
      paragraphs: _paragraphs,
      startParagraphIndex: pos.paragraphIndex,
    );
  }

  List<_ReadAloudChunk> _buildQueue({
    required List<ReaderParagraph> paragraphs,
    required int startParagraphIndex,
  }) {
    final tp = _tp;
    if (tp == null) return const [];
    if (paragraphs.isEmpty) return const [];
    final out = <_ReadAloudChunk>[];
    for (int i = startParagraphIndex; i < paragraphs.length; i++) {
      final p = paragraphs[i];
      final speechBase = _speechTextForParagraph(
        provider: tp,
        paragraphText: p.text,
      );
      if (speechBase.trim().isEmpty) continue;
      final segments = _splitTtsSegments(speechBase);
      for (int seg = 0; seg < segments.length; seg++) {
        final s = segments[seg];
        final speech = _normalizeSpeechText(s.speech).trim();
        if (speech.isEmpty) continue;
        final highlight = s.highlight.trim();
        out.add(
          _ReadAloudChunk(
            paragraphIndex: p.index,
            chunkIndexInParagraph: seg,
            speechText: speech,
            highlightText: highlight.isEmpty ? speech : highlight,
          ),
        );
      }
    }
    return out;
  }

  int _findQueueStartPos({
    required List<_ReadAloudChunk> queue,
    required int paragraphIndex,
    required int chunkIndexInParagraph,
  }) {
    final idx = queue.indexWhere((e) =>
        e.paragraphIndex == paragraphIndex &&
        e.chunkIndexInParagraph == chunkIndexInParagraph);
    if (idx >= 0) return idx;
    final paraFirst =
        queue.indexWhere((e) => e.paragraphIndex == paragraphIndex);
    if (paraFirst >= 0) return paraFirst;
    return 0;
  }

  Future<void> _playCurrentChunk(int session) async {
    if (session != _session) return;
    if (_queuePos < 0 || _queuePos >= _queue.length) {
      await stop(keepResume: true);
      return;
    }
    final tp = _tp;
    if (tp == null) return;

    if (_queueDirty) {
      final old = _queue[_queuePos];
      final rebuilt =
          _buildQueue(paragraphs: _paragraphs, startParagraphIndex: 0);
      if (rebuilt.isEmpty) {
        _queueDirty = false;
        await stop(keepResume: true);
        return;
      }
      _queue = rebuilt;
      _queuePos = _findQueueStartPos(
        queue: rebuilt,
        paragraphIndex: old.paragraphIndex,
        chunkIndexInParagraph: old.chunkIndexInParagraph,
      );
      _queueDirty = false;
      if (session != _session) return;
    }

    final entry = _queue[_queuePos];
    final para = _paragraphs.cast<ReaderParagraph?>().firstWhere(
          (p) => p?.index == entry.paragraphIndex,
          orElse: () => null,
        );
    int highlightOffsetInParagraph = 0;
    if (para != null) {
      final h = entry.highlightText.trim();
      if (h.isNotEmpty) {
        final idx = para.text.indexOf(h);
        if (idx >= 0) highlightOffsetInParagraph = idx;
      }
    }
    final chapterTextOffset = para == null
        ? 0
        : (para.start + highlightOffsetInParagraph).clamp(0, para.end);
    final position = ReadAloudPosition(
      bookId: _bookId ?? '',
      chapterIndex: _chapterIndex ?? 0,
      paragraphIndex: entry.paragraphIndex,
      chunkIndexInParagraph: entry.chunkIndexInParagraph,
      highlightOffsetInParagraph: highlightOffsetInParagraph,
      chapterTextOffset: chapterTextOffset,
      highlightText: entry.highlightText,
    );

    _preparing = true;
    notifyListeners();

    try {
      if (tp.readAloudEngine == ReadAloudEngine.online) {
        if (!tp.usingPersonalTencentKeys) {
          final need = entry.speechText.trim().length * 10;
          if (tp.pointsBalance <= need) {
            tp.onError?.call('积分不足（需>$need），已停止朗读与预取');
            await stop(
                keepResume: true, endedNaturally: false, stopEngine: false);
            return;
          }
        }
        if (!tp.usingPersonalTencentKeys && tp.pointsBalance <= 0) {
          tp.onError?.call('在线朗读积分已用尽，已停止朗读与预取');
          await stop(keepResume: true, endedNaturally: false, stopEngine: false);
          return;
        }
        await _persistPosition(position);
        final bytes = await _getOnlineTtsBytesDedup(
          text: entry.speechText,
          voiceType: tp.ttsVoiceType,
          speed: tp.ttsSpeed,
        );
        if (session != _session) return;
        _preparing = false;
        notifyListeners();
        await _cleanupTempFile();
        if (kIsWeb) {
          await _player.play(BytesSource(bytes));
        } else {
          final dir = await getTemporaryDirectory();
          final file = File(
              '${dir.path}/tts_${session}_${DateTime.now().microsecondsSinceEpoch}.mp3');
          await file.writeAsBytes(bytes, flush: true);
          _tempFilePath = file.path;
          await _player.play(DeviceFileSource(file.path));
        }
        _onlineTransitioning = false;
        _prefetchOnlineAhead(
          session: session,
          startIndex: _queuePos + 1,
          voiceType: tp.ttsVoiceType,
          speed: tp.ttsSpeed,
        );
        return;
      }

      if (kIsWeb) {
        await _persistPosition(position);
        if (!_webSpeechTts.supported) {
          throw UnsupportedError('当前浏览器不支持本地朗读');
        }
        String? lang;
        if (tp.applyToReader &&
            tp.config.displayMode == TranslationDisplayMode.translationOnly) {
          lang = tp.config.targetLang;
        } else {
          lang = tp.config.sourceLang;
        }
        if (lang.trim().isEmpty) lang = null;
        await _webSpeechTts.speak(
          text: entry.speechText,
          rate: tp.localTtsSpeed,
          session: session,
          onDone: (s) {
            if (s != _session) return;
            _onLocalChunkDone();
          },
          onError: (s, msg) {
            if (s != _session) return;
            _onLocalChunkError(msg);
          },
        );
        if (session != _session) return;
        _preparing = false;
        notifyListeners();
        return;
      }

      String? lang;
      if (tp.applyToReader &&
          tp.config.displayMode == TranslationDisplayMode.translationOnly) {
        lang = tp.config.targetLang;
      } else {
        lang = tp.config.sourceLang;
      }
      if (lang.trim().isEmpty) lang = null;

      await _persistPosition(position);
      _currentLocalToken =
          '${session}_${_queuePos}_${DateTime.now().microsecondsSinceEpoch}';
      final args = {
        'text': entry.speechText,
        'rate': tp.localTtsSpeed,
        'session': session,
        'lang': lang,
        'token': _currentLocalToken,
      };
      await _localTtsChannel.invokeMethod('speak', args);
      if (session != _session) return;
      _preparing = false;
      notifyListeners();
      _startLocalSpeakingPoll(
        session: session,
        token: _currentLocalToken,
      );
    } catch (e) {
      if (session != _session) return;
      await stop(keepResume: true);
      rethrow;
    }
  }

  void _prefetchOnlineAhead({
    required int session,
    required int startIndex,
    required int voiceType,
    required double speed,
  }) {
    if (session != _session) return;
    if (_queue.isEmpty) return;
    final tp = _tp;
    if (tp == null) return;
    if (!tp.usingPersonalTencentKeys && tp.pointsBalance <= 0) return;
    final int end =
        (startIndex + _onlinePrefetchDistance).clamp(0, _queue.length);
    for (int i = startIndex; i < end; i++) {
      final text = _queue[i].speechText;
      if (!tp.usingPersonalTencentKeys) {
        final need = text.trim().length * 10;
        if (tp.pointsBalance <= need) break;
      }
      unawaited(_getOnlineTtsBytesDedup(
          text: text, voiceType: voiceType, speed: speed));
    }
  }

  void _onOnlineChunkDone() {
    if (!_playing) return;
    final tp = _tp;
    if (tp == null) return;
    if (tp.readAloudEngine != ReadAloudEngine.online) return;
    if (_onlineTransitioning) return;

    final session = _session;
    final next = _queuePos + 1;
    if (next >= _queue.length) {
      unawaited(
          stop(keepResume: true, endedNaturally: true, stopEngine: false));
      return;
    }
    _queuePos = next;
    unawaited(_playCurrentChunk(session));
  }

  void _onLocalChunkDone() {
    if (!_playing) return;
    final tp = _tp;
    if (tp == null) return;
    if (tp.readAloudEngine != ReadAloudEngine.local) return;
    _stopLocalSpeakingPoll();

    final lastAt = _lastLocalDoneAt;
    if (_lastLocalDoneSession == _session &&
        _lastLocalDoneQueuePos == _queuePos &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastLocalDoneSession = _session;
    _lastLocalDoneQueuePos = _queuePos;
    _lastLocalDoneAt = DateTime.now();

    final session = _session;
    final next = _queuePos + 1;
    if (next >= _queue.length) {
      unawaited(
          stop(keepResume: true, endedNaturally: true, stopEngine: false));
      return;
    }
    _queuePos = next;
    unawaited(_playCurrentChunk(session));
  }

  void _onLocalChunkError(String message) {
    if (!_playing) return;
    _stopLocalSpeakingPoll();
    unawaited(stop(keepResume: true, endedNaturally: false));
  }

  void _stopLocalSpeakingPoll() {
    _localSpeakingPollTimer?.cancel();
    _localSpeakingPollTimer = null;
    _localSpeakingPollInFlight = false;
    _localSpeakingPollSession = 0;
    _localSpeakingPollToken = null;
    _localSpeakingPollEverSpeaking = false;
    _localSpeakingPollStartedAt = null;
    _localSpeakingPollErrorCount = 0;
  }

  void _startLocalSpeakingPoll({
    required int session,
    required String? token,
  }) {
    if (kIsWeb) return;
    final tp = _tp;
    if (tp == null) return;
    if (tp.readAloudEngine != ReadAloudEngine.local) return;
    if (!_playing) return;

    _stopLocalSpeakingPoll();
    _localSpeakingPollSession = session;
    _localSpeakingPollToken = token;
    _localSpeakingPollEverSpeaking = false;
    _localSpeakingPollStartedAt = DateTime.now();
    _localSpeakingPollErrorCount = 0;

    _localSpeakingPollTimer =
        Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (!_playing) {
        _stopLocalSpeakingPoll();
        return;
      }
      final tp2 = _tp;
      if (tp2 == null || tp2.readAloudEngine != ReadAloudEngine.local) {
        _stopLocalSpeakingPoll();
        return;
      }
      if (_session != _localSpeakingPollSession) {
        _stopLocalSpeakingPoll();
        return;
      }
      final curToken = _currentLocalToken;
      final pollToken = _localSpeakingPollToken;
      if (pollToken != null &&
          pollToken.isNotEmpty &&
          curToken != null &&
          curToken.isNotEmpty &&
          pollToken != curToken) {
        _stopLocalSpeakingPoll();
        return;
      }
      if (_localSpeakingPollInFlight) return;
      _localSpeakingPollInFlight = true;
      bool speaking = false;
      try {
        final res = await _localTtsChannel.invokeMethod('isSpeaking');
        if (res is bool) speaking = res;
        if (res is num) speaking = res != 0;
      } catch (_) {
        _localSpeakingPollInFlight = false;
        _localSpeakingPollErrorCount++;
        if (_localSpeakingPollErrorCount >= 6) {
          _stopLocalSpeakingPoll();
        }
        return;
      }
      _localSpeakingPollInFlight = false;
      if (!_playing) return;

      if (speaking) {
        _localSpeakingPollEverSpeaking = true;
        return;
      }
      final startedAt = _localSpeakingPollStartedAt;
      if (_localSpeakingPollEverSpeaking) {
        _stopLocalSpeakingPoll();
        _onLocalChunkDone();
        return;
      }
      if (startedAt != null &&
          DateTime.now().difference(startedAt) > const Duration(seconds: 3)) {
        _stopLocalSpeakingPoll();
        _onLocalChunkDone();
      }
    });
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
    required String paragraphText,
  }) {
    final original = paragraphText.trim();
    if (!provider.applyToReader) return original;

    final trans = provider.getCachedTranslation(paragraphText);
    final normalizedTrans = (trans ?? '').trim();
    final hasTrans = normalizedTrans.isNotEmpty;

    final mode = provider.config.displayMode;
    if (mode == TranslationDisplayMode.translationOnly) {
      return hasTrans ? normalizedTrans : original;
    }
    if (mode == TranslationDisplayMode.bilingual) {
      if (!hasTrans) return original;
      if (original.isEmpty) return normalizedTrans;
      return '$original\n$normalizedTrans';
    }
    return original;
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
    final out = <_TtsSegment>[];
    final buffer = StringBuffer();
    int currentLen = 0;
    const int maxLen = 120;
    for (final part in parts) {
      final partLen = _ttsUnitCount(part);
      if (buffer.isNotEmpty && (currentLen + partLen > maxLen)) {
        final combined = buffer.toString();
        out.add(
          _TtsSegment(
            speech: _normalizeSpeechText(combined),
            highlight: combined.trim(),
          ),
        );
        buffer.clear();
        currentLen = 0;
      }
      buffer.write(part);
      currentLen += partLen;
    }
    if (buffer.isNotEmpty) {
      final combined = buffer.toString();
      out.add(
        _TtsSegment(
          speech: _normalizeSpeechText(combined),
          highlight: combined.trim(),
        ),
      );
    }
    return out;
  }

  String _onlineTtsCacheKey({
    required String text,
    required int voiceType,
    required double speed,
  }) {
    return 'v2|${text.hashCode}|$voiceType|${speed.toStringAsFixed(2)}';
  }

  Future<Uint8List> _getOnlineTtsBytes({
    required String text,
    required int voiceType,
    required double speed,
  }) async {
    final key =
        _onlineTtsCacheKey(text: text, voiceType: voiceType, speed: speed);
    final cached = _onlineAudioCache[key];
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
    _onlineAudioCache[key] = bytes;
    return bytes;
  }

  Future<Uint8List> _getOnlineTtsBytesDedup({
    required String text,
    required int voiceType,
    required double speed,
  }) {
    final key =
        _onlineTtsCacheKey(text: text, voiceType: voiceType, speed: speed);
    final cached = _onlineAudioCache[key];
    if (cached != null) return Future<Uint8List>.value(cached);
    final existing = _onlineAudioInFlight[key];
    if (existing != null) return existing;
    final fut =
        _getOnlineTtsBytes(text: text, voiceType: voiceType, speed: speed)
            .whenComplete(() {
      _onlineAudioInFlight.remove(key);
    });
    _onlineAudioInFlight[key] = fut;
    return fut;
  }

  @override
  void dispose() {
    _localTtsSub?.cancel();
    _playerCompleteSub?.cancel();
    try {
      _tp?.removeListener(_onTtsConfigChanged);
    } catch (_) {}
    unawaited(_player.dispose());
    super.dispose();
  }
}

class _ReadAloudChunk {
  final int paragraphIndex;
  final int chunkIndexInParagraph;
  final String speechText;
  final String highlightText;

  const _ReadAloudChunk({
    required this.paragraphIndex,
    required this.chunkIndexInParagraph,
    required this.speechText,
    required this.highlightText,
  });
}

class _TtsSegment {
  final String speech;
  final String highlight;

  const _TtsSegment({
    required this.speech,
    required this.highlight,
  });
}
