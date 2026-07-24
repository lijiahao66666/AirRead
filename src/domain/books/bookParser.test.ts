import { describe, expect, it } from 'vitest';

import { parseBook } from './bookParser';
import { buildEpub3NavFixture, buildMinimalEpub, fileFromBytes, TEST_COVER_BYTES } from './bookFixtures';
import { readEpubArchive } from './epubArchive';
import { decodeText } from './textDecoder';

describe('book parsing', () => {
  it('reads EPUB metadata and TOC in spine order', async () => {
    const bytes = buildMinimalEpub();

    const archive = readEpubArchive(bytes);
    const book = await parseBook(fileFromBytes('fallback.epub', bytes));

    expect(book.title).toBe('AirRead Test Book');
    expect(book.author).toBe('AirRead');
    expect(book.format).toBe('epub');
    expect([...book.bytes]).toEqual([...bytes]);
    expect(archive.chapters.map(({ title, href }) => ({ title, href }))).toEqual([
      { title: 'Chapter One', href: 'chapter1.xhtml' },
      { title: 'Chapter Two', href: 'chapter2.xhtml' },
    ]);
  });

  it('extracts the EPUB cover without changing its bytes', async () => {
    const book = await parseBook(fileFromBytes('airread.epub', buildMinimalEpub()));

    expect(book.coverDataUrl).toBe(
      `data:image/png;base64,${bytesToBase64(TEST_COVER_BYTES)}`,
    );
  });

  it('reads an EPUB3 navigation document and resolves cross-directory fragments', async () => {
    const archive = readEpubArchive(buildEpub3NavFixture());

    expect(archive.chapters.map(({ title, href }) => ({ title, href }))).toEqual([
      { title: '来自导航的一章', href: 'text/chapter-one.xhtml' },
      { title: '来自导航的二章', href: 'text/chapter-two.xhtml' },
    ]);
  });

  it('decodes UTF-8 TXT and uses the file name as its title', async () => {
    const bytes = new TextEncoder().encode('沉浸阅读');

    const book = await parseBook(fileFromBytes('沉浸阅读.txt', bytes));

    expect(book.title).toBe('沉浸阅读');
    expect(book.format).toBe('txt');
    expect([...book.bytes]).toEqual([...bytes]);
    expect(book.text).toBe('沉浸阅读');
  });

  it('decodes GBK TXT in a browser-safe way', async () => {
    const gbkBytes = new Uint8Array([0xcb, 0xab, 0xd3, 0xef, 0xd4, 0xc4, 0xb6, 0xc1]);

    const book = await parseBook(fileFromBytes('双语阅读.txt', gbkBytes));

    expect(book.text).toBe('双语阅读');
  });

  it('fails explicitly instead of silently corrupting GBK when gb18030 is unavailable', () => {
    const originalTextDecoder = globalThis.TextDecoder;
    class UnsupportedChineseDecoder {
      constructor(label?: string) {
        if (label && label !== 'utf-8') throw new RangeError('unsupported label');
      }

      decode(): string {
        return '�';
      }
    }

    globalThis.TextDecoder = UnsupportedChineseDecoder as unknown as typeof TextDecoder;
    try {
      expect(() => decodeText(new Uint8Array([0xcb, 0xab, 0xd3, 0xef]))).toThrow(
        '当前浏览器不支持 GBK/GB18030 文本解码',
      );
    } finally {
      globalThis.TextDecoder = originalTextDecoder;
    }
  });

  it('rejects a truncated GBK/GB18030 byte sequence with a readable error', () => {
    expect(() => decodeText(new Uint8Array([0x81]))).toThrow(
      '文本编码无效，无法按 UTF-8 或 GBK/GB18030 解码',
    );
  });
});

function bytesToBase64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}
