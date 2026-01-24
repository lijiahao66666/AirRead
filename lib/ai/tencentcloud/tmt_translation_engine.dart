import 'dart:collection';

import '../translation/engines/translation_engine.dart';
import 'embedded_public_hunyuan_credentials.dart';
import 'tencent_api_client.dart';
import 'tencent_credentials.dart';
import 'tencent_cloud_exception.dart';

class _Pacer {
  final Duration interval;
  DateTime _nextAllowed = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future<void>.value();

  _Pacer({required this.interval});

  Future<void> pace() {
    _tail = _tail.then((_) async {
      final now = DateTime.now();
      final waitUntil = _nextAllowed.isAfter(now) ? _nextAllowed : now;
      final wait = waitUntil.difference(now);
      if (!wait.isNegative && wait.inMilliseconds > 0) {
        await Future<void>.delayed(wait);
      }
      _nextAllowed = waitUntil.add(interval);
    });
    return _tail;
  }
}

class TmtTranslationEngine implements TranslationEngine {
  static const String _host = 'tmt.tencentcloudapi.com';
  static const String _service = 'tmt';
  static const String _version = '2018-03-21';
  static const String _region = 'ap-guangzhou';

  static final _Pacer _pacer =
      _Pacer(interval: const Duration(milliseconds: 220));

  final TencentApiClient _api;
  final TencentCredentials _credentials;

  TmtTranslationEngine({
    TencentApiClient? api,
    required TencentCredentials credentials,
  })  : _api = api ?? TencentApiClient(),
        _credentials = credentials;

  @override
  String get id => 'tencent_tmt';

  @override
  Future<String> translate({
    required String text,
    required String sourceLang,
    required String targetLang,
    required List<String> contextSources,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return '';

    final src = _normalizeSource(sourceLang);
    final tgt = _normalizeTarget(targetLang);

    final clipped =
        normalized.length <= 6000 ? normalized : normalized.substring(0, 6000);

    await _pacer.pace();

    final resp = await _api.postJson(
      host: _host,
      service: _service,
      action: 'TextTranslate',
      version: _version,
      region: _region,
      secretId: _credentials.secretId,
      secretKey: _credentials.secretKey,
      useScfProxy: !usingPersonalTencentKeys(),
      payload: <String, dynamic>{
        'SourceText': clipped,
        'Source': src,
        'Target': tgt,
        'ProjectId': 0,
      },
      timeout: const Duration(seconds: 20),
      maxRetries: 4,
    );

    final out = resp['TargetText']?.toString() ?? '';
    if (out.trim().isEmpty) {
      final err = resp['Error'];
      if (err is Map) {
        throw TencentCloudException(
          code: err['Code']?.toString() ?? 'TencentCloudError',
          message: err['Message']?.toString() ?? 'Unknown error',
        );
      }
      return '';
    }
    return out;
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String sourceLang,
    required String targetLang,
  }) async {
    if (texts.isEmpty) return const [];
    final results = List<String>.filled(texts.length, '');

    final queue = Queue<int>.of(List<int>.generate(texts.length, (i) => i));
    const int concurrency = 3;
    final workers = <Future<void>>[];

    for (int w = 0; w < concurrency; w++) {
      workers.add(Future<void>(() async {
        while (queue.isNotEmpty) {
          final i = queue.removeFirst();
          results[i] = await translate(
            text: texts[i],
            sourceLang: sourceLang,
            targetLang: targetLang,
            contextSources: const [],
          );
        }
      }));
    }

    await Future.wait(workers);
    return results;
  }

  String _normalizeSource(String lang) {
    final v = lang.trim();
    if (v.isEmpty) return 'auto';
    if (v == 'zh-Hans') return 'zh';
    if (v == 'zh-Hant') return 'zh-TW';
    if (v == 'zh-TR') return 'zh-TW';
    return v;
  }

  String _normalizeTarget(String lang) {
    final v = lang.trim();
    if (v.isEmpty) return 'en';
    if (v == 'zh-Hans') return 'zh';
    if (v == 'zh-Hant') return 'zh-TW';
    if (v == 'zh-TR') return 'zh-TW';
    return v;
  }
}
