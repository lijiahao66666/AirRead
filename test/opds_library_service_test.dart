import 'package:flutter_test/flutter_test.dart';
import 'package:airread/data/services/opds_library_service.dart';

void main() {
  test('parseFeed parses acquisition links and resolves relative URLs', () {
    const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dc="http://purl.org/dc/terms/"
      xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:uuid:test</id>
  <title>Test Feed</title>
  <entry>
    <title>Example Book</title>
    <id>urn:uuid:book-1</id>
    <author><name>Alice</name></author>
    <summary>hello</summary>
    <link rel="http://opds-spec.org/image/thumbnail" href="/covers/1.png" type="image/png" />
    <link rel="http://opds-spec.org/acquisition" href="/content/1.epub" type="application/epub+zip" />
    <link rel="http://opds-spec.org/acquisition" href="/content/1.txt" type="text/plain" />
  </entry>
</feed>
''';

    final books = OpdsLibraryService.parseFeed(
      xml,
      Uri.parse('https://example.com/opds/search'),
    );

    expect(books, hasLength(1));
    expect(books.first.title, 'Example Book');
    expect(books.first.authors, ['Alice']);
    expect(books.first.coverUrl, 'https://example.com/covers/1.png');
    expect(books.first.downloadUrls['epub'], 'https://example.com/content/1.epub');
    expect(books.first.downloadUrls['txt'], 'https://example.com/content/1.txt');
  });
}

