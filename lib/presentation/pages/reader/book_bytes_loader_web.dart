import 'dart:typed_data';

Future<List<int>> loadBookBytes(Uint8List? embeddedBytes, String path) async {
  if (embeddedBytes != null && embeddedBytes.isNotEmpty) {
    return embeddedBytes;
  }
  throw StateError('Web 模式缺少书籍内容');
}

