import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/book.dart';
import '../database/database_helper.dart';
import 'book_parser.dart';

Future<Directory> getApplicationDocumentsDirectorySafe() async {
  try {
    return await getApplicationDocumentsDirectory();
  } catch (e) {
    throw Exception('无法获取应用文档目录: $e');
  }
}

class BookImporter {
  final BookParser _parser = BookParser();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final Uuid _uuid = const Uuid();

  Future<List<Book>> processWebFiles(
    FilePickerResult result, {
    Function(int current, int total)? onProgress,
  }) async {
    List<Book> importedBooks = [];
    int total = result.files.length;

    for (var i = 0; i < total; i++) {
      var file = result.files[i];
      if (file.bytes != null) {
        await Future.delayed(Duration.zero);
        if (onProgress != null) {
          onProgress(i + 1, total);
        }
        Book? book = await _importFileWeb(file.bytes!, file.name);
        if (book != null) {
          importedBooks.add(book);
        }
      }
    }
    return importedBooks;
  }

  Future<FilePickerResult?> pickFiles() async {
    try {
      if (kIsWeb) return null;

      return await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub', 'txt'],
        allowMultiple: true,
      );
    } catch (e) {
      debugPrint('Error picking files: $e');
      return null;
    }
  }

  Future<List<Book>> processPickedFiles(FilePickerResult result) async {
    List<Book> importedBooks = [];
    for (var file in result.files) {
      if (file.path != null) {
        Book? book = await importFile(file.path!);
        if (book != null) {
          importedBooks.add(book);
        }
      }
    }
    return importedBooks;
  }

  Future<List<Book>> pickAndImportBooks() async {
    final result = await pickFiles();
    if (result != null) {
      return processPickedFiles(result);
    }
    return [];
  }

  Future<Book?> _importFileWeb(List<int> bytes, String fileName) async {
    try {
      final String bookId = _uuid.v4();
      final String extension = p.extension(fileName).toLowerCase();

      final metadata = await BookParser.parseBytesIsolated(
          {'bytes': bytes, 'filename': fileName});

      final newBook = Book(
        id: bookId,
        title: metadata.title,
        author: metadata.author,
        coverPath: '',
        filePath: '',
        format: extension.replaceAll('.', ''),
        importDate: DateTime.now(),
        totalPages: 0,
        coverBytes: metadata.coverBytes != null
            ? Uint8List.fromList(metadata.coverBytes!)
            : null,
        fileBytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );

      return newBook;
    } catch (e) {
      debugPrint('Error importing web file $fileName: $e');
      return null;
    }
  }

  Future<Book?> importFile(String sourcePath) async {
    if (kIsWeb) {
      throw UnsupportedError(
          'importFile is not supported on Web. Use processWebFiles instead.');
    }

    try {
      final appDir = await getApplicationDocumentsDirectorySafe();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }

      final String bookId = _uuid.v4();
      final String extension = p.extension(sourcePath).toLowerCase();
      final String fileName = '$bookId$extension';
      final String destPath = p.join(booksDir.path, fileName);

      await File(sourcePath).copy(destPath);

      final metadata = await _parser.parse(destPath);

      String coverPath = '';
      if (metadata.coverBytes != null && metadata.coverBytes!.isNotEmpty) {
        final coversDir = Directory(p.join(appDir.path, 'covers'));
        if (!await coversDir.exists()) {
          await coversDir.create(recursive: true);
        }
        final coverFile = File(p.join(coversDir.path, '$bookId.png'));
        await coverFile.writeAsBytes(metadata.coverBytes!);
        coverPath = coverFile.path;
      }

      final newBook = Book(
        id: bookId,
        title: metadata.title,
        author: metadata.author,
        coverPath: coverPath,
        filePath: destPath,
        format: extension.replaceAll('.', ''),
        importDate: DateTime.now(),
        totalPages: 0,
      );

      await _dbHelper.insertBook(newBook);

      return newBook;
    } catch (e) {
      debugPrint('Error importing file $sourcePath: $e');
      return null;
    }
  }
}
