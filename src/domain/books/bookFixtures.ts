import { strToU8, unzipSync, zipSync } from 'fflate';

const CONTAINER_XML = `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`;

const PACKAGE_XML = `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">airread-test-book</dc:identifier>
    <dc:title>AirRead Test Book</dc:title>
    <dc:creator>AirRead</dc:creator>
    <dc:language>en</dc:language>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover-image" href="images/cover.png" media-type="image/png"/>
    <item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter-2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter-1"/>
    <itemref idref="chapter-2"/>
  </spine>
</package>`;

const NAVIGATION_XML = `<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="airread-test-book"/></head>
  <docTitle><text>AirRead Test Book</text></docTitle>
  <docAuthor><text>AirRead</text></docAuthor>
  <navMap>
    <navPoint id="chapter-1" playOrder="1">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
    <navPoint id="chapter-2" playOrder="2">
      <navLabel><text>Chapter Two</text></navLabel>
      <content src="chapter2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>`;

const CHAPTER_ONE = `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
  <head><title>Chapter One</title></head>
  <body><h1>Chapter One</h1><p>The first paragraph begins the AirRead test.</p></body>
</html>`;

const CHAPTER_TWO = `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
  <head><title>Chapter Two</title></head>
  <body><h1>Chapter Two</h1><p>The second chapter keeps the context stable.</p></body>
</html>`;

export const TEST_COVER_BYTES = new Uint8Array([
  137, 80, 78, 71, 13, 10, 26, 10,
]);

export function buildMinimalDocx(): Uint8Array {
  const document = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
  <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章 开始阅读</w:t></w:r></w:p>
  <w:p><w:r><w:t>AirRead 可以本地解析 DOCX 正文。</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>保留段落结构。</w:t></w:r></w:p>
  <w:tbl><w:tr><w:tc><w:p><w:r><w:t>表格中的可读文本。</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
  <w:sectPr/>
</w:body></w:document>`;
  const coreProperties = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>AirRead DOCX 测试书</dc:title><dc:creator>AirRead</dc:creator></cp:coreProperties>`;
  return zipSync({
    '[Content_Types].xml': strToU8('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'),
    '_rels/.rels': strToU8('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>'),
    'docProps/core.xml': strToU8(coreProperties),
    'word/document.xml': strToU8(document),
  });
}

export function buildMinimalEpub(): Uint8Array {
  return zipSync({
    mimetype: [strToU8('application/epub+zip'), { level: 0 }],
    'META-INF/container.xml': strToU8(CONTAINER_XML),
    'OEBPS/content.opf': strToU8(PACKAGE_XML),
    'OEBPS/toc.ncx': strToU8(NAVIGATION_XML),
    'OEBPS/images/cover.png': TEST_COVER_BYTES,
    'OEBPS/chapter1.xhtml': strToU8(CHAPTER_ONE),
    'OEBPS/chapter2.xhtml': strToU8(CHAPTER_TWO),
    'OEBPS/styles/reader.css': strToU8('body { color: #203633; }'),
  });
}

export function buildEpub3NavFixture(): Uint8Array {
  const container = `<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`;
  const packageDocument = `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">airread-epub3</dc:identifier><dc:title>AirRead EPUB3</dc:title><dc:creator>AirRead 3</dc:creator></metadata>
  <manifest>
    <item id="nav" href="navigation/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter-1" href="text/chapter-one.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter-2" href="text/chapter-two.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter-1"/><itemref idref="chapter-2"/></spine>
</package>`;
  const navigation = `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>
  <li><a href="../text/chapter-one.xhtml#start">来自导航的一章</a></li>
  <li><a href="../text/chapter-two.xhtml">来自导航的二章</a></li>
</ol></nav></body></html>`;
  const chapterOne = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fallback One</title></head><body><p id="start">One</p></body></html>';
  const chapterTwo = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fallback Two</title></head><body><p>Two</p></body></html>';
  return zipSync({
    mimetype: [strToU8('application/epub+zip'), { level: 0 }],
    'META-INF/container.xml': strToU8(container),
    'OEBPS/package.opf': strToU8(packageDocument),
    'OEBPS/navigation/toc.xhtml': strToU8(navigation),
    'OEBPS/text/chapter-one.xhtml': strToU8(chapterOne),
    'OEBPS/text/chapter-two.xhtml': strToU8(chapterTwo),
  });
}

export function buildMisorderedEpub(): Uint8Array {
  const source = unzipSync(buildMinimalEpub());
  const entries: Record<string, Uint8Array> = {};
  for (const [path, bytes] of Object.entries(source)) {
    if (path !== 'mimetype') entries[path] = bytes;
  }
  entries.mimetype = source.mimetype;
  return zipSync(entries);
}

export function fileFromBytes(name: string, bytes: Uint8Array): File {
  const copy = Uint8Array.from(bytes);
  return {
    name,
    arrayBuffer: async () => copy.buffer,
  } as File;
}
