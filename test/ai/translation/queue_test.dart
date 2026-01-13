import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:airread/ai/translation/translation_queue.dart';

void main() {
  test('queue respects max concurrency under load', () async {
    final q = TranslationTaskQueue(maxConcurrent: 5);

    int active = 0;
    int maxSeen = 0;

    Future<void> work() async {
      active++;
      if (active > maxSeen) maxSeen = active;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
    }

    final futures = List.generate(120, (_) => q.submit(work));
    await Future.wait(futures);

    expect(maxSeen <= 5, isTrue);
  });
}
