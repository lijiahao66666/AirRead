import type { Book, Chapter } from '../../domain/books/book';
import { readEpubArchive } from '../../domain/books/epubArchive';
import { splitTextIntoChapters } from '../../domain/books/textChapters';

export type ReaderParagraph = { id: string; original: string; translation?: string };

export function chaptersForBook(book: Book): Chapter[] {
  if (book.format === 'txt') {
    const text = book.text || new TextDecoder().decode(book.bytes);
    return splitTextIntoChapters(text, book.title).map((chapter, index) => ({
      id: `txt-chapter-${index + 1}`,
      title: chapter.title,
      href: `chapter-${index + 1}.txt`,
      content: chapter.content,
    }));
  }
  const chapters = readEpubArchive(book.bytes).chapters;
  const readableChapters = chapters.filter((chapter) => paragraphsForChapter(chapter).length > 0);
  return readableChapters.length > 0 ? readableChapters : chapters;
}

export function paragraphsForChapter(chapter: Chapter): ReaderParagraph[] {
  const fallback = chapter.content.replace(/\r\n?/g, '\n').split(/\n{1,}/).map((text, index) => ({ id: `${chapter.id}-${index}`, original: text.trim() })).filter((item) => item.original);
  const containsMarkup = /<\/?[a-z][^>]*>/i.test(chapter.content);
  if (!containsMarkup || typeof DOMParser === 'undefined') return fallback;
  const document = new DOMParser().parseFromString(chapter.content, 'text/html');
  const elements = [...document.querySelectorAll('h1,h2,h3,h4,p,li,blockquote')];
  const texts = elements.map((element) => element.textContent?.replace(/\s+/g, ' ').trim() || '').filter(Boolean);
  if (texts.length > 0) return texts.map((original, index) => ({ id: `${chapter.id}-${index}`, original }));
  const bodyText = (document.body.textContent || '').replace(/\s+/g, ' ').trim();
  return bodyText ? [{ id: `${chapter.id}-0`, original: bodyText }] : [];
}
