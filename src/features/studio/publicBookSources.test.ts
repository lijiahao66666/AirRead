import { describe, expect, it, vi } from 'vitest';

import { searchPublicBookSources } from './publicBookSources';

describe('publicBookSources', () => {
  it('searches the Chinese catalog and Gutenberg records in one request', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/book-sources/chinese-catalog')) return json([{ id: '30466012', title: '论语', url: 'https://book.douban.com/subject/30466012/', author_name: '杨伯峻', year: '2018' }]);
      if (url.startsWith('/api/book-sources/gutenberg')) return json({ results: [{ id: 1342, title: 'Pride and Prejudice', authors: [{ name: 'Austen, Jane' }], download_count: 1234 }] });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    const response = await searchPublicBookSources('pride', fetcher);

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(response).toEqual({
      unavailableProviders: [],
      results: [
        expect.objectContaining({ title: '论语', provider: 'chinese-catalog', action: 'open', sourceUrl: 'https://book.douban.com/subject/30466012/' }),
        expect.objectContaining({ title: 'Pride and Prejudice', provider: 'gutenberg', action: 'open', sourceUrl: 'https://www.gutenberg.org/ebooks/1342' }),
      ],
    });
  });

  it('keeps usable results when one source is unavailable', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/book-sources/chinese-catalog')) throw new Error('offline');
      if (url.startsWith('/api/book-sources/gutenberg')) return json({ results: [] });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    await expect(searchPublicBookSources('pride', fetcher)).resolves.toEqual({ results: [], unavailableProviders: ['中文书目'] });
  });
});

function json(value: unknown): Response {
  return new Response(JSON.stringify(value), { status: 200, headers: { 'Content-Type': 'application/json' } });
}
