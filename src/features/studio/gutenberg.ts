import { parseBook } from '../../domain/books/bookParser';
import type { Book } from '../../domain/books/book';

const GUTENBERG_SEARCH_API = '/api/open-books/gutenberg/search';
const GUTENBERG_DOWNLOAD_API = '/api/open-books/gutenberg';
const MAX_EPUB_BYTES = 80 * 1024 * 1024;

export type GutenbergSearchResult = {
  id: string;
  title: string;
  author: string;
  downloads: string;
};

type Fetcher = typeof fetch;

export async function searchGutenberg(query: string, fetcher: Fetcher = fetch): Promise<GutenbergSearchResult[]> {
  const normalizedQuery = query.trim();
  if (!normalizedQuery) return [];
  const response = await fetcher(`${GUTENBERG_SEARCH_API}?${new URLSearchParams({ query: normalizedQuery })}`);
  if (!response.ok) throw new Error('Project Gutenberg 暂时无法连接，请稍后重试');
  return parseSearchResults(await response.text());
}

export function parseSearchResults(html: string): GutenbergSearchResult[] {
  const document = new DOMParser().parseFromString(html, 'text/html');
  return [...document.querySelectorAll<HTMLAnchorElement>('li.booklink a[href^="/ebooks/"]')].flatMap((link) => {
    const match = link.getAttribute('href')?.match(/^\/ebooks\/(\d+)$/u);
    const title = link.querySelector('.title')?.textContent?.trim();
    if (!match || !title) return [];
    return [{
      id: match[1],
      title,
      author: link.querySelector('.subtitle')?.textContent?.trim() || 'Project Gutenberg',
      downloads: link.querySelector('.extra')?.textContent?.trim() || '',
    }];
  });
}

export async function downloadGutenbergBook(result: GutenbergSearchResult, fetcher: Fetcher = fetch, parse = parseBook): Promise<Book> {
  const response = await fetcher(`${GUTENBERG_DOWNLOAD_API}/${encodeURIComponent(result.id)}.epub`);
  if (!response.ok) throw new Error('该作品的 EPUB 暂时无法下载，请稍后重试');
  const length = Number(response.headers.get('content-length'));
  if (Number.isFinite(length) && length > MAX_EPUB_BYTES) throw new Error('该 EPUB 文件过大，暂不支持直接导入');
  const blob = await response.blob();
  if (blob.size === 0) throw new Error('下载的 EPUB 文件为空');
  if (blob.size > MAX_EPUB_BYTES) throw new Error('该 EPUB 文件过大，暂不支持直接导入');
  const parsed = await parse(new File([blob], `${safeFilename(result.title)}.epub`, { type: 'application/epub+zip' }));
  return {
    ...parsed,
    id: `gutenberg:${result.id}`,
    author: parsed.author || result.author,
    source: {
      provider: 'gutenberg',
      url: `https://www.gutenberg.org/ebooks/${result.id}`,
      license: 'Project Gutenberg 公版电子书；具体授权以作品页面说明为准',
    },
  };
}

function safeFilename(value: string): string {
  return value.replace(/[\\/:*?"<>|]/gu, '-').trim() || 'Project-Gutenberg';
}
