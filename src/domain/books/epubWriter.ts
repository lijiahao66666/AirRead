import { strToU8, zipSync, type ZipOptions } from 'fflate';

import type { Book, Chapter } from './book';
import { readEpubArchive, resolvePath } from './epubArchive';

export async function writeBilingualEpub(input: Book, chapters: Chapter[]): Promise<Blob> {
  if (input.format !== 'epub') throw new Error('只有 EPUB 书籍可以导出双语版本');

  const source = readEpubArchive(input.bytes);
  const packageDirectory = directoryOf(source.packagePath);
  const sourceChapterPaths = new Set(
    source.chapters.map((chapter) => resolvePath(packageDirectory, chapter.href)),
  );
  const replacementByPath = new Map(
    chapters.map((chapter) => [
      resolvePath(packageDirectory, chapter.href.split('#', 1)[0]),
      strToU8(chapter.content),
    ] as const),
  );
  for (const path of replacementByPath.keys()) {
    if (!sourceChapterPaths.has(path)) throw new Error(`章节 ${path} 不属于原 EPUB spine`);
  }

  const mimetypeEntry = source.entries.find((entry) => entry.path === 'mimetype');
  if (!mimetypeEntry) throw new Error('EPUB 缺少 mimetype 条目');
  const outputEntries: Record<string, Uint8Array | [Uint8Array, ZipOptions]> = {};
  outputEntries.mimetype = [mimetypeEntry.bytes, { level: 0 }];
  for (const entry of source.entries) {
    if (entry.path === 'mimetype') continue;
    outputEntries[entry.path] = replacementByPath.has(entry.path)
      ? replacementByPath.get(entry.path)!
      : entry.bytes;
  }
  const outputBytes = zipSync(outputEntries);
  return new Blob([outputBytes.buffer as ArrayBuffer], { type: 'application/epub+zip' });
}

function directoryOf(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.slice(0, slash);
}
