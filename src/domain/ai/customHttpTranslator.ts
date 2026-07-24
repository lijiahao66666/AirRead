import type { ProviderProfile } from './providerProfile';
import {
  assertSuccessfulResponse,
  connectionError,
  fetchWithTimeout,
  ProviderRequestError,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

type CustomTranslationResponse = {
  translation?: unknown;
  translatedText?: unknown;
  data?: { translation?: unknown; translatedText?: unknown };
};

const readTranslation = (payload: CustomTranslationResponse): string | undefined => {
  const candidates = [payload.translation, payload.translatedText, payload.data?.translation, payload.data?.translatedText];
  const translated = candidates.find((value): value is string => typeof value === 'string');
  return translated?.trim() || undefined;
};

export class CustomHttpTranslatorEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly profile: ProviderProfile) {
    this.cacheIdentity = [profile.kind, profile.id, profile.baseUrl ?? '', '', ''].join('|');
  }

  async translate(input: TranslationRequest): Promise<string> {
    let response: Response;
    try {
      response = await fetchWithTimeout(this.profile.baseUrl!, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.profile.apiKey!}`,
        },
        body: JSON.stringify({
          text: input.text,
          sourceLanguage: input.sourceLanguage ?? 'auto',
          targetLanguage: input.targetLanguage,
        }),
      });
    } catch {
      throw connectionError(this.profile.name);
    }
    assertSuccessfulResponse(response, this.profile.name);
    try {
      const payload = await response.json() as CustomTranslationResponse;
      const translated = readTranslation(payload);
      if (translated) return translated;
    } catch {
      // Normalize malformed provider responses below.
    }
    throw new ProviderRequestError(this.profile.name);
  }
}
