import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  createTranslationPrompt,
  ProviderRequestError,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

const endpointUrl = (baseUrl: string): string => {
  const normalized = baseUrl.replace(/\/+$/, '');
  return normalized.endsWith('/chat/completions') ? normalized : `${normalized}/chat/completions`;
};

export class OpenAiCompatibleEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, profile.baseUrl ?? '', profile.model ?? '', profile.region ?? ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    let response: Response;
    try {
      response = await fetch(endpointUrl(this.profile.baseUrl!), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.profile.apiKey!}`,
        },
        body: JSON.stringify({
          model: this.profile.model,
          temperature: 0,
          messages: [{ role: 'user', content: createTranslationPrompt(input) }],
        }),
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload: unknown = await response.json();
      const content = (payload as { choices?: Array<{ message?: { content?: unknown } }> }).choices?.[0]?.message?.content;
      if (typeof content === 'string' && content.trim()) return content.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
