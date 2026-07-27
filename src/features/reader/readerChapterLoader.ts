import type { Book, Chapter } from '../../domain/books/book';
import { chaptersForBook } from './readerState';

type WorkerResponse = { chapters?: Chapter[]; error?: string };

const chapterCache = new Map<string, Promise<Chapter[]>>();

const cacheKeyFor = (book: Book): string => `${book.id}:${book.importedAt}:${book.bytes.byteLength}`;

const parseInWorker = (book: Book): Promise<Chapter[]> => {
  if (book.format !== 'epub' || typeof Worker === 'undefined') {
    return Promise.resolve().then(() => chaptersForBook(book));
  }

  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./readerChapterWorker.ts', import.meta.url), { type: 'module' });
    worker.onmessage = (event: MessageEvent<WorkerResponse>) => {
      worker.terminate();
      if (event.data.chapters) resolve(event.data.chapters);
      else reject(new Error(event.data.error || '无法解析书籍章节'));
    };
    worker.onerror = () => {
      worker.terminate();
      reject(new Error('无法解析书籍章节'));
    };
    const bytes = Uint8Array.from(book.bytes);
    worker.postMessage({ ...book, bytes }, [bytes.buffer]);
  });
};

export function loadBookChapters(book: Book): Promise<Chapter[]> {
  const cacheKey = cacheKeyFor(book);
  const cached = chapterCache.get(cacheKey);
  if (cached) return cached;
  const loading = parseInWorker(book).catch((cause) => {
    chapterCache.delete(cacheKey);
    throw cause;
  });
  chapterCache.set(cacheKey, loading);
  return loading;
}
