import { describe, expect, it, vi } from 'vitest';

import { searchPublicBookSources } from './publicBookSources';

describe('publicBookSources', () => {
  it('searches the Chinese classics index and Gutenberg records in one request', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/book-sources/classics')) return html('<div id="zhengwen1"><p><a href="/guwen/book_1.aspx"><span class="timu">论语</span></a></p><div style="display: flex"><span>孔子弟子及再传弟子</span><span>先秦</span></div><div class="contson">儒家经典著作</div></div>');
      if (url.startsWith('/api/book-sources/gutenberg')) return json({ results: [{ id: 1342, title: 'Pride and Prejudice', authors: [{ name: 'Austen, Jane' }], download_count: 1234 }] });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    const response = await searchPublicBookSources('pride', fetcher);

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(response).toEqual({
      unavailableProviders: [],
      results: [
        expect.objectContaining({ title: '论语', provider: 'classics-index', action: 'open', actionLabel: '前往阅读' }),
        expect.objectContaining({ title: 'Pride and Prejudice', provider: 'gutenberg', action: 'open', sourceUrl: 'https://www.gutenberg.org/ebooks/1342' }),
      ],
    });
  });

  it('keeps usable results when one source is unavailable', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/book-sources/classics')) throw new Error('offline');
      if (url.startsWith('/api/book-sources/gutenberg')) return json({ results: [] });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    await expect(searchPublicBookSources('pride', fetcher)).resolves.toEqual({ results: [], unavailableProviders: ['中文典籍索引'] });
  });
});

function json(value: unknown): Response {
  return new Response(JSON.stringify(value), { status: 200, headers: { 'Content-Type': 'application/json' } });
}

function html(value: string): Response {
  return new Response(value, { status: 200, headers: { 'Content-Type': 'text/html' } });
}
