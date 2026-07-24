export type BookFormat = 'epub' | 'txt';

export type Book = {
  id: string;
  title: string;
  author: string;
  format: BookFormat;
  bytes: Uint8Array;
  coverDataUrl?: string;
  text?: string;
  importedAt: number;
  lastReadAt?: number;
  readingChapter: number;
  readingProgress: number;
  generatedBilingual: boolean;
};

export type Chapter = {
  id: string;
  title: string;
  href: string;
  content: string;
};

export function cloneBook(book: Book): Book {
  return {
    ...book,
    bytes: Uint8Array.from(book.bytes),
  };
}
