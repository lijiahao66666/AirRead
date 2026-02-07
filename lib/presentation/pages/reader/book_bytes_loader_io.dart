import 'dart:io';
import 'dart:typed_data';

Future<List<int>> loadBookBytes(Uint8List? embeddedBytes, String path) async {
  if (embeddedBytes != null && embeddedBytes.isNotEmpty) {
    return embeddedBytes;
  }
  return File(path).readAsBytes();
}

