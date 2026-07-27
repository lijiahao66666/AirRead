import { describe, expect, it } from 'vitest';

import { paginateReaderParagraphs } from './readerPagination';

describe('reader pagination', () => {
  it('splits long paragraphs into navigable pages without losing text', () => {
    const original = '第一句。'.repeat(80);
    const pages = paginateReaderParagraphs([{ id: 'p1', original }], { blockCapacity: 120, contentMode: 'original' });
    expect(pages.length).toBeGreaterThan(1);
    expect(pages.flat().map((block) => block.original).join('')).toBe(original);
  });

  it('keeps original and translation chunks together in bilingual mode', () => {
    const pages = paginateReaderParagraphs([{ id: 'p1', original: 'This is a long paragraph. '.repeat(12), translation: '这是一段很长的译文。'.repeat(12) }], { blockCapacity: 160, contentMode: 'bilingual' });
    expect(pages.flat().every((block) => block.paragraphId === 'p1')).toBe(true);
    expect(pages.flat().some((block) => block.translation)).toBe(true);
  });

  it('paginates pure translation mode from translated content', () => {
    const translation = '这是纯译文内容。'.repeat(40);
    const pages = paginateReaderParagraphs([{ id: 'p1', original: 'Short source.', translation }], { blockCapacity: 100, contentMode: 'translation' });
    expect(pages.length).toBeGreaterThan(1);
    expect(pages.flat().map((block) => block.translation).join('')).toBe(translation);
  });

  it('balances a nearly empty trailing page without losing reading order', () => {
    const paragraphs = Array.from({ length: 12 }, (_, index) => ({ id: `p${index + 1}`, original: 'A'.repeat(25) }));
    const pages = paginateReaderParagraphs(paragraphs, { blockCapacity: 100, blockGapWeight: 6, contentMode: 'original' });

    expect(pages).toHaveLength(3);
    expect(pages[pages.length - 1]).toHaveLength(3);
    expect(pages.flat().map((block) => block.paragraphId)).toEqual(paragraphs.map((paragraph) => paragraph.id));
  });
});
