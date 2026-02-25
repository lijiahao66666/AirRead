import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TranslationCacheEntry {
  final String value;
  final DateTime createdAt;

  const TranslationCacheEntry({required this.value, required this.createdAt});

  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;

  Map<String, dynamic> toJson() => {
        'v': value,
        't': createdAt.millisecondsSinceEpoch,
      };

  static TranslationCacheEntry? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final v = (json['v'] ?? '').toString();
      final t = (json['t'] as num?)?.toInt();
      if (v.isEmpty || t == null) return null;
      return TranslationCacheEntry(
        value: v,
        createdAt: DateTime.fromMillisecondsSinceEpoch(t),
      );
    } catch (_) {
      return null;
    }
  }
}

class TranslationCache {
  static const _keyPrefix = 'tr_cache_';
  final Duration ttl;
  final int memoryLimit;

  SharedPreferences? _prefs;

  /// In-memory LRU cache. LinkedHashMap preserves insertion order;
  /// re-inserting a key moves it to end (most recently used).
  final LinkedHashMap<String, TranslationCacheEntry> _mem = LinkedHashMap();

  TranslationCache({
    required this.ttl,
    this.memoryLimit = 500,
  });

  Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String buildKey({
    required String engineId,
    required String sourceLang,
    required String targetLang,
    required String text,
  }) {
    final input = '$engineId|$sourceLang|$targetLang|$text';
    final hash = sha1.convert(utf8.encode(input)).toString();
    return '$_keyPrefix$hash';
  }

  String? getSynchronous(String key) {
    final mem = _mem[key];
    if (mem != null && !mem.isExpired(ttl)) {
      _touchKey(key);
      return mem.value;
    }
    return null;
  }

  Future<String?> get(String key) async {
    final mem = _mem[key];
    if (mem != null && !mem.isExpired(ttl)) {
      _touchKey(key);
      return mem.value;
    }

    await _ensurePrefs();
    final raw = _prefs!.getString(key);
    final entry = TranslationCacheEntry.fromJsonString(raw);
    if (entry == null) return null;
    if (entry.isExpired(ttl)) {
      await _prefs!.remove(key);
      _mem.remove(key);
      return null;
    }

    _memPut(key, entry);
    return entry.value;
  }

  Future<void> set(String key, String value) async {
    final entry = TranslationCacheEntry(value: value, createdAt: DateTime.now());
    _memPut(key, entry);
    await _ensurePrefs();
    await _prefs!.setString(key, jsonEncode(entry.toJson()));
  }

  void _memPut(String key, TranslationCacheEntry entry) {
    // Remove first so re-insert moves key to end (most recently used)
    _mem.remove(key);
    _mem[key] = entry;
    while (_mem.length > memoryLimit) {
      _mem.remove(_mem.keys.first);
    }
  }

  void _touchKey(String key) {
    final entry = _mem.remove(key);
    if (entry != null) {
      _mem[key] = entry;
    }
  }
}
