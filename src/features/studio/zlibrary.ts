export type ZLibrarySource = {
  id: string;
  name: string;
  searchTemplate: string;
  builtIn?: boolean;
};

export const ZLIBRARY_SOURCES_STORAGE_KEY = 'airread.zlibrary.sources.v1';

export const ZLIBRARY_DEFAULT_SOURCE: ZLibrarySource = {
  id: 'zlibrary-default',
  name: 'Z-Library 预设入口',
  searchTemplate: 'https://singlelogin.re/s/{query}',
  builtIn: true,
};

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;

export function buildZLibrarySearchUrl(searchTemplate: string, query: string): string {
  const normalizedQuery = query.trim();
  if (!normalizedQuery) throw new Error('请输入书名、作者或 ISBN');
  const normalizedTemplate = validateZLibrarySearchTemplate(searchTemplate);
  return normalizedTemplate.replace('{query}', encodeURIComponent(normalizedQuery));
}

export function validateZLibrarySearchTemplate(value: string): string {
  const normalized = value.trim();
  if (!normalized.includes('{query}')) throw new Error('检索地址需要包含 {query}');
  let parsed: URL;
  try {
    parsed = new URL(normalized.replace('{query}', 'airread'));
  } catch {
    throw new Error('请输入完整的 HTTPS 检索地址');
  }
  if (parsed.protocol !== 'https:') throw new Error('书源地址必须使用 HTTPS');
  return normalized;
}

export function loadZLibrarySources(storage: Pick<Storage, 'getItem'>): ZLibrarySource[] {
  const stored = storage.getItem(ZLIBRARY_SOURCES_STORAGE_KEY);
  if (!stored) return [ZLIBRARY_DEFAULT_SOURCE];
  try {
    const parsed = JSON.parse(stored) as unknown;
    if (!Array.isArray(parsed)) return [ZLIBRARY_DEFAULT_SOURCE];
    const customSources = parsed.flatMap((item): ZLibrarySource[] => {
      if (!isSource(item) || item.id === ZLIBRARY_DEFAULT_SOURCE.id) return [];
      try {
        return [{ id: item.id, name: item.name.trim(), searchTemplate: validateZLibrarySearchTemplate(item.searchTemplate) }];
      } catch {
        return [];
      }
    });
    return [ZLIBRARY_DEFAULT_SOURCE, ...customSources];
  } catch {
    return [ZLIBRARY_DEFAULT_SOURCE];
  }
}

export function saveZLibrarySources(sources: ZLibrarySource[], storage: StorageLike): void {
  const customSources = sources
    .filter((source) => !source.builtIn && source.id !== ZLIBRARY_DEFAULT_SOURCE.id)
    .map((source) => ({ id: source.id, name: source.name.trim(), searchTemplate: validateZLibrarySearchTemplate(source.searchTemplate) }));
  storage.setItem(ZLIBRARY_SOURCES_STORAGE_KEY, JSON.stringify(customSources));
}

function isSource(value: unknown): value is ZLibrarySource {
  return typeof value === 'object' && value !== null
    && 'id' in value && typeof value.id === 'string'
    && 'name' in value && typeof value.name === 'string'
    && 'searchTemplate' in value && typeof value.searchTemplate === 'string';
}
