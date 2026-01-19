import 'dart:convert';
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
  static String _sanitizeTxt(String s) {
    var out = s.replaceAll('\u0000', '');
    if (out.isNotEmpty && out.codeUnitAt(0) == 0xFEFF) {
      out = out.substring(1);
    }
    return out;
  }

  static bool _hasUtf8Bom(List<int> bytes) {
    return bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
  }

  static bool _hasUtf16LeBom(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
  }

  static bool _hasUtf16BeBom(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF;
  }

  static bool _looksLikeUtf16LeNoBom(List<int> bytes) {
    final probeLen = bytes.length.clamp(0, 400);
    if (probeLen < 24) return false;
    int evenZeros = 0;
    int oddZeros = 0;
    int evenCount = 0;
    int oddCount = 0;
    for (int i = 0; i < probeLen; i++) {
      if ((i & 1) == 0) {
        evenCount++;
        if (bytes[i] == 0) evenZeros++;
      } else {
        oddCount++;
        if (bytes[i] == 0) oddZeros++;
      }
    }
    final evenRatio = evenCount == 0 ? 0.0 : evenZeros / evenCount;
    final oddRatio = oddCount == 0 ? 0.0 : oddZeros / oddCount;
    return oddRatio > 0.6 && evenRatio < 0.2;
  }

  static bool _looksLikeUtf16BeNoBom(List<int> bytes) {
    final probeLen = bytes.length.clamp(0, 400);
    if (probeLen < 24) return false;
    int evenZeros = 0;
    int oddZeros = 0;
    int evenCount = 0;
    int oddCount = 0;
    for (int i = 0; i < probeLen; i++) {
      if ((i & 1) == 0) {
        evenCount++;
        if (bytes[i] == 0) evenZeros++;
      } else {
        oddCount++;
        if (bytes[i] == 0) oddZeros++;
      }
    }
    final evenRatio = evenCount == 0 ? 0.0 : evenZeros / evenCount;
    final oddRatio = oddCount == 0 ? 0.0 : oddZeros / oddCount;
    return evenRatio > 0.6 && oddRatio < 0.2;
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final int len = bytes.length;
    final buffer = StringBuffer();
    int i = 0;
    if ((len & 1) == 1) {
      final safeLen = len - 1;
      while (i < safeLen) {
        final int lo = bytes[i];
        final int hi = bytes[i + 1];
        final int codeUnit = littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi);
        buffer.writeCharCode(codeUnit);
        i += 2;
      }
    } else {
      while (i < len) {
        final int lo = bytes[i];
        final int hi = bytes[i + 1];
        final int codeUnit = littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi);
        buffer.writeCharCode(codeUnit);
        i += 2;
      }
    }
    return buffer.toString();
  }

  static Future<String> _decodeTxtBytesChunked(List<int> bytes) async {
    const int chunkSize = 64 * 1024;
    final buffer = StringBuffer();
    if (_hasUtf16LeBom(bytes) ||
        _hasUtf16BeBom(bytes) ||
        _looksLikeUtf16LeNoBom(bytes) ||
        _looksLikeUtf16BeNoBom(bytes)) {
      final bool littleEndian =
          _hasUtf16LeBom(bytes) || _looksLikeUtf16LeNoBom(bytes);
      int offset = (_hasUtf16LeBom(bytes) || _hasUtf16BeBom(bytes)) ? 2 : 0;
      int chunks = 0;
      int? carry;
      while (offset < bytes.length) {
        final end = (offset + chunkSize).clamp(0, bytes.length);
        final chunk = bytes.sublist(offset, end);
        offset = end;

        int i = 0;
        if (carry != null) {
          if (chunk.isNotEmpty) {
            final int lo = carry;
            final int hi = chunk[0];
            final int codeUnit =
                littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi);
            buffer.writeCharCode(codeUnit);
            i = 1;
          }
          carry = null;
        }
        final safeLen = chunk.length - ((chunk.length - i) & 1);
        while (i + 1 < safeLen) {
          final int lo = chunk[i];
          final int hi = chunk[i + 1];
          final int codeUnit =
              littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi);
          buffer.writeCharCode(codeUnit);
          i += 2;
        }
        if (i < chunk.length) {
          carry = chunk[i];
        }

        chunks++;
        if (chunks % 6 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      return _sanitizeTxt(buffer.toString());
    }

    final sink = StringConversionSink.withCallback(buffer.write);
    const decoder = Utf8Decoder(allowMalformed: true);
    final byteSink = decoder.startChunkedConversion(sink);
    int offset = _hasUtf8Bom(bytes) ? 3 : 0;
    int chunks = 0;
    while (offset < bytes.length) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      byteSink.add(bytes.sublist(offset, end));
      offset = end;
      chunks++;
      if (chunks % 8 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    byteSink.close();
    sink.close();
    return _sanitizeTxt(buffer.toString());
  }

  static Future<ParsedMetadata> parseBytesIsolated(
      Map<String, dynamic> args) async {
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
          author: '',
        );
    }
  }

  Future<ParsedMetadata> parseBytes(List<int> bytes, String filename) async {
    return parseBytesIsolated({'bytes': bytes, 'filename': filename});
  }

  static Future<ParsedMetadata> _parseEpubBytes(
      List<int> bytes, String filename) async {
    try {
      final epubRef = await EpubReader.openBook(bytes);

      List<int>? coverBytes;
      try {
        coverBytes = await _extractCoverBytes(epubRef);
      } catch (e) {
        debugPrint('Error extracting cover bytes: $e');
      }

      return ParsedMetadata(
        title: epubRef.Title ?? p.basenameWithoutExtension(filename),
        author: epubRef.Author ?? '',
        coverBytes: coverBytes,
      );
    } catch (e) {
      debugPrint('Error parsing EPUB bytes: $e');
      return ParsedMetadata(
        title: p.basenameWithoutExtension(filename),
        author: '',
      );
    }
  }

  static String _decodeTxtBytes(List<int> bytes) {
    if (_hasUtf16LeBom(bytes)) {
      return _sanitizeTxt(_decodeUtf16(bytes.sublist(2), littleEndian: true));
    }
    if (_hasUtf16BeBom(bytes)) {
      return _sanitizeTxt(_decodeUtf16(bytes.sublist(2), littleEndian: false));
    }
    if (_hasUtf8Bom(bytes)) {
      return _sanitizeTxt(utf8.decode(bytes.sublist(3), allowMalformed: true));
    }
    if (_looksLikeUtf16LeNoBom(bytes)) {
      return _sanitizeTxt(_decodeUtf16(bytes, littleEndian: true));
    }
    if (_looksLikeUtf16BeNoBom(bytes)) {
      return _sanitizeTxt(_decodeUtf16(bytes, littleEndian: false));
    }
    return _sanitizeTxt(utf8.decode(bytes, allowMalformed: true));
  }

  static Future<ParsedMetadata> _parseTxtBytes(
      List<int> bytes, String filename) async {
    const int maxSampleBytes = 131072;
    final sample = bytes.length > maxSampleBytes
        ? bytes.sublist(0, maxSampleBytes)
        : bytes;
    final text = _decodeTxtBytes(sample);
    String title = p.basenameWithoutExtension(filename);
    String author = '';

    final lines = const LineSplitter().convert(text);
    final nonEmpty = <String>[];
    for (final l in lines) {
      final t = l.trim();
      if (t.isEmpty) continue;
      nonEmpty.add(t);
      if (nonEmpty.length >= 80) break;
    }

    if (nonEmpty.isNotEmpty) {
      final authorRe =
          RegExp(r'^(作者|Author)\s*[:：]\s*(.+)$', caseSensitive: false);
      final titleRe = RegExp(
        r'^(书名|书名：|Title|TITLE)\s*[:：]\s*(.+)$',
        caseSensitive: false,
      );
      final chapterRe = RegExp(
        r'^\s*(第.{1,12}[章节回卷篇]|(CHAPTER|Chapter)\s+\d+|序(章|言)|前言|楔子|引子)\b.*$',
        caseSensitive: false,
      );
      final junkRe = RegExp(
        r'(www\.|https?://|TXT|下载|电子书|全集|全本|完本|整理|校对|出品|版权|免责声明|更新|阅读|网盘|公众号|QQ群)',
        caseSensitive: false,
      );

      String? pickedTitle;

      for (final l in nonEmpty.take(25)) {
        final m = titleRe.firstMatch(l);
        if (m != null) {
          final t = (m.group(2) ?? '').trim();
          if (t.isNotEmpty && t.length <= 80 && !chapterRe.hasMatch(t)) {
            pickedTitle = t;
            break;
          }
        }
      }

      if (pickedTitle == null) {
        for (final l in nonEmpty.take(25)) {
          final m = RegExp(r'《([^》]{2,80})》').firstMatch(l);
          if (m != null) {
            final t = (m.group(1) ?? '').trim();
            if (t.isNotEmpty && !chapterRe.hasMatch(t)) {
              pickedTitle = t;
              break;
            }
          }
        }
      }

      if (pickedTitle == null) {
        for (final l in nonEmpty.take(30)) {
          if (authorRe.hasMatch(l)) continue;
          if (chapterRe.hasMatch(l)) continue;
          if (junkRe.hasMatch(l)) continue;
          final t = l.trim();
          if (t.length < 2 || t.length > 50) continue;
          if (RegExp(r'^[\W_]+$').hasMatch(t)) continue;
          pickedTitle = t;
          break;
        }
      }

      if (pickedTitle != null) {
        title = pickedTitle;
      }

      for (final l in nonEmpty.take(15)) {
        final m = authorRe.firstMatch(l);
        if (m != null) {
          final a = (m.group(2) ?? '').trim();
          if (a.isNotEmpty && a.length <= 80) {
            author = a;
            break;
          }
        }
      }
    }

    return ParsedMetadata(title: title, author: author);
  }

  static Future<List<int>?> _extractCoverBytes(EpubBookRef ref) async {
    String? coverId;
    final metaItems = ref.Schema?.Package?.Metadata?.MetaItems;
    if (metaItems != null) {
      for (var meta in metaItems) {
        final name = meta.Name?.toLowerCase();
        if (name == 'cover') {
          coverId = meta.Content;
          break;
        }
      }
    }

    final manifestItems = ref.Schema?.Package?.Manifest?.Items;

    if (coverId != null) {
      if (manifestItems != null) {
        final normalizedId = coverId.toLowerCase();
        for (var item in manifestItems) {
          final itemId = item.Id;
          if (itemId != null && itemId.toLowerCase() == normalizedId) {
            return _readImageByHref(ref, item.Href);
          }
        }
      }
    }

    if (manifestItems != null) {
      for (final item in manifestItems) {
        final props = (item.Properties ?? '').toLowerCase();
        if (props.contains('cover-image')) {
          final bytes = await _readImageByHref(ref, item.Href);
          if (bytes != null && bytes.isNotEmpty) return bytes;
        }
      }

      for (final item in manifestItems) {
        final id = (item.Id ?? '').toLowerCase();
        final href = (item.Href ?? '').toLowerCase();
        final mediaType = (item.MediaType ?? '').toLowerCase();
        final isImage = mediaType.startsWith('image/');
        if (isImage && (id.contains('cover') || href.contains('cover'))) {
          final bytes = await _readImageByHref(ref, item.Href);
          if (bytes != null && bytes.isNotEmpty) return bytes;
        }
      }
    }

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

  static Future<List<int>?> _readImageByHref(
      EpubBookRef ref, String? href) async {
    if (href == null) return null;
    final images = ref.Content?.Images;
    if (images == null) return null;

    if (images.containsKey(href)) {
      return images[href]!.readContentAsBytes();
    }

    for (var key in images.keys) {
      if (key.endsWith(href) || href.endsWith(key)) {
        return images[key]!.readContentAsBytes();
      }
    }
    return null;
  }

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

  Future<EpubBookRef?> openBookFromBytes(List<int> bytes) async {
    try {
      return await EpubReader.openBook(bytes);
    } catch (e) {
      debugPrint('Error opening book from bytes: $e');
      return null;
    }
  }

  Future<String?> openTxt(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      return _decodeTxtBytesChunked(bytes);
    } catch (e) {
      debugPrint('Error opening txt $filePath: $e');
      return null;
    }
  }

  Future<String?> openTxtFromBytes(List<int> bytes) async {
    try {
      return _decodeTxtBytesChunked(bytes);
    } catch (e) {
      debugPrint('Error decoding txt bytes: $e');
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
          author: '',
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
        author: '',
      );
    }
  }

  Future<ParsedMetadata> _parseTxt(String filePath) async {
    try {
      final file = File(filePath);
      const int maxSampleBytes = 131072;
      final raf = await file.open();
      try {
        final sample = await raf.read(maxSampleBytes);
        return _parseTxtBytes(sample, filePath);
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint('Error parsing TXT: $e');
      return ParsedMetadata(
        title: p.basenameWithoutExtension(filePath),
        author: '',
      );
    }
  }
}
