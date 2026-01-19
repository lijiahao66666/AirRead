import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/book.dart';
import 'book_parser.dart';

class BookImporter {
  final Uuid _uuid = const Uuid();

  Future<List<Book>> processWebFiles(
    FilePickerResult result, {
    Function(int current, int total)? onProgress,
  }) async {
    List<Book> importedBooks = [];
    int total = result.files.length;

    for (var i = 0; i < total; i++) {
      var file = result.files[i];
      if (file.bytes == null) continue;

      await Future.delayed(Duration.zero);

      if (onProgress != null) {
        onProgress(i + 1, total);
      }

      final book = await _importFileWeb(file.bytes!, file.name);
      if (book != null) {
        importedBooks.add(book);
      }
    }
    return importedBooks;
  }

  Future<FilePickerResult?> pickFiles() async {
    return null;
  }

  Future<List<Book>> processPickedFiles(FilePickerResult result) async {
    throw UnsupportedError('processPickedFiles is not supported on Web');
  }

  Future<List<Book>> pickAndImportBooks() async {
    return [];
  }

  Future<Book?> importFile(String sourcePath) async {
    throw UnsupportedError('importFile is not supported on Web');
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
}
