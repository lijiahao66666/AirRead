import { describe, expect, it } from 'vitest';

import { buildZLibrarySearchUrl, loadZLibrarySources, saveZLibrarySources, validateZLibrarySearchTemplate, ZLIBRARY_DEFAULT_SOURCE } from './zlibrary';

class MemoryStorage {
  private readonly values = new Map<string, string>();

  getItem(key: string) { return this.values.get(key) ?? null; }
  setItem(key: string, value: string) { this.values.set(key, value); }
}

describe('Z-Library source configuration', () => {
  it('encodes queries into the configured source template', () => {
    expect(buildZLibrarySearchUrl('https://library.example/s/{query}', '三体 第一部')).toBe('https://library.example/s/%E4%B8%89%E4%BD%93%20%E7%AC%AC%E4%B8%80%E9%83%A8');
  });

  it('accepts only HTTPS templates containing the search placeholder', () => {
    expect(validateZLibrarySearchTemplate('https://library.example/s/{query}')).toBe('https://library.example/s/{query}');
    expect(() => validateZLibrarySearchTemplate('http://library.example/s/{query}')).toThrow('HTTPS');
    expect(() => validateZLibrarySearchTemplate('https://library.example/search')).toThrow('{query}');
  });

  it('persists custom mirrors locally without overwriting the built-in entry', () => {
    const storage = new MemoryStorage();
    saveZLibrarySources([ZLIBRARY_DEFAULT_SOURCE, { id: 'mirror-1', name: '我的镜像', searchTemplate: 'https://mirror.example/s/{query}' }], storage);

    expect(loadZLibrarySources(storage)).toEqual([ZLIBRARY_DEFAULT_SOURCE, { id: 'mirror-1', name: '我的镜像', searchTemplate: 'https://mirror.example/s/{query}' }]);
  });

  it('ignores malformed saved sources and restores the default entry', () => {
    const storage = new MemoryStorage();
    storage.setItem('airread.zlibrary.sources.v1', JSON.stringify([{ id: 'bad', name: 'Bad', searchTemplate: 'http://bad.example/s/{query}' }]));

    expect(loadZLibrarySources(storage)).toEqual([ZLIBRARY_DEFAULT_SOURCE]);
  });
});
