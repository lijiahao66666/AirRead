import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/online_book.dart';

class PublicLibraryService {
  static const String _baseUrl = 'https://gutendex.com/books/';
  http.Client? _httpClient;

  PublicLibraryService() {
    _httpClient = http.Client();
  }

  /// Search for books using Gutendex API
  Future<List<OnlineBook>> search(String query) async {
    if (query.isEmpty) return [];

    try {
      final response = await _httpClient!.get(
        Uri.parse('$_baseUrl?search=${Uri.encodeComponent(query)}'),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final results = data['results'] as List? ?? [];
        return results.map((json) => OnlineBook.fromGutenberg(json)).toList();
      } else {
        throw Exception('搜索失败: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('PublicLibraryService Search Error: $e');
      rethrow;
    }
  }

  /// Download a book to a temporary file
  Future<File?> downloadBook(OnlineBook book, {
    required String format,
    Function(double progress)? onProgress,
  }) async {
    final url = book.downloadUrls[format];
    if (url == null) {
      debugPrint('No download URL for format: $format');
      return null;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      // Use book ID and timestamp to avoid conflicts
      final fileName = '${book.id}_${DateTime.now().millisecondsSinceEpoch}.$format';
      final savePath = p.join(tempDir.path, fileName);
      final file = File(savePath);

      final request = http.Request('GET', Uri.parse(url));
      final response = await _httpClient!.send(request).timeout(const Duration(minutes: 5));

      if (response.statusCode != 200) {
        throw Exception('下载失败: ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;

      final sink = file.openWrite();
      
      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }

      await sink.close();
      return file;
    } catch (e) {
      debugPrint('PublicLibraryService Download Error: $e');
      return null;
    }
  }

  Future<Uint8List?> downloadBytes(
    String url, {
    Function(double progress)? onProgress,
  }) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await _httpClient!.send(request).timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) {
        throw Exception('下载失败: ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;
      final chunks = <List<int>>[];

      await for (final chunk in response.stream) {
        chunks.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }

      final all = Uint8List(receivedBytes);
      int offset = 0;
      for (final c in chunks) {
        all.setRange(offset, offset + c.length, c);
        offset += c.length;
      }
      return all;
    } catch (e) {
      debugPrint('PublicLibraryService DownloadBytes Error: $e');
      return null;
    }
  }

  void dispose() {
    _httpClient?.close();
    _httpClient = null;
  }
}
