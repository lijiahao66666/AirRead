import { readEpubArchive } from './epubArchive';
import type { Book } from './book';
import { decodeText } from './textDecoder';

export async function parseBook(file: File): Promise<Book> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes.length === 0) throw new Error('书籍文件为空');
  const extension = file.name.toLowerCase().split('.').pop();
  const importedAt = Date.now();
  const id = createId();

  if (extension === 'txt') {
    return {
      id,
      title: file.name.replace(/\.txt$/i, '') || '未命名书籍',
      author: '',
      format: 'txt',
      bytes: Uint8Array.from(bytes),
      text: decodeText(bytes),
      importedAt,
      readingChapter: 0,
      readingProgress: 0,
      generatedBilingual: false,
    };
  }

  if (extension !== 'epub') throw new Error('仅支持 EPUB 或 TXT 文件');
  const archive = readEpubArchive(bytes);
  return {
    id,
    title: archive.title,
    author: archive.author,
    format: 'epub',
    bytes: Uint8Array.from(bytes),
    coverDataUrl: archive.coverDataUrl,
    importedAt,
    readingChapter: 0,
    readingProgress: 0,
    generatedBilingual: false,
  };
}

function createId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}
