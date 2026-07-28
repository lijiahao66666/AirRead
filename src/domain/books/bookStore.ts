import { openDB, type DBSchema } from 'idb';

import { cloneBook, type Book } from './book';

const DATABASE_NAME = 'airread-local-v1';
const BOOKS_STORE = 'books';

interface AirReadDatabase extends DBSchema {
  books: {
    key: string;
    value: Book;
  };
}

export interface BookDatabase {
  getAll(): Promise<Book[]>;
  put(storeName: string, book: Book): Promise<void>;
  delete(storeName: string, id: string): Promise<void>;
}

export type OpenBookDatabase = () => Promise<BookDatabase>;

const openBookDatabase: OpenBookDatabase = async () => {
  const database = await openDB<AirReadDatabase>(DATABASE_NAME, 1, {
    upgrade(db) {
      if (!db.objectStoreNames.contains(BOOKS_STORE)) {
        db.createObjectStore(BOOKS_STORE, { keyPath: 'id' });
      }
    },
  });
  return {
    getAll: () => database.getAll(BOOKS_STORE),
    put: async (storeName, book) => {
      await database.put(storeName as 'books', book);
    },
    delete: async (storeName, id) => {
      await database.delete(storeName as 'books', id);
    },
  };
};

export function createBookStore(open: OpenBookDatabase = openBookDatabase) {
  let database: Promise<BookDatabase> | undefined;
  const getDatabase = () => database ??= open();

  return {
    async saveBook(book: Book): Promise<void> {
      await (await getDatabase()).put(BOOKS_STORE, cloneBook(book));
    },
    async listBooks(): Promise<Book[]> {
      const books = await (await getDatabase()).getAll();
      return books
        .map(cloneBook)
        .sort((left, right) => right.importedAt - left.importedAt);
    },
    async updateBook(id: string, updates: Partial<Pick<Book, 'lastReadAt' | 'readingChapter' | 'readingProgress' | 'readingAnchor' | 'bookmarks' | 'generatedBilingual' | 'translationPreferences' | 'selectionPreferences'>>): Promise<void> {
      const current = (await (await getDatabase()).getAll()).find((book) => book.id === id);
      if (!current) throw new Error('书籍不存在');
      await (await getDatabase()).put(BOOKS_STORE, cloneBook({ ...current, ...updates }));
    },
    async deleteBook(id: string): Promise<void> {
      await (await getDatabase()).delete(BOOKS_STORE, id);
    },
  };
}

const defaultStore = createBookStore();

export const saveBook = defaultStore.saveBook;
export const listBooks = defaultStore.listBooks;
export const updateBook = defaultStore.updateBook;
export const deleteBook = defaultStore.deleteBook;
