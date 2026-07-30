import type { Book } from '../domain/books/book';
import type { ReaderPreferences } from '../features/reader/readerPreferences';

const BACKUP_VERSION = 1;

export type LocalBookBackup = {
  version: typeof BACKUP_VERSION;
  exportedAt: number;
  books: Array<Omit<Book, 'bytes'> & { bytes: string }>;
  readerPreferences?: ReaderPreferences;
};

export type ParsedLocalBookBackup = Omit<LocalBookBackup, 'books'> & {
  books: Book[];
};

const encodeBytes = (bytes: Uint8Array): string => {
  let binary = '';
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
};

const decodeBytes = (value: string): Uint8Array => Uint8Array.from(atob(value), (character) => character.charCodeAt(0));

const isBookFormat = (value: unknown): value is Book['format'] => ['epub', 'txt', 'markdown', 'html', 'pdf', 'docx'].includes(String(value));

export function createLocalBookBackup(books: Book[], readerPreferences?: ReaderPreferences): LocalBookBackup {
  return {
    version: BACKUP_VERSION,
    exportedAt: Date.now(),
    books: books.map((book) => ({ ...book, bytes: encodeBytes(book.bytes) })),
    readerPreferences,
  };
}

export function parseLocalBookBackup(serialized: string): ParsedLocalBookBackup {
  let parsed: unknown;
  try {
    parsed = JSON.parse(serialized);
  } catch {
    throw new Error('备份文件不是有效的 JSON');
  }
  if (!parsed || typeof parsed !== 'object') throw new Error('备份文件格式不正确');
  const backup = parsed as Partial<LocalBookBackup>;
  if (backup.version !== BACKUP_VERSION || !Array.isArray(backup.books)) throw new Error('不支持的备份版本或内容');
  const books = backup.books.map((candidate): Book => {
    if (!candidate || typeof candidate !== 'object') throw new Error('备份中包含无效书籍');
    const book = candidate as LocalBookBackup['books'][number];
    if (!book.id || !book.title || !isBookFormat(book.format) || typeof book.bytes !== 'string' || !Number.isFinite(book.importedAt)) throw new Error('备份中包含无效书籍');
    try {
      return { ...book, bytes: decodeBytes(book.bytes) };
    } catch {
      throw new Error('备份中的书籍数据已损坏');
    }
  });
  return { version: BACKUP_VERSION, exportedAt: Number(backup.exportedAt) || 0, books, readerPreferences: backup.readerPreferences };
}

export function mergeRestoredBooks(currentBooks: Book[], restoredBooks: Book[]): Book[] {
  const restoredById = new Map(restoredBooks.map((book) => [book.id, book]));
  return [
    ...restoredBooks,
    ...currentBooks.filter((book) => !restoredById.has(book.id)),
  ].sort((left, right) => right.importedAt - left.importedAt);
}
