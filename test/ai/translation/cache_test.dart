import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airread/ai/translation/translation_cache.dart';

void main() {
  test('cache stores and expires entries', () async {
    SharedPreferences.setMockInitialValues({});

    final cache = TranslationCache(ttl: const Duration(milliseconds: 50));
    const key = 'tr_cache_test';

    await cache.set(key, 'hello');
    final v1 = await cache.get(key);
    expect(v1, 'hello');

    await Future<void>.delayed(const Duration(milliseconds: 80));
    final v2 = await cache.get(key);
    expect(v2, isNull);
  });
}
