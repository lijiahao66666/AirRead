import { describe, expect, it } from 'vitest';
import { strToU8, unzipSync, zipSync } from 'fflate';

import type { Book } from '../../domain/books/book';
import { buildMinimalEpub } from '../../domain/books/bookFixtures';
import {
  buildBilingualChapters,
  buildStudioChapters,
  createStudioState,
  studioReducer,
} from './studioState';

const book: Book = {
  id: 'studio-book',
  title: 'AirRead Test Book',
  author: 'AirRead',
  format: 'epub',
  bytes: buildMinimalEpub(),
  importedAt: 1,
  readingChapter: 0,
  readingProgress: 0,
  generatedBilingual: false,
};

describe('studioState', () => {
  it('inspects spine chapters and extracts semantic paragraphs in reading order', () => {
    const state = createStudioState(book);

    expect(state.stage).toBe('inspect');
    expect(state.chapters.map((chapter) => chapter.title)).toEqual(['Chapter One', 'Chapter Two']);
    expect(state.paragraphs.map((paragraph) => paragraph.original)).toEqual([
      'Chapter One',
      'The first paragraph begins the AirRead test.',
      'Chapter Two',
      'The second chapter keeps the context stable.',
    ]);
    expect(state.totalCharacters).toBeGreaterThan(80);
  });

  it('keeps pause, resume, cancel, and failed retry transitions explicit', () => {
    const selected = createStudioState(book);
    const running = studioReducer(selected, { type: 'start' });
    const translating = studioReducer(running, { type: 'paragraph-started', paragraphId: running.paragraphs[0].id });
    const paused = studioReducer(translating, { type: 'pause' });
    const resumed = studioReducer(paused, { type: 'resume' });
    const failed = studioReducer(resumed, { type: 'paragraph-failed', paragraphId: resumed.paragraphs[0].id, error: '翻译失败' });
    const retried = studioReducer(failed, { type: 'retry-failed' });
    const cancelled = studioReducer(retried, { type: 'cancel' });

    expect(paused.status).toBe('paused');
    expect(resumed.status).toBe('running');
    expect(failed.paragraphs[0]).toMatchObject({ status: 'failed', error: '翻译失败' });
    expect(retried.paragraphs[0]).toMatchObject({ status: 'pending', error: undefined });
    expect(cancelled.stage).toBe('select');
    expect(cancelled.status).toBe('cancelled');
  });

  it('inserts each translation below its source element without adding secrets to XHTML', () => {
    let state = createStudioState(book);
    for (const [index, paragraph] of state.paragraphs.entries()) {
      state = studioReducer(state, { type: 'paragraph-succeeded', paragraphId: paragraph.id, translation: `译文 ${index + 1}` });
    }

    const chapters = buildBilingualChapters(state);

    expect(chapters[0].content).toMatch(/Chapter One<\/h1>\s*<p[^>]*>译文 1<\/p>/);
    expect(chapters[0].content).toMatch(/AirRead test\.<\/p>\s*<p[^>]*>译文 2<\/p>/);
    expect(chapters[1].content).toContain('译文 4');
    expect(chapters.map((chapter) => chapter.content).join('')).not.toContain('secret-key');
  });

  it('writes only translated semantic text when bilingual output is disabled', () => {
    let state = createStudioState(book);
    state = studioReducer(state, { type: 'configure', config: { ...state.config, outputBilingual: false } });
    for (const [index, paragraph] of state.paragraphs.entries()) {
      state = studioReducer(state, { type: 'paragraph-succeeded', paragraphId: paragraph.id, translation: `译文 ${index + 1}` });
    }

    const chapters = buildStudioChapters(state);

    expect(chapters[0].content).toContain('<h1>译文 1</h1>');
    expect(chapters[0].content).not.toContain('Chapter One</h1>');
    expect(chapters[0].content).not.toContain('airread-translation');
  });

  it('translates only outer semantic blocks and preserves nested inline markup', () => {
    const files = unzipSync(buildMinimalEpub());
    files['OEBPS/chapter1.xhtml'] = strToU8(`<?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Nested</title></head><body>
        <ul><li><p>Read <em>deeply</em> today.</p></li></ul>
        <blockquote><p>Quoted <a href="https://example.com">link</a>.</p></blockquote>
      </body></html>`);
    const nestedBook = { ...book, bytes: zipSync(files) };
    let state = createStudioState(nestedBook);

    expect(state.paragraphs.slice(0, 2).map((paragraph) => paragraph.original)).toEqual([
      'Read deeply today.',
      'Quoted link.',
    ]);
    expect(state.paragraphs.filter((paragraph) => paragraph.chapterIndex === 0)).toHaveLength(2);

    state = studioReducer(state, { type: 'configure', config: { ...state.config, outputBilingual: false } });
    state = studioReducer(state, { type: 'paragraph-succeeded', paragraphId: state.paragraphs[0].id, translation: '深入阅读。' });
    state = studioReducer(state, { type: 'paragraph-succeeded', paragraphId: state.paragraphs[1].id, translation: '引用链接。' });
    const chapter = buildStudioChapters(state)[0];
    const document = new DOMParser().parseFromString(chapter.content, 'application/xhtml+xml');

    expect(document.querySelector('li')?.textContent).toBe('深入阅读。');
    expect(document.querySelector('li em')).not.toBeNull();
    expect(document.querySelector('blockquote')?.textContent).toBe('引用链接。');
    expect(document.querySelector('blockquote a')?.getAttribute('href')).toBe('https://example.com');
  });
});
