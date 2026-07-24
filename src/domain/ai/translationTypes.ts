export type TranslationRequest = {
  text: string;
  sourceLanguage?: string;
  targetLanguage: string;
  prompt?: string;
  glossary?: Record<string, string>;
};

export interface TranslationEngine {
  readonly cacheIdentity: string;
  translate(input: TranslationRequest): Promise<string>;
}

export class ProviderConnectionError extends Error {
  constructor(providerName: string) {
    super(`${providerName}：浏览器无法直接连接。请检查网络、服务的 CORS 设置和 Base URL。AirRead 不会代你转发请求。`);
    this.name = 'ProviderConnectionError';
  }
}

export class ProviderRequestError extends Error {
  constructor(providerName: string, status?: number) {
    super(`${providerName} 请求失败${status ? `（HTTP ${status}）` : ''}，请检查本地 Provider 配置。`);
    this.name = 'ProviderRequestError';
  }
}

export const PROVIDER_REQUEST_TIMEOUT_MS = 15_000;

export const fetchWithTimeout = async (input: RequestInfo | URL, init: RequestInit = {}, timeoutMs = PROVIDER_REQUEST_TIMEOUT_MS): Promise<Response> => {
  const controller = new AbortController();
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    window.clearTimeout(timeoutId);
  }
};

export const assertSuccessfulResponse = (response: Response, providerName: string): void => {
  if (!response.ok) throw new ProviderRequestError(providerName, response.status);
};

export const connectionError = (providerName: string): ProviderConnectionError => (
  new ProviderConnectionError(providerName)
);

export const DEFAULT_TRANSLATION_INSTRUCTIONS = '你是一名专业翻译。请准确、自然地翻译，保留原文的含义、语气和段落结构，不添加解释，只返回译文。';

export const createTranslationPrompt = (request: TranslationRequest, providerInstructions?: string): string => {
  const glossary = Object.entries(request.glossary ?? {})
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([source, target]) => `${source} => ${target}`)
    .join('\n');
  const instructions = providerInstructions?.trim() || DEFAULT_TRANSLATION_INSTRUCTIONS;
  const taskInstructions = request.prompt?.trim();
  return [
    instructions,
    taskInstructions ? `附加要求：${taskInstructions}` : '',
    `源语言：${request.sourceLanguage || '自动识别'}`,
    `目标语言：${request.targetLanguage}`,
    glossary ? `术语表：\n${glossary}` : '',
    `原文：\n${request.text}`,
  ].filter(Boolean).join('\n\n');
};
