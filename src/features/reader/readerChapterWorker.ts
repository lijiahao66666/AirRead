import type { Book } from '../../domain/books/book';
import { chaptersForBook } from './readerState';

const workerScope = self as unknown as {
  onmessage: ((event: MessageEvent<Book>) => void) | null;
  postMessage: (message: unknown) => void;
};

workerScope.onmessage = (event) => {
  try {
    workerScope.postMessage({ chapters: chaptersForBook(event.data) });
  } catch (cause) {
    workerScope.postMessage({ error: cause instanceof Error ? cause.message : '无法解析书籍章节' });
  }
};
