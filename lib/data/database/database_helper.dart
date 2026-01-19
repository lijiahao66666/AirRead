import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/book.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('airread.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(path,
        version: 4, onCreate: _createDB, onUpgrade: _upgradeDB);
  }

  Future _createDB(Database db, int version) async {
    const bookTable = '''
    CREATE TABLE books (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT,
      cover_path TEXT,
      file_path TEXT NOT NULL,
      format TEXT NOT NULL,
      total_pages INTEGER DEFAULT 0,
      import_date INTEGER NOT NULL,
      current_page INTEGER DEFAULT 0,
      percentage REAL DEFAULT 0.0,
      last_read INTEGER,
      reading_chapter INTEGER DEFAULT 0,
      reading_page INTEGER DEFAULT 0,
      reading_progress REAL DEFAULT 0.0
    )
    ''';

    const settingsTable = '''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT
    )
    ''';

    await db.execute(bookTable);
    await db.execute(settingsTable);
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      const settingsTable = '''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
      ''';
      await db.execute(settingsTable);
    }
    if (oldVersion < 3) {
      try {
        await db.execute(
            'ALTER TABLE books ADD COLUMN reading_chapter INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE books ADD COLUMN reading_page INTEGER DEFAULT 0');
      } catch (_) {}
    }
    if (oldVersion < 4) {
      try {
        await db.execute(
            'ALTER TABLE books ADD COLUMN reading_progress REAL DEFAULT 0.0');
      } catch (_) {}
    }
  }

  Future<void> insertBook(Book book) async {
    final db = await instance.database;
    await db.insert(
      'books',
      book.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Book>> getAllBooks() async {
    final db = await instance.database;
    final result = await db.query('books', orderBy: 'import_date DESC');
    return result.map((json) => Book.fromMap(json)).toList();
  }

  Future<Book?> getBook(String id) async {
    final db = await instance.database;
    final maps = await db.query(
      'books',
      columns: null,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Book.fromMap(maps.first);
    } else {
      return null;
    }
  }

  Future<int> updateBook(Book book) async {
    final db = await instance.database;
    return db.update(
      'books',
      book.toMap(),
      where: 'id = ?',
      whereArgs: [book.id],
    );
  }

  Future<int> deleteBook(String id) async {
    final db = await instance.database;
    return await db.delete(
      'books',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveReadingSettings(double fontSize, double lineHeight) async {
    final db = await instance.database;
    await db.insert(
      'settings',
      {'key': 'fontSize', 'value': fontSize.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'settings',
      {'key': 'lineHeight', 'value': lineHeight.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
