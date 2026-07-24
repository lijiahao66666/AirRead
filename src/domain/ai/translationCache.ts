import type { TranslationRequest } from './translationTypes';

const CACHE_KEY = 'airread.translationCache.v1';

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;
type CacheRecord = Record<string, { translation: string; expiresAt: number }>;

const stableGlossary = (glossary?: Record<string, string>): Array<[string, string]> => (
  Object.entries(glossary ?? {}).sort(([left], [right]) => left.localeCompare(right))
);

const toHex = (bytes: ArrayBuffer): string => Array.from(new Uint8Array(bytes))
  .map((byte) => byte.toString(16).padStart(2, '0'))
  .join('');

export const createTranslationCacheKey = async (
  cacheIdentity: string,
  request: TranslationRequest,
): Promise<string> => {
  const identity = JSON.stringify({
    provider: cacheIdentity,
    text: request.text,
    sourceLanguage: request.sourceLanguage ?? '',
    targetLanguage: request.targetLanguage,
    prompt: request.prompt ?? '',
    glossary: stableGlossary(request.glossary),
  });
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(identity));
  return `sha256:${toHex(digest)}`;
};

export class TranslationCache {
  constructor(
    private readonly storage: StorageLike = window.localStorage,
    private readonly now: () => number = Date.now,
    private readonly ttlMs = 30 * 24 * 60 * 60 * 1000,
  ) {}

  async get(cacheIdentity: string, request: TranslationRequest): Promise<string | undefined> {
    const records = this.read();
    const key = await createTranslationCacheKey(cacheIdentity, request);
    const record = records[key];
    if (!record) return undefined;
    if (record.expiresAt <= this.now()) {
      delete records[key];
      this.write(records);
      return undefined;
    }
    return record.translation;
  }

  async set(cacheIdentity: string, request: TranslationRequest, translation: string): Promise<void> {
    const records = this.read();
    const key = await createTranslationCacheKey(cacheIdentity, request);
    records[key] = { translation, expiresAt: this.now() + this.ttlMs };
    this.write(records);
  }

  private read(): CacheRecord {
    const raw = this.storage.getItem(CACHE_KEY);
    if (!raw) return {};
    try {
      const parsed: unknown = JSON.parse(raw);
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed as CacheRecord : {};
    } catch {
      return {};
    }
  }

  private write(records: CacheRecord): void {
    this.storage.setItem(CACHE_KEY, JSON.stringify(records));
  }
}
