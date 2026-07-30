export type BookFormat = 'epub' | 'txt' | 'markdown' | 'html' | 'pdf' | 'docx';

export type BookTranslationPreferences = {
  sourceLanguage?: string;
  targetLanguage?: string;
};

export type BookSelectionPreferences = {
  targetLanguage?: string;
};

export type BookReadingAnchor = {
  chapter: number;
  paragraphId: string;
  sourceOffset: number;
};

export type BookBookmark = BookReadingAnchor & {
  id: string;
  createdAt: number;
};

export type BookExcerpt = BookReadingAnchor & {
  id: string;
  source: string;
  translation?: string;
  targetLanguage?: string;
  createdAt: number;
};

export type BookSource = {
  provider: 'wikisource';
  url: string;
  license: string;
};

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
  readingAnchor?: BookReadingAnchor;
  bookmarks?: BookBookmark[];
  excerpts?: BookExcerpt[];
  source?: BookSource;
  generatedBilingual: boolean;
  translationPreferences?: BookTranslationPreferences;
  selectionPreferences?: BookSelectionPreferences;
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
    bookmarks: book.bookmarks?.map((bookmark) => ({ ...bookmark })),
    excerpts: book.excerpts?.map((excerpt) => ({ ...excerpt })),
    source: book.source ? { ...book.source } : undefined,
  };
}
