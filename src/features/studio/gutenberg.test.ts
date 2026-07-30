import { describe, expect, it, vi } from 'vitest';

import { downloadGutenbergBook, parseSearchResults, searchGutenberg } from './gutenberg';

const html = '<li class="booklink"><a href="/ebooks/1342"><span class="title">Pride and Prejudice</span><span class="subtitle">Jane Austen</span><span class="extra">177064 downloads</span></a></li>';

describe('Project Gutenberg client', () => {
  it('parses only book result links from the trusted search page', () => {
    expect(parseSearchResults(`${html}<a href="/ebooks/not-a-book">Skip</a>`)).toEqual([{ id: '1342', title: 'Pride and Prejudice', author: 'Jane Austen', downloads: '177064 downloads' }]);
  });

  it('searches through the same-origin proxy', async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true, text: async () => html });
    await expect(searchGutenberg('pride', fetcher as typeof fetch)).resolves.toHaveLength(1);
    expect(fetcher).toHaveBeenCalledWith('/api/open-books/gutenberg/search?query=pride');
  });

  it('downloads a trusted EPUB route and records its source', async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true, headers: new Headers({ 'content-length': '4' }), blob: async () => new Blob([new Uint8Array([1, 2, 3, 4])], { type: 'application/epub+zip' }) });
    const parse = vi.fn().mockResolvedValue({ id: 'temporary', title: 'Pride and Prejudice', author: '', format: 'epub', bytes: new Uint8Array([1, 2, 3, 4]), importedAt: 1, readingChapter: 0, readingProgress: 0, generatedBilingual: false });
    const book = await downloadGutenbergBook({ id: '1342', title: 'Pride and Prejudice', author: 'Jane Austen', downloads: '' }, fetcher as typeof fetch, parse);
    expect(fetcher).toHaveBeenCalledWith('/api/open-books/gutenberg/1342.epub');
    expect(book).toMatchObject({ id: 'gutenberg:1342', author: 'Jane Austen', source: { provider: 'gutenberg', url: 'https://www.gutenberg.org/ebooks/1342' } });
  });
});
