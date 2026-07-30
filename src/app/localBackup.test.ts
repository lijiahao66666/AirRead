import { describe, expect, it } from 'vitest';

import type { Book } from '../domain/books/book';
import { createLocalBookBackup, mergeRestoredBooks, parseLocalBookBackup } from './localBackup';

const book = (id: string, importedAt: number): Book => ({
  id, title: `书籍 ${id}`, author: '', format: 'txt', bytes: new Uint8Array([1, 2, 3]), text: '正文', importedAt,
  readingChapter: 0, readingProgress: 0, generatedBilingual: false,
});

describe('local book backup', () => {
  it('round-trips books and excludes provider configuration by design', () => {
    const source = book('source', 10);
    source.excerpts = [{ id: 'excerpt', chapter: 0, paragraphId: 'p-1', sourceOffset: 0, source: '摘录', translation: 'translation', targetLanguage: 'en', createdAt: 11 }];

    const backup = createLocalBookBackup([source]);
    const restored = parseLocalBookBackup(JSON.stringify(backup));

    expect(backup).not.toHaveProperty('providers');
    expect(restored.books[0]).toMatchObject({ id: 'source', excerpts: source.excerpts });
    expect(restored.books[0].bytes).toEqual(new Uint8Array([1, 2, 3]));
  });

  it('rejects malformed book data and merges without deleting local-only books', () => {
    expect(() => parseLocalBookBackup('{"version":1,"books":[{"id":"bad"}]}')).toThrow('备份中包含无效书籍');

    const merged = mergeRestoredBooks([book('local-only', 1), book('same', 2)], [book('same', 5), book('restored', 4)]);

    expect(merged.map((item) => item.id)).toEqual(['same', 'restored', 'local-only']);
  });
});
