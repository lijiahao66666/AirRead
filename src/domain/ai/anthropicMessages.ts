import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  createTranslationPrompt,
  fetchWithTimeout,
  ProviderRequestError,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

const defaultEndpoint = 'https://api.anthropic.com';

const endpointUrl = (baseUrl: string): string => {
  const normalized = baseUrl.replace(/\/+$/, '');
  return normalized.endsWith('/v1/messages') ? normalized : `${normalized}/v1/messages`;
};

export class AnthropicMessagesEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, profile.baseUrl ?? defaultEndpoint, profile.model ?? '', ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    let response: Response;
    try {
      response = await fetchWithTimeout(endpointUrl(this.profile.baseUrl || defaultEndpoint), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': this.profile.apiKey!,
          'anthropic-version': '2023-06-01',
          'anthropic-dangerous-direct-browser-access': 'true',
        },
        body: JSON.stringify({
          model: this.profile.model,
          max_tokens: 2048,
          temperature: 0,
          messages: [{ role: 'user', content: createTranslationPrompt(input) }],
        }),
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload = await response.json() as { content?: Array<{ type?: unknown; text?: unknown }> };
      const translated = payload.content?.find((item) => item.type === 'text' && typeof item.text === 'string')?.text;
      if (typeof translated === 'string' && translated.trim()) return translated.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
