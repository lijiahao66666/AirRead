import { describe, expect, it, vi } from 'vitest';

import { createWikisourceBook, loadWikisourcePage, searchWikisource, wikisourceHtmlToText } from './wikisource';

const response = (body: unknown) => ({ ok: true, json: async () => body }) as Response;

describe('Wikisource client', () => {
  it('searches only the public main namespace and removes result markup', async () => {
    const fetcher = vi.fn().mockResolvedValue(response({ query: { search: [{ title: '论语', snippet: '<span class="searchmatch">论语</span>  学而', wordcount: 123 }] } }));

    await expect(searchWikisource('论语', fetcher as typeof fetch)).resolves.toEqual([{ title: '论语', snippet: '论语 学而', wordCount: 123 }]);
    expect(fetcher).toHaveBeenCalledWith(expect.stringContaining('srnamespace=0'));
  });

  it('converts readable page blocks into a local text book with attribution', async () => {
    const fetcher = vi.fn().mockResolvedValue(response({ parse: { title: '论语/学而', text: { '*': '<div class="mw-parser-output"><h2>学而</h2><p>子曰：学而时习之。</p><table><tr><td>忽略</td></tr></table></div>' } } }));

    const page = await loadWikisourcePage('论语/学而', fetcher as typeof fetch);
    const book = createWikisourceBook(page);

    expect(page.text).toBe('# 学而\n\n子曰：学而时习之。');
    expect(book).toMatchObject({ format: 'txt', source: { provider: 'wikisource' } });
    expect(book.text).toContain('来源说明');
    expect(book.text).toContain('中文维基文库');
  });

  it('does not retain navigation tables while parsing HTML', () => {
    expect(wikisourceHtmlToText('<div class="mw-parser-output"><p>可读正文</p><div class="navbox">忽略导航</div><blockquote>引用文字</blockquote></div>')).toBe('可读正文\n\n引用文字');
  });
});
