import 'dart:convert';
import 'dart:io';

import 'package:airread/data/database/database_helper.dart';
import 'package:airread/data/models/book.dart';
import 'package:airread/main.dart' as app;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:airread/presentation/providers/ai_model_provider.dart';
import 'package:airread/presentation/providers/books_provider.dart';
import 'package:airread/presentation/providers/translation_provider.dart';

Uint8List _buildMinimalEpubBytes({
  required String title,
  required List<String> paragraphs,
}) {
  Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

  final body = paragraphs
      .map((e) => '<p>${const HtmlEscape().convert(e)}</p>')
      .join('\n');

  final chapter1 = '''
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <title>$title</title>
    <meta charset="utf-8" />
  </head>
  <body>
    <h1>$title</h1>
    $body
  </body>
</html>
''';

  const containerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  final contentOpf = '''
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:language>zh</dc:language>
    <dc:identifier id="BookId">urn:uuid:airread-integration-test</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter1"/>
  </spine>
</package>
''';

  final tocNcx = '''
<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:airread-integration-test"/>
  </head>
  <docTitle><text>$title</text></docTitle>
  <navMap>
    <navPoint id="navPoint-1" playOrder="1">
      <navLabel><text>$title</text></navLabel>
      <content src="Text/ch1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
''';

  final mimetypeBytes = utf8Bytes('application/epub+zip');
  final containerBytes = utf8Bytes(containerXml);
  final opfBytes = utf8Bytes(contentOpf);
  final tocBytes = utf8Bytes(tocNcx);
  final chapterBytes = utf8Bytes(chapter1);

  final archive = Archive()
    ..addFile(
      ArchiveFile(
        'mimetype',
        mimetypeBytes.length,
        mimetypeBytes,
      ),
    )
    ..addFile(ArchiveFile(
        'META-INF/container.xml', containerBytes.length, containerBytes))
    ..addFile(ArchiveFile('OEBPS/content.opf', opfBytes.length, opfBytes))
    ..addFile(ArchiveFile('OEBPS/toc.ncx', tocBytes.length, tocBytes))
    ..addFile(
        ArchiveFile('OEBPS/Text/ch1.xhtml', chapterBytes.length, chapterBytes));

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Future<void> _seedTestBook() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('tr_cfg_to', 'en');
  await prefs.setString('tr_cfg_mode', 'translationOnly');
  await prefs.setBool('tr_ai_translate_enabled', false);
  await prefs.setString('ai_model_source', 'local');

  final docDir = await getApplicationDocumentsDirectory();
  final booksDir = Directory(p.join(docDir.path, 'books'));
  if (!await booksDir.exists()) {
    await booksDir.create(recursive: true);
  }

  const bookId = 'integration_test_epub_1';
  final epubPath = p.join(booksDir.path, '$bookId.epub');
  final file = File(epubPath);
  final bytes = _buildMinimalEpubBytes(
    title: '测试章节',
    paragraphs: const [
      '版权信息',
      '这是第一段中文，用于测试翻译模型是否会输出稳定的英文译文。',
      '如果输出包含大量乱码或直接回显原文，应判定为失败。',
    ],
  );
  await file.writeAsBytes(bytes, flush: true);

  final db = await DatabaseHelper.instance.database;
  final now = DateTime.now();
  final book = Book(
    id: bookId,
    title: '自动化翻译测试书',
    author: 'integration_test',
    filePath: epubPath,
    format: 'epub',
    importDate: now,
    totalPages: 0,
    currentPage: 0,
    percentage: 0.0,
    lastRead: null,
  );
  await db.insert('books', book.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure(
    'timeout waiting for widget after ${sw.elapsed.inSeconds}s: $finder',
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String onTimeout,
  Duration timeout = const Duration(seconds: 60),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    await tester.pump(step);
    if (condition()) return;
  }
  throw TestFailure('$onTimeout after ${sw.elapsed.inSeconds}s');
}

Future<void> _tapScreenCenter(WidgetTester tester) async {
  final size = tester.getSize(find.byType(MaterialApp));
  await tester.tapAt(Offset(size.width / 2, size.height / 2));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _ensureLocalModelEnabledAndLocalSelected(
    WidgetTester tester) async {
  await _tapScreenCenter(tester);
  await tester.tap(find.byIcon(Icons.auto_awesome));
  await tester.pump(const Duration(milliseconds: 900));

  await _pumpUntilFound(tester, find.byTooltip('AI设置'));
  await tester.tap(find.byTooltip('AI设置'));
  await tester.pump(const Duration(milliseconds: 900));

  final modelSwitch = find.descendant(
    of: find.ancestor(of: find.text('大模型'), matching: find.byType(Row)).first,
    matching: find.byType(Switch),
  );
  await _pumpUntilFound(tester, modelSwitch,
      timeout: const Duration(seconds: 20));
  final modelSwitchWidget = tester.widget<Switch>(modelSwitch);
  if (!modelSwitchWidget.value) {
    await tester.tap(modelSwitch);
    await tester.pump(const Duration(milliseconds: 900));
  }

  final localChip = find.text('本地');
  if (localChip.evaluate().isNotEmpty) {
    await tester.tap(localChip);
    await tester.pump(const Duration(milliseconds: 700));
  }

  final back = find.byTooltip('返回');
  await _pumpUntilFound(tester, back, timeout: const Duration(seconds: 10));
  await tester.tap(back);
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> _ensureTranslationEnabled(WidgetTester tester) async {
  final translateRowTap = find.ancestor(
    of: find.text('翻译'),
    matching: find.byType(InkWell),
  );
  await _pumpUntilFound(tester, translateRowTap,
      timeout: const Duration(seconds: 20));
  await tester.tap(translateRowTap.first);
  await tester.pump(const Duration(milliseconds: 900));

  final size = tester.getSize(find.byType(MaterialApp));
  await tester.tapAt(Offset(size.width / 2, size.height * 0.1));
  await tester.pump(const Duration(milliseconds: 800));
}

Future<void> _assertLocalTranslationWorks(WidgetTester tester) async {
  final element = tester.element(find.byType(MaterialApp));
  final aiModel = element.read<AiModelProvider>();
  final tp = element.read<TranslationProvider>();

  debugPrint(
      '[integration_test] aiModel.loaded=${aiModel.loaded} source=${aiModel.source.name}');
  debugPrint(
      '[integration_test] modelInstalled=${aiModel.isModelInstalled} loaded=${aiModel.loaded}');

  if (aiModel.source != AiModelSource.local) {
    throw TestFailure('expected local model source, got ${aiModel.source}');
  }
  if (!aiModel.isModelInstalled) {
    throw TestFailure('local model not installed');
  }
  if (!aiModel.loaded) {
    throw TestFailure('local model not loaded');
  }

  final out = await tester.runAsync(() async {
    final r = await tp.translateParagraphsByIndex({0: '版权信息'});
    return r[0] ?? '';
  }) as String;

  final t = out.trim();
  if (t.isEmpty) {
    throw TestFailure('empty translation output');
  }
  if (t.contains('版权信息')) {
    throw TestFailure('translation echoes source');
  }
  if (t.contains('\uFFFD')) {
    throw TestFailure('translation contains replacement char');
  }
  final hasLatin = RegExp(r'[A-Za-z]').hasMatch(t);
  if (!hasLatin) {
    throw TestFailure('translation does not look like English: $t');
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('自动化走通阅读页 -> AI面板 -> 本地翻译 -> 译文校验', (tester) async {
    await _seedTestBook();
    app.main();
    await tester.pump(const Duration(seconds: 2));

    const bookId = 'integration_test_epub_1';
    await _pumpUntil(tester, () {
      final element = find.byType(MaterialApp).evaluate().isEmpty
          ? null
          : tester.element(find.byType(MaterialApp));
      if (element == null) return false;
      final books = element.read<BooksProvider>();
      return books.books.any((b) => b.id == bookId);
    },
        onTimeout: 'BooksProvider did not load seeded book',
        timeout: const Duration(seconds: 90));

    await _pumpUntilFound(tester, find.byKey(const ValueKey(bookId)),
        timeout: const Duration(seconds: 90));
    await tester.tap(find.byKey(const ValueKey(bookId)));
    await tester.pump(const Duration(seconds: 3));

    await _tapScreenCenter(tester);
    await _pumpUntilFound(tester, find.byIcon(Icons.auto_awesome),
        timeout: const Duration(seconds: 30));
    await _ensureLocalModelEnabledAndLocalSelected(tester);

    await _pumpUntil(tester, () {
      final element = tester.element(find.byType(MaterialApp));
      final aiModel = element.read<AiModelProvider>();
      return aiModel.source == AiModelSource.local &&
          aiModel.isModelInstalled &&
          aiModel.loaded;
    },
        onTimeout: 'Local model not ready',
        timeout: const Duration(minutes: 3));

    await _tapScreenCenter(tester);
    await tester.tap(find.byIcon(Icons.auto_awesome));
    await tester.pump(const Duration(milliseconds: 900));

    await _ensureTranslationEnabled(tester);
    await _assertLocalTranslationWorks(tester);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
