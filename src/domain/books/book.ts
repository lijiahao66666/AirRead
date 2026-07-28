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
  };
}
