import { describe, expect, it, vi } from 'vitest';

import { searchPublicBookSources } from './publicBookSources';

describe('publicBookSources', () => {
  it('searches Wikisource and Gutenberg public-domain records in one request', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('https://zh.wikisource.org/')) return json({ query: { search: [{ title: '论语', snippet: '论语 学而', wordcount: 123 }] } });
      if (url.startsWith('https://archive.org/advancedsearch.php')) return json({ response: { docs: [{ identifier: 'pride', title: 'Pride and Prejudice', creator: 'Austen, Jane', year: 1813 }] } });
      if (url === 'https://archive.org/metadata/pride') return json({ files: [{ name: 'pride.epub', format: 'EPUB' }] });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    const response = await searchPublicBookSources('pride', fetcher);

    expect(fetcher).toHaveBeenCalledTimes(3);
    expect(response).toEqual({
      unavailableProviders: [],
      results: [
        expect.objectContaining({ title: '论语', provider: 'wikisource', action: 'import', sourceTitle: '论语' }),
        expect.objectContaining({ title: 'Pride and Prejudice', provider: 'archive-gutenberg', action: 'download', downloadUrl: 'https://archive.org/download/pride/pride.epub' }),
      ],
    });
  });

  it('keeps usable results when one source is unavailable', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('https://zh.wikisource.org/')) throw new Error('offline');
      if (url.startsWith('https://archive.org/advancedsearch.php')) return json({ response: { docs: [] } });
      throw new Error(`unexpected request: ${url}`);
    }) as typeof fetch;

    await expect(searchPublicBookSources('pride', fetcher)).resolves.toEqual({ results: [], unavailableProviders: ['中文维基文库'] });
  });
});

function json(value: unknown): Response {
  return new Response(JSON.stringify(value), { status: 200, headers: { 'Content-Type': 'application/json' } });
}
