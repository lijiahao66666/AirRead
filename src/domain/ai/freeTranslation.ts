import {
  ProviderConnectionError,
  ProviderRequestError,
  fetchWithTimeout,
  type TranslationEngine,
  type TranslationRequest,
} from './translationTypes';
import type { FreeTranslationRoute } from './providerProfile';

type FreeEndpoint = {
  route: Exclude<FreeTranslationRoute, 'auto' | 'azure-edge'>;
  buildUrl(request: TranslationRequest): string;
  read(json: unknown): string | undefined;
};

const endpoints: FreeEndpoint[] = [
  {
    route: 'mymemory',
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
    route: 'google',
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

type AzureEdgeToken = { value: string; expiresAt: number };
let azureEdgeToken: AzureEdgeToken | undefined;

const languageForAzureEdge = (language: string): string => {
  if (language.toLowerCase() === 'zh-cn') return 'zh-Hans';
  if (language.toLowerCase() === 'zh-tw') return 'zh-Hant';
  return language;
};

const readAzureEdgeResponse = (json: unknown): string | undefined => {
  if (!Array.isArray(json)) return undefined;
  const translated = (json[0] as { translations?: Array<{ text?: unknown }> } | undefined)?.translations?.[0]?.text;
  return typeof translated === 'string' ? translated.trim() || undefined : undefined;
};

const getAzureEdgeToken = async (): Promise<string> => {
  if (azureEdgeToken && azureEdgeToken.expiresAt > Date.now()) return azureEdgeToken.value;
  const response = await fetchWithTimeout('https://edge.microsoft.com/translate/auth', { method: 'GET' });
  if (!response.ok) throw new Error(`Azure Edge token HTTP ${response.status}`);
  const value = (await response.text()).trim();
  if (!value) throw new Error('Azure Edge token empty');
  azureEdgeToken = { value, expiresAt: Date.now() + 7 * 60 * 1000 };
  return value;
};

export class FreeTranslationEngine implements TranslationEngine {
  readonly cacheIdentity: string;

  constructor(private readonly route: FreeTranslationRoute = 'auto') {
    this.cacheIdentity = route === 'auto' ? 'free|builtin-free|||' : `free|builtin-free|${route}||`;
  }

  async translate(input: TranslationRequest): Promise<string> {
    const source = input.text.trim();
    let receivedProviderResponse = false;
    const routes: FreeTranslationRoute[] = this.route === 'auto' ? ['mymemory', 'azure-edge', 'google'] : [this.route];
    for (const route of routes) {
      try {
        const endpoint = endpoints.find((candidate) => candidate.route === route);
        const response = route === 'azure-edge'
          ? await fetchWithTimeout(`https://api-edge.cognitive.microsofttranslator.com/translate?${new URLSearchParams({ 'api-version': '3.0', to: languageForAzureEdge(input.targetLanguage), ...(input.sourceLanguage ? { from: languageForAzureEdge(input.sourceLanguage) } : {}) })}`, {
            method: 'POST',
            headers: { Authorization: `Bearer ${await getAzureEdgeToken()}`, 'Content-Type': 'application/json' },
            body: JSON.stringify([{ Text: input.text }]),
          })
          : await fetchWithTimeout(endpoint!.buildUrl(input), { method: 'GET' });
        receivedProviderResponse = true;
        if (!response.ok) continue;
        const translated = route === 'azure-edge' ? readAzureEdgeResponse(await response.json()) : endpoint!.read(await response.json())?.trim();
        if (translated && translated !== source) return translated;
      } catch {
        if (route === 'azure-edge') azureEdgeToken = undefined;
        // Continue through the free endpoint chain.
      }
    }
    if (receivedProviderResponse) throw new ProviderRequestError('免费翻译');
    throw new ProviderConnectionError('免费翻译');
  }
}
