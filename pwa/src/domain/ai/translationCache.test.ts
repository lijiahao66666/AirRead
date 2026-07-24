import { beforeEach, describe, expect, it } from 'vitest';

import { createTranslationCacheKey, TranslationCache } from './translationCache';
import type { TranslationRequest } from './translationTypes';

const baseRequest: TranslationRequest = {
  text: 'A quiet morning', sourceLanguage: 'en', targetLanguage: 'zh-CN',
  prompt: '文学翻译', glossary: { morning: '清晨' },
};

describe('translation cache identity', () => {
  beforeEach(() => localStorage.clear());

  it('changes for profile, model, prompt, or glossary changes but not API key changes', async () => {
    const identityA = 'openai-compatible|profile-a|https://example.com/v1|model-a|';
    const identityB = 'openai-compatible|profile-b|https://example.com/v1|model-a|';
    const identityModel = 'openai-compatible|profile-a|https://example.com/v1|model-b|';

    const baseKey = await createTranslationCacheKey(identityA, baseRequest);
    expect(await createTranslationCacheKey(identityB, baseRequest)).not.toBe(baseKey);
    expect(await createTranslationCacheKey(identityModel, baseRequest)).not.toBe(baseKey);
    expect(await createTranslationCacheKey(identityA, { ...baseRequest, prompt: '直译' })).not.toBe(baseKey);
    expect(await createTranslationCacheKey(identityA, { ...baseRequest, glossary: { morning: '早晨' } })).not.toBe(baseKey);

    const unsafeIdentity = `${identityA}|sk-should-not-be-here`;
    expect(await createTranslationCacheKey(identityA, baseRequest)).not.toBe(await createTranslationCacheKey(unsafeIdentity, baseRequest));
    expect(baseKey).not.toContain(baseRequest.text);
  });

  it('persists translations without credentials and expires stale entries', async () => {
    let now = 1_000;
    const cache = new TranslationCache(localStorage, () => now, 100);
    await cache.set('free|builtin-free|||', baseRequest, '安静的清晨');
    await expect(cache.get('free|builtin-free|||', baseRequest)).resolves.toBe('安静的清晨');

    now = 1_101;
    await expect(cache.get('free|builtin-free|||', baseRequest)).resolves.toBeUndefined();
    expect(localStorage.getItem('airread.translationCache.v1')).not.toContain('apiKey');
  });
});
