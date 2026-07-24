import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  ProviderRequestError,
  fetchWithTimeout,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

const defaultEndpoint = 'https://api-free.deepl.com';

const languageForDeepL = (language: string): string => {
  const normalized = language.toLowerCase();
  const languages: Record<string, string> = {
    'zh-cn': 'ZH',
    'zh-tw': 'ZH',
    en: 'EN-US',
    ja: 'JA',
    ko: 'KO',
    fr: 'FR',
    de: 'DE',
    es: 'ES',
    ru: 'RU',
  };
  return languages[normalized] || language.toUpperCase();
};

export class DeepLTranslatorEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, profile.baseUrl ?? defaultEndpoint, '', ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    const baseUrl = (this.profile.baseUrl || defaultEndpoint).replace(/\/+$/, '');
    const body = new URLSearchParams({
      text: input.text,
      target_lang: languageForDeepL(input.targetLanguage),
    });
    if (input.sourceLanguage) body.set('source_lang', languageForDeepL(input.sourceLanguage));

    let response: Response;
    try {
      response = await fetchWithTimeout(`${baseUrl}/v2/translate`, {
        method: 'POST',
        headers: {
          Authorization: `DeepL-Auth-Key ${this.profile.apiKey!}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body,
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload = await response.json() as { translations?: Array<{ text?: unknown }> };
      const translated = payload.translations?.[0]?.text;
      if (typeof translated === 'string' && translated.trim()) return translated.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
