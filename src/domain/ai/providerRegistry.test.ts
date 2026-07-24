import { afterEach, describe, expect, it, vi } from 'vitest';

import { createTranslationEngine } from './providerRegistry';
import { ProviderConnectionError, ProviderRequestError, type TranslationRequest } from './translationTypes';
import type { ProviderProfile } from './providerProfile';

const request: TranslationRequest = {
  text: 'Good morning',
  sourceLanguage: 'en',
  targetLanguage: 'zh-CN',
  prompt: '保持文学语气',
  glossary: { AirRead: '灵阅' },
};

describe('translation provider registry', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('uses the first non-empty, non-echo result from the free chain', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ responseStatus: 200, responseData: { translatedText: 'Good morning' } }), { status: 200 }))
      .mockResolvedValueOnce(new Response('unavailable', { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify([[['早上好', 'Good morning', null, null, 10]], null, 'en']), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({ id: 'builtin-free', name: '免费翻译', kind: 'free', enabled: true });
    await expect(engine.translate(request)).resolves.toBe('早上好');
    expect(fetchMock).toHaveBeenCalledTimes(3);
    const fallbackUrl = new URL(fetchMock.mock.calls[2][0] as string);
    expect(`${fallbackUrl.origin}${fallbackUrl.pathname}`).toBe('https://translate.googleapis.com/translate_a/single');
    expect(Object.fromEntries(fallbackUrl.searchParams)).toMatchObject({
      client: 'gtx', sl: 'en', tl: 'zh-CN', dt: 't', q: 'Good morning',
    });
  });

  it('ignores MyMemory warning text and uses Autodetect when source language is empty', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        responseStatus: '403', responseData: { translatedText: 'MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS' },
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response('unavailable', { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify([[['早上好', 'Good morning']]]), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({ id: 'builtin-free', name: '免费翻译', kind: 'free', enabled: true });
    await expect(engine.translate({ ...request, sourceLanguage: undefined })).resolves.toBe('早上好');
    expect(decodeURIComponent(fetchMock.mock.calls[0][0] as string)).toContain('langpair=Autodetect|zh-CN');
  });

  it('classifies HTTP and malformed free responses as provider request errors', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response('rate limited', { status: 429 }))
      .mockResolvedValueOnce(new Response('{invalid-json', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({ id: 'builtin-free', name: '免费翻译', kind: 'free', enabled: true });
    await expect(engine.translate(request)).rejects.toBeInstanceOf(ProviderRequestError);
  });

  it('supports the legacy Azure Edge free route without a user key', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response('edge-token', { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify([{ translations: [{ text: '早上好' }] }]), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({ id: 'builtin-free', name: '免费翻译', kind: 'free', freeRoute: 'azure-edge', enabled: true });
    await expect(engine.translate(request)).resolves.toBe('早上好');
    expect(fetchMock.mock.calls[0][0]).toBe('https://edge.microsoft.com/translate/auth');
    expect(fetchMock.mock.calls[1][0]).toContain('https://api-edge.cognitive.microsofttranslator.com/translate');
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toMatchObject({ Authorization: 'Bearer edge-token' });
  });

  it('tries free routes in MyMemory, Azure Edge, then Google order', async () => {
    const actualNow = Date.now();
    vi.spyOn(Date, 'now').mockReturnValue(actualNow + 8 * 60 * 1000);
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ responseStatus: 429 }), { status: 200 }))
      .mockResolvedValueOnce(new Response('edge-token', { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify([{ translations: [{ text: 'Good morning' }] }]), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify([[['早上好']]]), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({ id: 'builtin-free', name: '免费翻译', kind: 'free', enabled: true });
    await expect(engine.translate(request)).resolves.toBe('早上好');
    expect(fetchMock.mock.calls).toHaveLength(4);
    expect(fetchMock.mock.calls[0][0]).toContain('api.mymemory.translated.net');
    expect(fetchMock.mock.calls[1][0]).toBe('https://edge.microsoft.com/translate/auth');
    expect(fetchMock.mock.calls[2][0]).toContain('api-edge.cognitive.microsofttranslator.com');
    expect(fetchMock.mock.calls[3][0]).toContain('translate.googleapis.com');
  });

  it('calls an OpenAI-compatible chat completion endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      choices: [{ message: { content: '早上好' } }],
    }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const profile: ProviderProfile = {
      id: 'openai', name: 'OpenAI', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1/', model: 'air-model', apiKey: 'sk-secret-value',
    };

    const engine = createTranslationEngine(profile);
    await expect(engine.translate(request)).resolves.toBe('早上好');
    expect(fetchMock).toHaveBeenCalledWith('https://models.example/v1/chat/completions', expect.objectContaining({
      method: 'POST',
      headers: expect.objectContaining({ Authorization: 'Bearer sk-secret-value' }),
    }));
    const body = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string) as { temperature: number };
    expect(body.temperature).toBe(0);
    expect(engine.cacheIdentity).not.toContain('sk-secret-value');
  });

  it('does not duplicate an OpenAI chat completions suffix', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      choices: [{ message: { content: '早上好' } }],
    }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({
      id: 'openai-endpoint', name: 'OpenAI', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1/chat/completions/', model: 'air-model', apiKey: 'secret',
    });
    await engine.translate(request);

    expect(fetchMock.mock.calls[0][0]).toBe('https://models.example/v1/chat/completions');
  });

  it('calls Anthropic Messages with browser-safe headers and content blocks', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ content: [{ type: 'text', text: '早上好' }] }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const engine = createTranslationEngine({ id: 'anthropic', name: 'Claude', kind: 'anthropic-messages', enabled: true, model: 'claude-3-5-sonnet', apiKey: 'anthropic-secret' });

    await expect(engine.translate(request)).resolves.toBe('早上好');
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.anthropic.com/v1/messages');
    expect(init.headers).toMatchObject({
      'x-api-key': 'anthropic-secret',
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
    });
    expect(JSON.parse(init.body as string)).toMatchObject({ model: 'claude-3-5-sonnet', max_tokens: 2048 });
  });

  it('calls OpenAI Responses with the Responses input shape', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ output_text: '早上好' }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const engine = createTranslationEngine({ id: 'responses', name: 'OpenAI Responses', kind: 'openai-responses', enabled: true, baseUrl: 'https://api.openai.com/v1', model: 'gpt-4.1-mini', apiKey: 'responses-secret' });

    await expect(engine.translate(request)).resolves.toBe('早上好');
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/responses');
    expect(init.headers).toMatchObject({ Authorization: 'Bearer responses-secret' });
    expect(JSON.parse(init.body as string)).toMatchObject({ model: 'gpt-4.1-mini', temperature: 0 });
  });

  it('keeps API keys out of cache identity while tracking profile and model changes', () => {
    const base: ProviderProfile = {
      id: 'profile-a', name: 'OpenAI', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1', model: 'model-a', apiKey: 'first-secret',
    };
    const identity = createTranslationEngine(base).cacheIdentity;

    expect(createTranslationEngine({ ...base, apiKey: 'second-secret' }).cacheIdentity).toBe(identity);
    expect(createTranslationEngine({ ...base, id: 'profile-b' }).cacheIdentity).not.toBe(identity);
    expect(createTranslationEngine({ ...base, model: 'model-b' }).cacheIdentity).not.toBe(identity);
    expect(identity).not.toContain('first-secret');
  });

  it('signs Tencent TMT requests with TC3 Web Crypto headers', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      Response: { TargetText: '早上好', RequestId: 'request-id' },
    }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({
      id: 'tencent', name: '腾讯翻译', kind: 'tencent-tmt', enabled: true,
      apiKey: 'secretId:secretKeyValue', region: 'ap-guangzhou',
    });
    await expect(engine.translate(request)).resolves.toBe('早上好');

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toMatch(/^TC3-HMAC-SHA256 Credential=secretId\//);
    expect(headers.Authorization).not.toContain('secretKeyValue');
    expect(headers['X-TC-Action']).toBe('TextTranslate');
    expect(headers['X-TC-Region']).toBe('ap-guangzhou');
  });

  it('maps traditional Chinese tags to the Tencent-supported zh-TW value', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      Response: { TargetText: '早安' },
    }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const engine = createTranslationEngine({
      id: 'tencent', name: '腾讯翻译', kind: 'tencent-tmt', enabled: true,
      apiKey: 'secretId:secretKeyValue', region: 'ap-guangzhou',
    });

    await engine.translate({ ...request, sourceLanguage: 'zh-Hant', targetLanguage: 'zh-TW' });
    const body = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string) as { Source: string; Target: string };
    expect(body).toMatchObject({ Source: 'zh-TW', Target: 'zh-TW' });
  });

  it('normalizes Web Crypto signing failures without leaking their reason or secret', async () => {
    const secret = 'secretKeyMustNeverLeak';
    vi.spyOn(crypto.subtle, 'digest').mockRejectedValue(new Error(`crypto failed for ${secret}`));
    const engine = createTranslationEngine({
      id: 'tencent', name: '腾讯翻译', kind: 'tencent-tmt', enabled: true,
      apiKey: `secretId:${secret}`, region: 'ap-guangzhou',
    });

    const error = await engine.translate(request).catch((reason: unknown) => reason);
    expect(error).toBeInstanceOf(ProviderRequestError);
    expect(String(error)).not.toContain(secret);
    expect(String(error)).not.toContain('crypto failed');
  });

  it('calls Azure Translator with local key and region headers', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify([
      { translations: [{ text: '早上好', to: 'zh-Hans' }] },
    ]), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({
      id: 'azure', name: 'Azure', kind: 'azure-translator', enabled: true,
      baseUrl: 'https://api.cognitive.microsofttranslator.com', apiKey: 'azure-secret', region: 'eastasia',
    });
    await expect(engine.translate(request)).resolves.toBe('早上好');

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toContain('/translate?api-version=3.0');
    expect(init.headers).toEqual(expect.objectContaining({
      'Ocp-Apim-Subscription-Key': 'azure-secret',
      'Ocp-Apim-Subscription-Region': 'eastasia',
    }));
  });

  it('supports Azure without a region and omits the region header', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify([
      { translations: [{ text: '早上好', to: 'zh-Hans' }] },
    ]), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const engine = createTranslationEngine({
      id: 'azure-global', name: 'Azure Global', kind: 'azure-translator', enabled: true,
      apiKey: 'azure-secret',
    });
    await engine.translate(request);

    const headers = (fetchMock.mock.calls[0][1] as RequestInit).headers as Record<string, string>;
    expect(headers['Ocp-Apim-Subscription-Region']).toBeUndefined();
  });

  it('calls Youdao with v3 signed form fields', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ translation: ['早上好'] }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const engine = createTranslationEngine({ id: 'youdao', name: '有道', kind: 'youdao', enabled: true, apiKey: 'app-key', appSecret: 'app-secret' });

    await expect(engine.translate(request)).resolves.toBe('早上好');
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://openapi.youdao.com/api');
    const body = new URLSearchParams(init.body as string);
    expect(body.get('appKey')).toBe('app-key');
    expect(body.get('signType')).toBe('v3');
    expect(body.get('curtime')).toBeTruthy();
    expect(body.get('salt')).toBeTruthy();
    expect(body.get('sign')).toMatch(/^[a-f0-9]{64}$/);
    expect(String(init.body)).not.toContain('app-secret');
  });

  it('calls DeepL Free with its auth header and target language', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ translations: [{ text: '早上好' }] }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const engine = createTranslationEngine({ id: 'deepl', name: 'DeepL', kind: 'deepl', enabled: true, apiKey: 'deepl-secret' });

    await expect(engine.translate(request)).resolves.toBe('早上好');
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api-free.deepl.com/v2/translate');
    expect(init.headers).toMatchObject({ Authorization: 'DeepL-Auth-Key deepl-secret' });
    expect(new URLSearchParams(init.body as string).get('target_lang')).toBe('ZH');
  });

  it('reports direct-browser CORS failures and never leaks keys or response bodies', async () => {
    const key = 'never-leak-this-key';
    const profile: ProviderProfile = {
      id: 'openai', name: 'OpenAI', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1', model: 'model', apiKey: key,
    };
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError(`Failed to fetch ${key}`)));

    const engine = createTranslationEngine(profile);
    const error = await engine.translate(request).catch((reason: unknown) => reason);
    expect(error).toBeInstanceOf(ProviderConnectionError);
    expect(String(error)).toContain('浏览器无法直接连接');
    expect(String(error)).not.toContain(key);
    expect(String(error)).not.toContain('/proxy');

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('sensitive response body', { status: 401 })));
    const httpError = await engine.translate(request).catch((reason: unknown) => reason);
    expect(httpError).toBeInstanceOf(ProviderRequestError);
    expect(String(httpError)).toContain('HTTP 401');
    expect(String(httpError)).not.toContain('sensitive response body');
  });
});
