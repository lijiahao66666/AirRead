import { describe, expect, it } from 'vitest';

import type { Book } from './book';
import { createBookStore, type BookDatabase } from './bookStore';

describe('book store', () => {
  it('replaces matching books and lists the newest import first', async () => {
    const database = new MemoryBookDatabase();
    const store = createBookStore(async () => database);
    const older = makeBook('older', 100, [1, 2]);
    const newer = makeBook('newer', 200, [3, 4]);

    await store.saveBook(older);
    await store.saveBook(newer);
    await store.saveBook({ ...newer, title: 'Replaced' });

    const books = await store.listBooks();

    expect(books.map(({ id }) => id)).toEqual(['newer', 'older']);
    expect(books[0].title).toBe('Replaced');
  });

  it('round-trips binary book bytes without base64 conversion', async () => {
    const database = new MemoryBookDatabase();
    const store = createBookStore(async () => database);
    const source = makeBook('binary', 300, [0, 1, 2, 255]);

    await store.saveBook(source);
    source.bytes.fill(9);

    const [restored] = await store.listBooks();

    expect(restored.bytes).toBeInstanceOf(Uint8Array);
    expect([...restored.bytes]).toEqual([0, 1, 2, 255]);
  });

  it('deletes a book and updates reading progress', async () => {
    const database = new MemoryBookDatabase();
    const store = createBookStore(async () => database);
    const source = makeBook('progress', 300, [1]);

    await store.saveBook(source);
    await store.updateBook('progress', { readingChapter: 2, readingProgress: 0.45, readingAnchor: { chapter: 2, paragraphId: 'chapter-3-4', sourceOffset: 18 }, lastReadAt: 500 });
    expect((await store.listBooks())[0]).toMatchObject({ readingChapter: 2, readingProgress: 0.45, readingAnchor: { chapter: 2, paragraphId: 'chapter-3-4', sourceOffset: 18 }, lastReadAt: 500 });

    await store.deleteBook('progress');
    expect(await store.listBooks()).toEqual([]);
  });

  it('persists per-book translation preferences', async () => {
    const database = new MemoryBookDatabase();
    const store = createBookStore(async () => database);
    await store.saveBook(makeBook('preferences', 400, [1]));

    await store.updateBook('preferences', { translationPreferences: { sourceLanguage: 'auto', targetLanguage: 'ja' }, selectionPreferences: { targetLanguage: 'en' } });

    expect((await store.listBooks())[0]).toMatchObject({
      translationPreferences: { sourceLanguage: 'auto', targetLanguage: 'ja' },
      selectionPreferences: { targetLanguage: 'en' },
    });
  });
});

class MemoryBookDatabase implements BookDatabase {
  private readonly books = new Map<string, Book>();

  async getAll(): Promise<Book[]> {
    return [...this.books.values()].map((book) => structuredClone(book));
  }

  async put(_storeName: string, book: Book): Promise<void> {
    this.books.set(book.id, structuredClone(book));
  }

  async delete(_storeName: string, id: string): Promise<void> {
    this.books.delete(id);
  }
}

function makeBook(id: string, importedAt: number, bytes: number[]): Book {
  return {
    id,
    title: id,
    author: '',
    format: 'epub',
    bytes: new Uint8Array(bytes),
    importedAt,
    readingChapter: 0,
    readingProgress: 0,
    generatedBilingual: false,
  };
}
