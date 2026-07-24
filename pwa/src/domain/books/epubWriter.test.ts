import { describe, expect, it } from 'vitest';
import { unzipSync, strFromU8 } from 'fflate';

import type { Book } from './book';
import { buildMinimalEpub, buildMisorderedEpub } from './bookFixtures';
import { readEpubArchive } from './epubArchive';
import { writeBilingualEpub } from './epubWriter';

describe('bilingual EPUB writer', () => {
  it('replaces bilingual chapters while preserving metadata, TOC, cover, and other entries', async () => {
    const bytes = buildMinimalEpub();
    const input = makeBook(bytes);
    const source = readEpubArchive(bytes);
    const chapters = source.chapters.map((chapter, index) => ({
      ...chapter,
      content: chapter.content.replace(
        '</body>',
        `<p class="airread-translation">译文 ${index + 1}</p></body>`,
      ),
    }));

    const blob = await writeBilingualEpub(input, chapters);
    const outputBytes = await blobToBytes(blob);
    const output = readEpubArchive(outputBytes);
    const entries = unzipSync(outputBytes);

    expect(output.title).toBe(source.title);
    expect(output.author).toBe(source.author);
    expect(output.coverDataUrl).toBe(source.coverDataUrl);
    expect(output.chapters.map(({ title }) => title)).toEqual([
      'Chapter One',
      'Chapter Two',
    ]);
    expect(output.chapters[0].content).toContain('译文 1');
    expect(output.chapters[1].content).toContain('译文 2');
    expect(strFromU8(entries['OEBPS/styles/reader.css'])).toBe(
      'body { color: #203633; }',
    );
  });

  it('writes mimetype first and without compression even when source order is wrong', async () => {
    const input = makeBook(buildMisorderedEpub());
    const source = readEpubArchive(input.bytes);
    const blob = await writeBilingualEpub(input, source.chapters);
    const outputBytes = await blobToBytes(blob);
    const nameLength = outputBytes[26] | (outputBytes[27] << 8);
    const compressionMethod = outputBytes[8] | (outputBytes[9] << 8);

    expect([...outputBytes.subarray(0, 4)]).toEqual([0x50, 0x4b, 0x03, 0x04]);
    expect(new TextDecoder().decode(outputBytes.subarray(30, 30 + nameLength))).toBe('mimetype');
    expect(compressionMethod).toBe(0);
    expect(strFromU8(unzipSync(outputBytes).mimetype)).toBe('application/epub+zip');
  });

  it('rejects a chapter href that is not part of the source spine', async () => {
    const input = makeBook(buildMinimalEpub());

    await expect(writeBilingualEpub(input, [{
      id: 'missing',
      title: 'Missing',
      href: 'does-not-exist.xhtml',
      content: '<html/>',
    }])).rejects.toThrow('不属于原 EPUB spine');
  });
});

function makeBook(bytes: Uint8Array): Book {
  return {
    id: 'book-1',
    title: 'AirRead Test Book',
    author: 'AirRead',
    format: 'epub',
    bytes,
    importedAt: 1,
    readingChapter: 0,
    readingProgress: 0,
    generatedBilingual: false,
  };
}

function blobToBytes(blob: Blob): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(new Uint8Array(reader.result as ArrayBuffer));
    reader.onerror = () => reject(reader.error);
    reader.readAsArrayBuffer(blob);
  });
}
