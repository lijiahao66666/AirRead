import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/online_book.dart';
import '../../data/services/public_library_service.dart';
import '../../data/services/opds_library_service.dart';

enum LibraryOnlineSource {
  gutendex,
  opds,
}

class LibraryTestProvider extends ChangeNotifier {
  static const _kSource = 'library_test_source';
  static const _kOpdsUrl = 'library_test_opds_url';

  final PublicLibraryService _libraryService = PublicLibraryService();
  final OpdsLibraryService _opdsService = OpdsLibraryService();

  LibraryOnlineSource _source = LibraryOnlineSource.gutendex;
  String _opdsUrl = '';
  
  List<OnlineBook> _searchResults = [];
  bool _isSearching = false;
  String? _searchError;

  LibraryOnlineSource get source => _source;
  String get opdsUrl => _opdsUrl;
  List<OnlineBook> get searchResults => _searchResults;
  bool get isSearching => _isSearching;
  String? get searchError => _searchError;

  LibraryTestProvider() {
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSource) ?? 'gutendex';
    _source = raw == 'opds' ? LibraryOnlineSource.opds : LibraryOnlineSource.gutendex;
    _opdsUrl = prefs.getString(_kOpdsUrl) ?? '';
    notifyListeners();
  }

  Future<void> setSource(LibraryOnlineSource source) async {
    if (_source == source) return;
    _source = source;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSource, source == LibraryOnlineSource.opds ? 'opds' : 'gutendex');
  }

  Future<void> setOpdsUrl(String url) async {
    final next = url.trim();
    if (_opdsUrl == next) return;
    _opdsUrl = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOpdsUrl, next);
  }

  Future<void> search(String query) async {
    if (query.isEmpty) {
      _searchResults = [];
      notifyListeners();
      return;
    }

    _isSearching = true;
    _searchError = null;
    notifyListeners();

    try {
      if (_source == LibraryOnlineSource.gutendex) {
        _searchResults = await _libraryService.search(query);
      } else {
        _searchResults = await _opdsService.search(
          catalogOrTemplateUrl: _opdsUrl,
          query: query,
        );
      }
    } catch (e) {
      _searchError = '搜索出错: $e';
      debugPrint('Search Error: $e');
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _libraryService.dispose();
    _opdsService.dispose();
    super.dispose();
  }
}
