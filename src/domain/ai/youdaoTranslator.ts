import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  ProviderRequestError,
  fetchWithTimeout,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

const endpoint = 'https://openapi.youdao.com/api';
const encoder = new TextEncoder();

const languageForYoudao = (language?: string): string => {
  const normalized = language?.toLowerCase();
  const languages: Record<string, string> = {
    'zh-cn': 'zh-CHS',
    'zh-tw': 'zh-CHT',
    en: 'en',
    ja: 'ja',
    ko: 'ko',
    fr: 'fr',
    de: 'de',
    es: 'es',
    ru: 'ru',
  };
  return (normalized && languages[normalized]) || normalized || 'auto';
};

const truncate = (value: string): string => value.length <= 20 ? value : `${value.slice(0, 10)}${value.length}${value.slice(-10)}`;

const hex = (bytes: ArrayBuffer): string => Array.from(new Uint8Array(bytes))
  .map((byte) => byte.toString(16).padStart(2, '0'))
  .join('');

const sha256 = async (value: string): Promise<string> => hex(await crypto.subtle.digest('SHA-256', encoder.encode(value)));

export class YoudaoTranslatorEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, endpoint, '', ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    const salt = `${Date.now()}${Math.random().toString(16).slice(2)}`;
    const curtime = String(Math.floor(Date.now() / 1000));
    const sign = await sha256(`${this.profile.apiKey}${truncate(input.text)}${salt}${curtime}${this.profile.appSecret}`);
    const body = new URLSearchParams({
      q: input.text,
      from: languageForYoudao(input.sourceLanguage),
      to: languageForYoudao(input.targetLanguage),
      appKey: this.profile.apiKey!,
      salt,
      sign,
      signType: 'v3',
      curtime,
      docType: 'json',
    });

    let response: Response;
    try {
      response = await fetchWithTimeout(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body,
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload = await response.json() as { translation?: unknown; errorCode?: unknown };
      const translated = Array.isArray(payload.translation) ? payload.translation.find((value): value is string => typeof value === 'string') : undefined;
      if (translated?.trim()) return translated.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
