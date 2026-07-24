import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  ProviderRequestError,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

const languageForAzure = (language: string): string => {
  if (language.toLowerCase() === 'zh-cn') return 'zh-Hans';
  return language;
};

export class AzureTranslatorEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    const baseUrl = profile.baseUrl || 'https://api.cognitive.microsofttranslator.com';
    this.cacheIdentity = [profile.kind, profile.id, baseUrl, '', profile.region ?? ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    const baseUrl = (this.profile.baseUrl || 'https://api.cognitive.microsofttranslator.com').replace(/\/+$/, '');
    const query = new URLSearchParams({ 'api-version': '3.0', to: languageForAzure(input.targetLanguage) });
    if (input.sourceLanguage) query.set('from', languageForAzure(input.sourceLanguage));
    let response: Response;
    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Ocp-Apim-Subscription-Key': this.profile.apiKey!,
      };
      if (this.profile.region?.trim()) {
        headers['Ocp-Apim-Subscription-Region'] = this.profile.region.trim();
      }
      response = await fetch(`${baseUrl}/translate?${query}`, {
        method: 'POST',
        headers,
        body: JSON.stringify([{ text: input.text }]),
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload: unknown = await response.json();
      const translated = (payload as Array<{ translations?: Array<{ text?: unknown }> }>)[0]?.translations?.[0]?.text;
      if (typeof translated === 'string' && translated.trim()) return translated.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
