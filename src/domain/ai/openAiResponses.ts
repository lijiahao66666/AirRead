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

const endpointUrl = (baseUrl: string): string => {
  const normalized = baseUrl.replace(/\/+$/, '');
  return normalized.endsWith('/responses') ? normalized : `${normalized}/responses`;
};

type ResponsesPayload = {
  output_text?: unknown;
  output?: Array<{ content?: Array<{ text?: unknown; type?: unknown }> }>;
};

export class OpenAiResponsesEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, profile.baseUrl ?? '', profile.model ?? '', profile.prompt ?? ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    let response: Response;
    try {
      response = await fetchWithTimeout(endpointUrl(this.profile.baseUrl!), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.profile.apiKey!}`,
        },
        body: JSON.stringify({
          model: this.profile.model,
          temperature: 0,
          input: createTranslationPrompt(input, this.profile.prompt),
        }),
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload = await response.json() as ResponsesPayload;
      const outputText = typeof payload.output_text === 'string'
        ? payload.output_text
        : payload.output?.flatMap((item) => item.content ?? [])
          .find((content) => content.type === 'output_text' && typeof content.text === 'string')?.text;
      if (typeof outputText === 'string' && outputText.trim()) return outputText.trim();
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
