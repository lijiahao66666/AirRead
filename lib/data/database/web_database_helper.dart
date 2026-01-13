import 'package:idb_shim/idb_client.dart';
import 'package:idb_shim/idb_browser.dart';
import 'dart:typed_data';
import '../models/book.dart';

class WebDatabaseHelper {
  static final WebDatabaseHelper instance = WebDatabaseHelper._init();
  Database? _db;
  static const String _dbName = 'airread_web.db';
  static const String _storeName = 'books';

  WebDatabaseHelper._init();

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final idbFactory = getIdbFactory();
    if (idbFactory == null) {
      throw Exception('IndexedDB not supported');
    }
    
    return await idbFactory.open(
      _dbName,
      version: 1,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final db = event.database;
        // Create books store with 'id' as keyPath
        db.createObjectStore(_storeName, keyPath: 'id');
      },
    );
  }

  Future<void> insertBook(Book book) async {
    final db = await database;
    final txn = db.transaction(_storeName, idbModeReadWrite);
    final store = txn.objectStore(_storeName);
    
    final map = book.toMap();
    if (book.coverBytes != null) {
      map['cover_bytes'] = book.coverBytes;
    }
    if (book.fileBytes != null) {
      map['file_bytes'] = book.fileBytes;
    }
    
    await store.put(map);
    await txn.completed;
  }

  Future<List<Book>> getAllBooks() async {
    final db = await database;
    final txn = db.transaction(_storeName, idbModeReadOnly);
    final store = txn.objectStore(_storeName);
    
    final books = <Book>[];
    await store
        .openCursor(direction: idbDirectionNext)
        .listen((CursorWithValue cursor) {
      final map = cursor.value as Map;
      // Convert map keys to String just in case
      final stringMap = map.cast<String, dynamic>();
      
      Uint8List? coverBytes;
      if (stringMap['cover_bytes'] != null) {
        if (stringMap['cover_bytes'] is List) {
          coverBytes = Uint8List.fromList(
              (stringMap['cover_bytes'] as List).cast<int>());
        } else if (stringMap['cover_bytes'] is Uint8List) {
          coverBytes = stringMap['cover_bytes'] as Uint8List;
        }
      }
      Uint8List? fileBytes;
      if (stringMap['file_bytes'] != null) {
        if (stringMap['file_bytes'] is List) {
          fileBytes = Uint8List.fromList(
              (stringMap['file_bytes'] as List).cast<int>());
        } else if (stringMap['file_bytes'] is Uint8List) {
          fileBytes = stringMap['file_bytes'] as Uint8List;
        }
      }
      
      var book = Book.fromMap(stringMap);
      if (coverBytes != null || fileBytes != null) {
        book = book.copyWith(
          coverBytes: coverBytes ?? book.coverBytes,
          fileBytes: fileBytes ?? book.fileBytes,
        );
      }
      
      books.add(book);
      cursor.next();
    }).asFuture();
    
    await txn.completed;
    
    // Sort by import date descending
    books.sort((a, b) => b.importDate.compareTo(a.importDate));
    return books;
  }

  Future<void> deleteBook(String id) async {
    final db = await database;
    final txn = db.transaction(_storeName, idbModeReadWrite);
    final store = txn.objectStore(_storeName);
    await store.delete(id);
    await txn.completed;
  }
}
