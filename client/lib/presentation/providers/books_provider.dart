import 'package:flutter/foundation.dart';
import '../../data/models/book.dart';
import '../../data/database/database_helper.dart';
import '../../data/database/web_database_helper.dart';
import '../../data/services/book_importer.dart';
import 'translation_provider.dart';

import 'package:file_picker/file_picker.dart';

class BooksProvider extends ChangeNotifier {
  List<Book> _books = [];
  bool _isLoading = false;
  bool _isImporting = false;
  String _loadingMessage = '';
  String? _importError;

  // Animation Control
  List<String> _recentlyImportedIds = [];
  int _importBatchId = 0;
  int _booksLoadRequestId = 0;

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final WebDatabaseHelper _webDbHelper = WebDatabaseHelper.instance;
  final BookImporter _importer = BookImporter();

  // Selection Mode
  bool _isSelectionMode = false;
  final Set<String> _selectedBookIds = {};

  List<Book> get books => _books;
  bool get isLoading => _isLoading;
  bool get isImporting => _isImporting;
  String get loadingMessage => _loadingMessage;
  String? get importError => _importError;

  bool get isSelectionMode => _isSelectionMode;
  Set<String> get selectedBookIds => _selectedBookIds;

  List<String> get recentlyImportedIds => _recentlyImportedIds;
  int get importBatchId => _importBatchId;

  BooksProvider() {
    loadBooks();
  }

  void _invalidatePendingLoads() {
    _booksLoadRequestId++;
  }

  void toggleSelectionMode() {
    _isSelectionMode = !_isSelectionMode;
    if (!_isSelectionMode) {
      _selectedBookIds.clear();
    }
    notifyListeners();
  }

  void toggleBookSelection(String id) {
    if (_selectedBookIds.contains(id)) {
      _selectedBookIds.remove(id);
    } else {
      _selectedBookIds.add(id);
    }
    notifyListeners();
  }

  void selectAll() {
    if (_selectedBookIds.length == _books.length) {
      _selectedBookIds.clear();
    } else {
      _selectedBookIds.addAll(_books.map((b) => b.id));
    }
    notifyListeners();
  }

  Future<void> pinSelectedBooks() async {
    if (_selectedBookIds.isEmpty) return;

    _isLoading = true;
    notifyListeners();

    try {
      final now = DateTime.now();
      // Update import date to now (simple "Bump to top" logic)
      final idsToPin = _selectedBookIds.toList();

      for (var id in idsToPin) {
        final index = _books.indexWhere((b) => b.id == id);
        if (index != -1) {
          final updatedBook = _books[index].copyWith(importDate: now);

          if (kIsWeb) {
            await _webDbHelper
                .insertBook(updatedBook); // Insert replaces on conflict
          } else {
            await _dbHelper
                .insertBook(updatedBook); // Insert replaces on conflict
          }

          _books[index] = updatedBook;
        }
      }

      // Re-sort local list
      _books.sort((a, b) => b.importDate.compareTo(a.importDate));

      // Trigger animation
      _importBatchId++;
      _recentlyImportedIds = [];

      // Exit selection mode
      _isSelectionMode = false;
      _selectedBookIds.clear();
    } catch (e) {
      debugPrint('Error pinning books: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteSelectedBooks() async {
    if (_selectedBookIds.isEmpty) return;

    _isLoading = true; // Use loading state to prevent interaction
    notifyListeners();

    try {
      final idsToDelete = _selectedBookIds.toList();

      // Update Animation State to trigger re-layout/shift
      _importBatchId++;
      _recentlyImportedIds = []; // No new imports, just layout change

      for (var id in idsToDelete) {
        if (kIsWeb) {
          await _webDbHelper.deleteBook(id);
        } else {
          await _dbHelper.deleteBook(id);
        }
        try {
          await TranslationProvider.removeBookScopedPrefs(id);
        } catch (_) {}
      }

      _books.removeWhere((b) => idsToDelete.contains(b.id));

      // Exit selection mode
      _isSelectionMode = false;
      _selectedBookIds.clear();

      debugPrint('Deleted ${idsToDelete.length} books');
    } catch (e) {
      debugPrint('Error deleting books: $e');
      // Show error in UI?
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // New method for Web imports
  Future<void> importWebFiles(FilePickerResult result) async {
    _isImporting = true;
    _importError = null;
    notifyListeners();

    // Small delay to allow UI to render the loading state before heavy processing
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final newBooks =
          await _importer.processWebFiles(result, onProgress: (current, total) {
        _loadingMessage = '正在导入 $current / $total';
        notifyListeners();
      });

      if (newBooks.isNotEmpty) {
        _invalidatePendingLoads();
        _loadingMessage = '正在保存...';

        // Update Animation State
        _recentlyImportedIds = newBooks.map((b) => b.id).toList();
        _importBatchId++;

        notifyListeners();

        // Save to DB
        for (var book in newBooks) {
          await _webDbHelper.insertBook(book);
        }
        _books.insertAll(0, newBooks);
      }
    } catch (e) {
      debugPrint('Error importing web files: $e');
      _importError = '导入失败: $e';
    } finally {
      _isImporting = false;
      _loadingMessage = '';
      notifyListeners();
    }
  }

  Future<void> loadBooks() async {
    final requestId = ++_booksLoadRequestId;
    var applyResult = true;
    _isLoading = true;
    _recentlyImportedIds = []; // Clear animation state on reload
    notifyListeners();

    try {
      final loadedBooks = kIsWeb
          ? await _webDbHelper.getAllBooks()
          : await _dbHelper.getAllBooks();
      if (requestId != _booksLoadRequestId) {
        applyResult = false;
        return;
      }
      _books = loadedBooks;
    } catch (e) {
      debugPrint('Error loading books: $e');
    } finally {
      if (applyResult && requestId == _booksLoadRequestId) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 从文件路径导入书籍（用于「用灵阅打开」等场景）
  Future<Book?> importFromPath(String sourcePath) async {
    if (kIsWeb) return null;
    try {
      final book = await _importer.importFile(sourcePath);
      if (book != null) {
        _invalidatePendingLoads();
        _isLoading = false;
        _recentlyImportedIds = [book.id];
        _importBatchId++;
        _books.insert(0, book);
        notifyListeners();
      }
      return book;
    } catch (e) {
      debugPrint('Error importing from path $sourcePath: $e');
      return null;
    }
  }

  Future<void> importBooks() async {
    // 1. Pick files first (don't show overlay yet)
    final result = await _importer.pickFiles();

    // 2. If files picked, start import process (show overlay)
    if (result != null) {
      _isImporting = true;
      _importError = null;
      notifyListeners();

      try {
        final newBooks = await _importer.processPickedFiles(result);
        if (newBooks.isNotEmpty) {
          _invalidatePendingLoads();
          // Update Animation State
          _recentlyImportedIds = newBooks.map((b) => b.id).toList();
          _importBatchId++;

          _books.insertAll(0, newBooks); // Add to top
        }
      } catch (e) {
        debugPrint('Error importing books: $e');
        _importError = '导入失败: $e';
      } finally {
        _isImporting = false;
        notifyListeners();
      }
    }
  }

  Future<void> deleteBook(String id) async {
    if (kIsWeb) {
      await _webDbHelper.deleteBook(id);
    } else {
      await _dbHelper.deleteBook(id);
    }
    try {
      await TranslationProvider.removeBookScopedPrefs(id);
    } catch (_) {}
    _books.removeWhere((b) => b.id == id);
    notifyListeners();
  }

  Future<void> saveReadingSettingsToDb({
    required double fontSize,
    required double lineHeight,
  }) async {
    if (kIsWeb) return;
    await _dbHelper.saveReadingSettings(fontSize, lineHeight);
  }

  Future<void> saveReadingProgress({
    required String bookId,
    required int chapterIndex,
    required int pageInChapter,
    required double progress,
    double? overallProgress,
  }) async {
    final index = _books.indexWhere((b) => b.id == bookId);
    if (index == -1) return;

    final now = DateTime.now();
    final updated = _books[index].copyWith(
      readingChapter: chapterIndex,
      readingPage: pageInChapter,
      readingProgress: progress,
      percentage: overallProgress ?? _books[index].percentage,
      lastRead: now,
    );

    _books[index] = updated;

    try {
      if (kIsWeb) {
        await _webDbHelper.insertBook(updated);
      } else {
        await _dbHelper.updateBook(updated);
      }
    } catch (_) {}

    notifyListeners();
  }
}
