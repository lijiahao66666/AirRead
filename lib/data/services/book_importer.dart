import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/book.dart';
import '../database/database_helper.dart';
import 'book_parser.dart';

class BookImporter {
  final BookParser _parser = BookParser();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final Uuid _uuid = const Uuid();

  // Process already picked files (for Web)
  Future<List<Book>> processWebFiles(FilePickerResult result, {Function(int current, int total)? onProgress}) async {
    List<Book> importedBooks = [];
    int total = result.files.length;
    
    for (var i = 0; i < total; i++) {
      var file = result.files[i];
      if (file.bytes != null) {
        // Yield to UI thread to keep animation smooth
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

  // 1. Pick Files Only
  Future<FilePickerResult?> pickFiles() async {
    try {
      if (kIsWeb) return null; // Use Web specific flow instead
      
      return await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub', 'txt', 'pdf'],
        allowMultiple: true,
      );
    } catch (e) {
      print('Error picking files: $e');
      return null;
    }
  }

  // 2. Process Picked Files (Mobile/Desktop)
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

  // Legacy method - kept if needed but we'll likely move to the split flow
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

      // Parse Metadata directly (avoid compute on Web to save data transfer time)
      // Since we optimized BookParser to use openBook (headers only), 
      // it's fast enough to run on main thread and avoids the expensive 
      // Structured Clone of the byte array to the worker.
      final metadata = await BookParser.parseBytesIsolated(
        {'bytes': bytes, 'filename': fileName}
      );

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
        fileBytes: Uint8List.fromList(bytes),
      );

      return newBook;
    } catch (e) {
      print('Error importing web file $fileName: $e');
      return null;
    }
  }

  Future<Book?> importFile(String sourcePath) async {
    try {
      // 1. Get Application Directory
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }

      // 2. Generate ID and Paths
      final String bookId = _uuid.v4();
      final String extension = p.extension(sourcePath).toLowerCase();
      final String fileName = '$bookId$extension';
      final String destPath = p.join(booksDir.path, fileName);

      // 3. Copy File
      await File(sourcePath).copy(destPath);

      // 4. Parse Metadata
      final metadata = await _parser.parse(destPath);

      // 5. Save Cover if exists
      String coverPath = '';
      if (metadata.coverBytes != null && metadata.coverBytes!.isNotEmpty) {
        final coversDir = Directory(p.join(appDir.path, 'covers'));
        if (!await coversDir.exists()) {
          await coversDir.create(recursive: true);
        }
        final coverFile = File(p.join(coversDir.path, '$bookId.png')); // Assume PNG or extract format?
        // Basic assumption for now. Epub covers are usually jpg/png.
        await coverFile.writeAsBytes(metadata.coverBytes!);
        coverPath = coverFile.path;
      }

      // 6. Create Book Object
      final newBook = Book(
        id: bookId,
        title: metadata.title,
        author: metadata.author,
        coverPath: coverPath,
        filePath: destPath,
        format: extension.replaceAll('.', ''), // 'epub'
        importDate: DateTime.now(),
        totalPages: 0, // Will be calculated on open
      );

      // 7. Save to DB
      await _dbHelper.insertBook(newBook);

      return newBook;
    } catch (e) {
      print('Error importing file $sourcePath: $e');
      return null;
    }
  }
}
