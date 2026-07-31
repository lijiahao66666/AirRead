import { parseBook } from '../../domain/books/bookParser';
import type { Book } from '../../domain/books/book';

const GUTENBERG_SEARCH_API = '/api/open-books/gutenberg/search';
const GUTENBERG_DOWNLOAD_API = '/api/open-books/gutenberg';
const MAX_EPUB_BYTES = 80 * 1024 * 1024;
const DOWNLOAD_CHUNK_BYTES = 256 * 1024;
const DOWNLOAD_RETRIES = 4;

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
  const bytes = await downloadGutenbergBytes(`${GUTENBERG_DOWNLOAD_API}/${encodeURIComponent(result.id)}.epub`, fetcher);
  const blob = new Blob([bytes.buffer as ArrayBuffer], { type: 'application/epub+zip' });
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

async function downloadGutenbergBytes(url: string, fetcher: Fetcher): Promise<Uint8Array> {
  let start = 0;
  let totalLength: number | undefined;
  const chunks: Uint8Array[] = [];

  while (totalLength === undefined || start < totalLength) {
    const end = totalLength === undefined ? DOWNLOAD_CHUNK_BYTES - 1 : Math.min(start + DOWNLOAD_CHUNK_BYTES - 1, totalLength - 1);
    const chunk = await fetchGutenbergChunk(url, start, end, fetcher);
    if (chunk.status === 200) {
      if (chunk.bytes.length === 0) throw new Error('下载的 EPUB 文件为空');
      if (chunk.bytes.length > MAX_EPUB_BYTES) throw new Error('该 EPUB 文件过大，暂不支持直接导入');
      return chunk.bytes;
    }
    totalLength = chunk.totalLength;
    if (totalLength > MAX_EPUB_BYTES) throw new Error('该 EPUB 文件过大，暂不支持直接导入');
    chunks.push(chunk.bytes);
    start += chunk.bytes.length;
    if (chunk.bytes.length === 0 || start > totalLength) throw new Error('EPUB 下载内容不完整，请稍后重试');
  }

  const bytes = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  if (bytes.length === 0) throw new Error('下载的 EPUB 文件为空');
  return bytes;
}

async function fetchGutenbergChunk(url: string, start: number, end: number, fetcher: Fetcher): Promise<{ status: number; bytes: Uint8Array; totalLength: number }> {
  let lastError: unknown;
  for (let attempt = 0; attempt < DOWNLOAD_RETRIES; attempt += 1) {
    try {
      const response = await fetcher(url, { headers: { Range: `bytes=${start}-${end}` } });
      if (!response.ok) throw new Error('该作品的 EPUB 暂时无法下载，请稍后重试');
      const contentRange = response.status === 206
        ? response.headers.get('content-range')?.match(/^bytes (\d+)-(\d+)\/(\d+)$/u)
        : undefined;
      const expectedLength = contentRange
        ? Number(contentRange[2]) - Number(contentRange[1]) + 1
        : Number(response.headers.get('content-length')) || undefined;
      const bytes = await readResponseBytes(response, expectedLength);
      if (response.status === 200) return { status: 200, bytes, totalLength: bytes.length };
      if (!contentRange || Number(contentRange[1]) !== start || Number(contentRange[2]) !== start + bytes.length - 1) {
        throw new Error('EPUB 下载内容不完整');
      }
      return { status: 206, bytes, totalLength: Number(contentRange[3]) };
    } catch (error) {
      lastError = error;
    }
  }
  if (lastError instanceof Error && lastError.message.includes('暂时无法下载')) throw lastError;
  throw new Error('EPUB 下载内容不完整，请稍后重试');
}

async function readResponseBytes(response: Response, expectedLength?: number): Promise<Uint8Array> {
  if (!response.body) return new Uint8Array(await response.arrayBuffer());
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalLength = 0;
  let streamError: unknown;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      if (!next.value) continue;
      chunks.push(next.value);
      totalLength += next.value.length;
    }
  } catch (error) {
    streamError = error;
  }
  if (streamError && expectedLength !== undefined && totalLength < expectedLength) throw streamError;
  const bytes = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

function safeFilename(value: string): string {
  return value.replace(/[\\/:*?"<>|]/gu, '-').trim() || 'Project-Gutenberg';
}
