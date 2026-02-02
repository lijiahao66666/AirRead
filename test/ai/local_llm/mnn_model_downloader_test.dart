import 'package:flutter_test/flutter_test.dart';
import 'package:airread/ai/local_llm/mnn_model_downloader.dart';

void main() {
  group('MnnModelDownloader.parseTotalBytesFromContentRange', () {
    test('parses total bytes', () {
      expect(
        MnnModelDownloader.parseTotalBytesFromContentRange('bytes 0-99/1234'),
        1234,
      );
    });

    test('returns null for unknown total', () {
      expect(
        MnnModelDownloader.parseTotalBytesFromContentRange('bytes 0-99/*'),
        isNull,
      );
    });

    test('returns null for invalid format', () {
      expect(
        MnnModelDownloader.parseTotalBytesFromContentRange('invalid'),
        isNull,
      );
    });
  });
}

