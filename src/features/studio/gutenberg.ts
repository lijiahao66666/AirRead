import { parseBook } from '../../domain/books/bookParser';
import type { Book } from '../../domain/books/book';

const GUTENBERG_SEARCH_API = '/api/open-books/gutenberg/search';
const GUTENBERG_DOWNLOAD_API = '/api/open-books/gutenberg/file';
const MAX_EPUB_BYTES = 80 * 1024 * 1024;
const DOWNLOAD_CHUNK_BYTES = 64 * 1024;
const DOWNLOAD_RETRIES = 8;
const DOWNLOAD_CONCURRENCY = 1;
const DOWNLOAD_REQUEST_TIMEOUT_MS = 12_000;

export type GutenbergSearchResult = {
  id: string;
  title: string;
  author: string;
  downloads: string;
};

type Fetcher = typeof fetch;
type ResponseBytes = { bytes: Uint8Array; complete: boolean; error?: unknown };

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
  const bookId = encodeURIComponent(result.id);
  const bytes = await downloadGutenbergBytes(`${GUTENBERG_DOWNLOAD_API}/${bookId}/pg${bookId}.epub`, fetcher);
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
  const firstChunk = await fetchGutenbergChunk(url, 0, DOWNLOAD_CHUNK_BYTES - 1, fetcher);
  if (firstChunk.status === 200) {
    if (firstChunk.bytes.length === 0) throw new Error('下载的 EPUB 文件为空');
    if (firstChunk.bytes.length > MAX_EPUB_BYTES) throw new Error('该 EPUB 文件过大，暂不支持直接导入');
    return firstChunk.bytes;
  }
  const totalLength = firstChunk.totalLength;
  if (totalLength > MAX_EPUB_BYTES) throw new Error('该 EPUB 文件过大，暂不支持直接导入');
  const ranges: Array<{ start: number; end: number }> = [];
  for (let start = firstChunk.bytes.length; start < totalLength; start += DOWNLOAD_CHUNK_BYTES) {
    ranges.push({ start, end: Math.min(start + DOWNLOAD_CHUNK_BYTES - 1, totalLength - 1) });
  }
  const remainingChunks = await downloadGutenbergChunks(url, ranges, fetcher);
  const chunks = [firstChunk.bytes, ...remainingChunks];

  const bytes = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  if (bytes.length === 0) throw new Error('下载的 EPUB 文件为空');
  return bytes;
}

async function downloadGutenbergChunks(url: string, ranges: Array<{ start: number; end: number }>, fetcher: Fetcher): Promise<Uint8Array[]> {
  const results: Uint8Array[] = new Array(ranges.length);
  let nextIndex = 0;
  const worker = async () => {
    while (nextIndex < ranges.length) {
      const index = nextIndex;
      nextIndex += 1;
      const range = ranges[index];
      results[index] = (await fetchGutenbergChunk(url, range.start, range.end, fetcher)).bytes;
    }
  };
  await Promise.all(Array.from({ length: Math.min(DOWNLOAD_CONCURRENCY, ranges.length) }, worker));
  return results;
}

async function fetchGutenbergChunk(url: string, start: number, end: number, fetcher: Fetcher): Promise<{ status: number; bytes: Uint8Array; totalLength: number }> {
  let cursor = start;
  let targetEnd = end;
  let totalLength = 0;
  const chunks: Uint8Array[] = [];
  let lastError: unknown;
  for (let attempt = 0; attempt < DOWNLOAD_RETRIES; attempt += 1) {
    const controller = typeof AbortController === 'undefined' ? undefined : new AbortController();
    const timeout = controller ? setTimeout(() => controller.abort(), DOWNLOAD_REQUEST_TIMEOUT_MS) : undefined;
    try {
      const response = await fetcher(url, {
        headers: { Range: `bytes=${cursor}-${targetEnd}` },
        ...(controller ? { signal: controller.signal } : {}),
      });
      if (!response.ok) throw new Error('该作品的 EPUB 暂时无法下载，请稍后重试');
      const contentRange = response.status === 206
        ? response.headers.get('content-range')?.match(/^bytes (\d+)-(\d+)\/(\d+)$/u)
        : undefined;
      const expectedLength = contentRange
        ? Number(contentRange[2]) - Number(contentRange[1]) + 1
        : Number(response.headers.get('content-length')) || undefined;
      const result = await readResponseBytes(response, expectedLength);
      if (response.status === 200) {
        if (!result.complete) throw result.error ?? new Error('EPUB 下载内容不完整');
        if (cursor === 0) return { status: 200, bytes: result.bytes, totalLength: result.bytes.length };
        if (result.bytes.length < end + 1) throw new Error('EPUB 下载内容不完整');
        return { status: 200, bytes: result.bytes.slice(start, end + 1), totalLength: result.bytes.length };
      }
      if (!contentRange || Number(contentRange[1]) !== cursor || Number(contentRange[2]) < cursor || Number(contentRange[2]) > end) {
        throw new Error('EPUB 下载内容不完整');
      }
      totalLength = Number(contentRange[3]);
      targetEnd = Math.min(targetEnd, totalLength - 1);
      if (result.bytes.length === 0) throw result.error ?? new Error('EPUB 下载内容不完整');
      chunks.push(result.bytes);
      cursor += result.bytes.length;
      if (cursor > targetEnd) {
        return { status: 206, bytes: joinBytes(chunks), totalLength };
      }
      lastError = result.error ?? new Error('EPUB 下载内容不完整');
    } catch (error) {
      lastError = error;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }
  if (lastError instanceof Error && lastError.message.includes('暂时无法下载')) throw lastError;
  throw new Error('EPUB 下载内容不完整，请稍后重试');
}

async function readResponseBytes(response: Response, expectedLength?: number): Promise<ResponseBytes> {
  if (!response.body) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    return { bytes, complete: expectedLength === undefined || bytes.length >= expectedLength };
  }
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
  const bytes = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return {
    bytes,
    complete: expectedLength === undefined || totalLength >= expectedLength,
    error: streamError,
  };
}

function joinBytes(chunks: Uint8Array[]): Uint8Array {
  const bytes = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
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
