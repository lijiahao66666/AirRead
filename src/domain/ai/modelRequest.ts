export class ModelConnectionError extends Error {
  constructor(providerName: string) {
    super(`${providerName}：浏览器无法直接连接。请检查网络、CORS 设置和 Base URL。AirRead 不会代你转发请求。`);
    this.name = 'ModelConnectionError';
  }
}

export class ModelRequestError extends Error {
  constructor(providerName: string, status?: number) {
    super(`${providerName} 请求未成功${status ? `（HTTP ${status}）` : ''}，请检查模型配置后重试。`);
    this.name = 'ModelRequestError';
  }
}

export const fetchWithTimeout = async (input: RequestInfo | URL, init: RequestInit = {}, timeoutMs = 40_000): Promise<Response> => {
  const controller = new AbortController();
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    window.clearTimeout(timeoutId);
  }
};

export const assertSuccessfulResponse = (response: Response, providerName: string): void => {
  if (!response.ok) throw new ModelRequestError(providerName, response.status);
};
