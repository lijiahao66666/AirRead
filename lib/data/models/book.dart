import 'dart:typed_data';

class Book {
  final String id;
  final String title;
  final String author;
  final String coverPath;
  final String filePath;
  final String format;
  final int totalPages;
  final DateTime importDate;
  final int currentPage;
  final double percentage;
  final DateTime? lastRead;
  final int readingChapter;
  final int readingPage;
  final double readingProgress;
  final Uint8List? coverBytes;
  final Uint8List? fileBytes;

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.coverPath = '',
    required this.filePath,
    required this.format,
    this.totalPages = 0,
    required this.importDate,
    this.currentPage = 0,
    this.percentage = 0.0,
    this.lastRead,
    this.readingChapter = 0,
    this.readingPage = 0,
    this.readingProgress = 0.0,
    this.coverBytes,
    this.fileBytes,
  });

  // Convert to Map for Database
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'cover_path': coverPath,
      'file_path': filePath,
      'format': format,
      'total_pages': totalPages,
      'import_date': importDate.millisecondsSinceEpoch,
      'current_page': currentPage,
      'percentage': percentage,
      'last_read': lastRead?.millisecondsSinceEpoch,
      'reading_chapter': readingChapter,
      'reading_page': readingPage,
      'reading_progress': readingProgress,
    };
  }

  // Create from Map
  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'],
      title: map['title'],
      author: map['author'] ?? '',
      coverPath: map['cover_path'] ?? '',
      filePath: map['file_path'] ?? '',
      format: map['format'] ?? 'unknown',
      totalPages: map['total_pages'] ?? 0,
      importDate: DateTime.fromMillisecondsSinceEpoch(map['import_date']),
      currentPage: map['current_page'] ?? 0,
      percentage: map['percentage'] ?? 0.0,
      lastRead: map['last_read'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_read'])
          : null,
      readingChapter: map['reading_chapter'] ?? 0,
      readingPage: map['reading_page'] ?? 0,
      readingProgress: (map['reading_progress'] ?? 0.0) * 1.0,
    );
  }

  Book copyWith({
    String? id,
    String? title,
    String? author,
    String? coverPath,
    String? filePath,
    String? format,
    int? totalPages,
    DateTime? importDate,
    int? currentPage,
    double? percentage,
    DateTime? lastRead,
    int? readingChapter,
    int? readingPage,
    double? readingProgress,
    Uint8List? coverBytes,
    Uint8List? fileBytes,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      coverPath: coverPath ?? this.coverPath,
      filePath: filePath ?? this.filePath,
      format: format ?? this.format,
      totalPages: totalPages ?? this.totalPages,
      importDate: importDate ?? this.importDate,
      currentPage: currentPage ?? this.currentPage,
      percentage: percentage ?? this.percentage,
      lastRead: lastRead ?? this.lastRead,
      readingChapter: readingChapter ?? this.readingChapter,
      readingPage: readingPage ?? this.readingPage,
      readingProgress: readingProgress ?? this.readingProgress,
      coverBytes: coverBytes ?? this.coverBytes,
      fileBytes: fileBytes ?? this.fileBytes,
    );
  }
}
