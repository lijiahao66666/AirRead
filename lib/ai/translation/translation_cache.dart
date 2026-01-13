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

  /// In-memory cache for speed.
  final Map<String, TranslationCacheEntry> _mem = {};
  final List<String> _memOrder = [];

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
    required int glossaryVersion,
    required String text,
  }) {
    final input = '$engineId|$sourceLang|$targetLang|$glossaryVersion|$text';
    final hash = sha1.convert(utf8.encode(input)).toString();
    return '$_keyPrefix$hash';
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
      _memOrder.remove(key);
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
    _mem[key] = entry;
    _touchKey(key);
    while (_memOrder.length > memoryLimit) {
      final oldest = _memOrder.removeAt(0);
      _mem.remove(oldest);
    }
  }

  void _touchKey(String key) {
    _memOrder.remove(key);
    _memOrder.add(key);
  }
}
