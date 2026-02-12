import 'dart:io';

import 'package:airread/ai/illustration/illustration_service.dart';
import 'package:airread/ai/tencentcloud/tencent_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  IllustrationService _svc() {
    return IllustrationService(
      credentials: TencentCredentials.empty(),
      baseStoragePath: Directory.systemTemp.path,
    );
  }

  test('illustration returns empty when model outputs null', () async {
    final svc = _svc();
    final cards = await svc.analyzeScenesFromParagraphs(
      paragraphs: const ['这一段没有明显画面。'],
      chapterTitle: '第1章',
      maxScenes: 1,
      run: (prompt) async => 'null',
    );
    expect(cards.isEmpty, true);
  });

  test('illustration returns empty when JSON contains null fields', () async {
    final svc = _svc();
    final samples = <String>[
      '{"index": null, "title": "x", "prompt": null}',
      '{"index": 0, "title": null, "prompt": "室内，人物站立，柔光"}',
      '{"index": 0, "title": "x", "prompt": ""}',
      '{"index": "", "title": "x", "prompt": "室内，人物站立，柔光"}',
      '{"index": 0, "title": "", "prompt": "室内，人物站立，柔光"}',
      '{"index": 0, "title": "x", "prompt": "null"}',
    ];
    for (final raw in samples) {
      final cards = await svc.analyzeScenesFromParagraphs(
        paragraphs: const ['这一段没有明显画面。'],
        chapterTitle: '第1章',
        maxScenes: 1,
        run: (prompt) async => raw,
      );
      expect(cards.isEmpty, true, reason: raw);
    }
  });

  test('illustration returns one card for valid single-object JSON', () async {
    final svc = _svc();
    final cards = await svc.analyzeScenesFromParagraphs(
      paragraphs: const ['他推开门走进屋内。'],
      chapterTitle: '第1章',
      maxScenes: 1,
      run: (prompt) async =>
          '{"index": 0, "title": "入室", "prompt": "室内，人物推门进入，暖光，中景，生活气息，构图稳定"}',
    );
    expect(cards.length, 1);
    expect(cards.first.endParagraphIndex, 0);
    expect(cards.first.title.isNotEmpty, true);
    expect(cards.first.action.isNotEmpty, true);
  });
}

