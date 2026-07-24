import {
  ProviderConnectionError,
  ProviderRequestError,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';

type FreeEndpoint = {
  buildUrl(request: TranslationRequest): string;
  read(json: unknown): string | undefined;
};

const endpoints: FreeEndpoint[] = [
  {
    buildUrl: (request) => {
      const pair = `${request.sourceLanguage || 'Autodetect'}|${request.targetLanguage}`;
      return `https://api.mymemory.translated.net/get?q=${encodeURIComponent(request.text)}&langpair=${encodeURIComponent(pair)}`;
    },
    read: (json) => {
      const value = json as { responseStatus?: unknown; responseData?: { translatedText?: unknown } };
      if (String(value.responseStatus) !== '200') return undefined;
      return typeof value.responseData?.translatedText === 'string' ? value.responseData.translatedText : undefined;
    },
  },
  {
    buildUrl: (request) => {
      const query = new URLSearchParams({
        client: 'gtx',
        sl: request.sourceLanguage || 'auto',
        tl: request.targetLanguage,
        dt: 't',
        q: request.text,
      });
      return `https://translate.googleapis.com/translate_a/single?${query}`;
    },
    read: (json) => {
      if (!Array.isArray(json) || !Array.isArray(json[0])) return undefined;
      const translated = json[0]
        .map((segment: unknown) => (Array.isArray(segment) && typeof segment[0] === 'string' ? segment[0] : ''))
        .join('')
        .trim();
      return translated || undefined;
    },
  },
];

export class FreeTranslationEngine implements TranslationEngine {
  readonly cacheIdentity = 'free|builtin-free|||';

  async translate(input: TranslationRequest): Promise<string> {
    const source = input.text.trim();
    let receivedProviderResponse = false;
    for (const endpoint of endpoints) {
      try {
        const response = await fetch(endpoint.buildUrl(input), { method: 'GET' });
        receivedProviderResponse = true;
        if (!response.ok) continue;
        const translated = endpoint.read(await response.json())?.trim();
        if (translated && translated !== source) return translated;
      } catch {
        // Continue through the free endpoint chain.
      }
    }
    if (receivedProviderResponse) throw new ProviderRequestError('免费翻译');
    throw new ProviderConnectionError('免费翻译');
  }
}
