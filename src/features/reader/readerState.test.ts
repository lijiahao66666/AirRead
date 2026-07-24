import { describe, expect, it } from 'vitest';

import type { Chapter } from '../../domain/books/book';
import { paragraphsForChapter } from './readerState';

const chapter = (content: string): Chapter => ({
  id: 'chapter',
  title: 'Chapter',
  href: 'chapter.xhtml',
  content,
});

describe('reader state', () => {
  it('keeps plain text paragraphs separate', () => {
    expect(paragraphsForChapter(chapter('First paragraph.\n\nSecond paragraph.')).map(({ original }) => original)).toEqual([
      'First paragraph.',
      'Second paragraph.',
    ]);
  });

  it('extracts readable text from XHTML without exposing markup', () => {
    const content = `<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter One</h1><p>Down the rabbit-hole.</p></body></html>`;

    expect(paragraphsForChapter(chapter(content)).map(({ original }) => original)).toEqual([
      'Chapter One',
      'Down the rabbit-hole.',
    ]);
  });

  it('treats an image-only XHTML cover as non-readable content', () => {
    const content = `<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><svg><image href="cover.jpg" /></svg></body></html>`;

    expect(paragraphsForChapter(chapter(content))).toEqual([]);
  });
});
