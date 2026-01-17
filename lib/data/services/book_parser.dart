import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:epubx/epubx.dart';
import 'package:path/path.dart' as p;

class ParsedMetadata {
  final String title;
  final String author;
  final List<int>? coverBytes;

  ParsedMetadata({
    required this.title,
    required this.author,
    this.coverBytes,
  });
}

class BookParser {
  // Static entry point for compute isolate
  static Future<ParsedMetadata> parseBytesIsolated(Map<String, dynamic> args) async {
    final List<int> bytes = args['bytes'];
    final String filename = args['filename'];
    
    final extension = p.extension(filename).toLowerCase();

    switch (extension) {
      case '.epub':
        return _parseEpubBytes(bytes, filename);
      case '.txt':
        return _parseTxtBytes(bytes, filename);
      default:
        return ParsedMetadata(
          title: p.basenameWithoutExtension(filename),
          author: 'Unknown',
        );
    }
  }

  Future<ParsedMetadata> parseBytes(List<int> bytes, String filename) async {
    return parseBytesIsolated({'bytes': bytes, 'filename': filename});
  }

  static Future<ParsedMetadata> _parseEpubBytes(List<int> bytes, String filename) async {
    try {
      // Use openBook instead of readBook to avoid parsing all chapters/HTML
      final epubRef = await EpubReader.openBook(bytes);

      List<int>? coverBytes;
      try {
        coverBytes = await _extractCoverBytes(epubRef);
      } catch (e) {
        debugPrint('Error extracting cover bytes: $e');
      }

      return ParsedMetadata(
        title: epubRef.Title ?? p.basenameWithoutExtension(filename),
        author: epubRef.Author ?? 'Unknown',
        coverBytes: coverBytes,
      );
    } catch (e) {
      debugPrint('Error parsing EPUB bytes: $e');
      return ParsedMetadata(
        title: p.basenameWithoutExtension(filename),
        author: 'Unknown',
      );
    }
  }

  static Future<List<int>?> _extractCoverBytes(EpubBookRef ref) async {
    // 1. Try to find cover ID from metadata (standard way)
    String? coverId;
    final metaItems = ref.Schema?.Package?.Metadata?.MetaItems;
    if (metaItems != null) {
      for (var meta in metaItems) {
        if (meta.Name == 'cover') {
          coverId = meta.Content;
          break;
        }
      }
    }

    // 2. Resolve ID to Href
    if (coverId != null) {
      final manifestItems = ref.Schema?.Package?.Manifest?.Items;
      if (manifestItems != null) {
        for (var item in manifestItems) {
          if (item.Id == coverId) {
            return _readImageByHref(ref, item.Href);
          }
        }
      }
    }
    
    // 3. Fallback: Search for "cover" in images map keys
    final images = ref.Content?.Images;
    if (images != null) {
      for (var key in images.keys) {
        if (key.toLowerCase().contains('cover')) {
          return images[key]!.readContentAsBytes();
        }
      }
    }
    
    return null;
  }

  static Future<List<int>?> _readImageByHref(EpubBookRef ref, String? href) async {
    if (href == null) return null;
    final images = ref.Content?.Images;
    if (images == null) return null;
    
    // Exact match
    if (images.containsKey(href)) {
      return images[href]!.readContentAsBytes();
    }
    
    // Partial/Relative match (handle different path normalization)
    for (var key in images.keys) {
      if (key.endsWith(href) || href.endsWith(key)) {
        return images[key]!.readContentAsBytes();
      }
    }
    return null;
  }

  static Future<ParsedMetadata> _parseTxtBytes(List<int> bytes, String filename) async {
    // For TXT, we just use filename as title
    return ParsedMetadata(
      title: p.basenameWithoutExtension(filename),
      author: 'Unknown',
    );
  }

  // New Method: Read Full Book Content
  Future<EpubBookRef?> openBook(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      return await EpubReader.openBook(bytes);
    } catch (e) {
      debugPrint('Error opening book $filePath: $e');
      return null;
    }
  }

  // New Method: Read Full Book Content from Bytes (Web)
  Future<EpubBookRef?> openBookFromBytes(List<int> bytes) async {
    try {
      return await EpubReader.openBook(bytes);
    } catch (e) {
      debugPrint('Error opening book from bytes: $e');
      return null;
    }
  }

  Future<ParsedMetadata> parse(String filePath) async {
    final extension = p.extension(filePath).toLowerCase();

    switch (extension) {
      case '.epub':
        return _parseEpub(filePath);
      case '.txt':
        return _parseTxt(filePath);
      default:
        return ParsedMetadata(
          title: p.basenameWithoutExtension(filePath),
          author: 'Unknown',
        );
    }
  }

  Future<ParsedMetadata> _parseEpub(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      return _parseEpubBytes(bytes, filePath);
    } catch (e) {
      debugPrint('Error parsing EPUB: $e');
      return ParsedMetadata(
        title: p.basenameWithoutExtension(filePath),
        author: 'Unknown',
      );
    }
  }

  Future<ParsedMetadata> _parseTxt(String filePath) async {
    // For TXT, we just use filename as title
    return ParsedMetadata(
      title: p.basenameWithoutExtension(filePath),
      author: 'Unknown',
    );
  }
}
