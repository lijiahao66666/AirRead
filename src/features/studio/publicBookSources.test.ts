import { describe, expect, it, vi } from 'vitest';

import { searchPublicBookSources } from './publicBookSources';

describe('publicBookSources', () => {
  it('searches the reachable Chinese catalog in one request', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/book-sources/chinese-catalog')) return json([{ id: '30466012', title: '论语', url: 'https://book.douban.com/subject/30466012/', author_name: '杨伯峻', year: '2018' }]);
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    const response = await searchPublicBookSources('pride', fetcher);

    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(response).toEqual({
      unavailableProviders: [],
      results: [
        expect.objectContaining({ title: '论语', provider: 'chinese-catalog', action: 'open', sourceUrl: 'https://book.douban.com/subject/30466012/' }),
      ],
    });
  });

  it('fails when the configured catalog is unavailable', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/book-sources/chinese-catalog')) throw new Error('offline');
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    await expect(searchPublicBookSources('pride', fetcher)).rejects.toThrow('offline');
  });
});

function json(value: unknown): Response {
  return new Response(JSON.stringify(value), { status: 200, headers: { 'Content-Type': 'application/json' } });
}
