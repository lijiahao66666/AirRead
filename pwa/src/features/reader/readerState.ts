import type { Book, Chapter } from '../../domain/books/book';
import { readEpubArchive } from '../../domain/books/epubArchive';

export type ReaderParagraph = { id: string; original: string; translation?: string };

export function chaptersForBook(book: Book): Chapter[] {
  if (book.format === 'txt') {
    return [{ id: 'txt', title: book.title, href: 'book.txt', content: book.text || new TextDecoder().decode(book.bytes) }];
  }
  return readEpubArchive(book.bytes).chapters;
}

export function paragraphsForChapter(chapter: Chapter): ReaderParagraph[] {
  const fallback = chapter.content.replace(/\r\n?/g, '\n').split(/\n{1,}/).map((text, index) => ({ id: `${chapter.id}-${index}`, original: text.trim() })).filter((item) => item.original);
  if (typeof DOMParser === 'undefined') return fallback;
  const document = new DOMParser().parseFromString(chapter.content, 'text/html');
  const elements = [...document.querySelectorAll('h1,h2,h3,h4,p,li,blockquote')];
  const texts = elements.map((element) => element.textContent?.replace(/\s+/g, ' ').trim() || '').filter(Boolean);
  if (texts.length > 0 && elements.some((element) => element.tagName !== 'BODY')) return texts.map((original, index) => ({ id: `${chapter.id}-${index}`, original }));
  if (fallback.length > 1) return fallback;
  return [(document.body.textContent || '').replace(/\s+/g, ' ').trim()].filter(Boolean).map((original, index) => ({ id: `${chapter.id}-${index}`, original }));
}
