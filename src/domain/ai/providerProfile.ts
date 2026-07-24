export type ProviderKind = 'free' | 'openai-compatible' | 'openai-responses' | 'anthropic-messages' | 'custom-http' | 'tencent-tmt' | 'azure-translator' | 'youdao' | 'deepl';
export type FreeTranslationRoute = 'mymemory' | 'google' | 'azure-edge' | 'auto';

export type ProviderProfile = {
  id: string;
  name: string;
  kind: ProviderKind;
  baseUrl?: string;
  model?: string;
  prompt?: string;
  apiKey?: string;
  appSecret?: string;
  region?: string;
  freeRoute?: FreeTranslationRoute;
  enabled: boolean;
  builtIn?: true;
};

export type ProviderValidationResult = {
  valid: boolean;
  errors: string[];
};

export const BUILT_IN_FREE_PROFILE: ProviderProfile = Object.freeze({
  id: 'builtin-free',
  name: '免费翻译',
  kind: 'free',
  freeRoute: 'auto',
  enabled: true,
  builtIn: true,
});

const isSafeProviderUrl = (value: string): boolean => {
  try {
    const url = new URL(value);
    if (url.protocol === 'https:') return true;
    return url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  } catch {
    return false;
  }
};

export const maskSecret = (secret?: string): string | undefined => {
  if (!secret) return secret;
  if (secret.length <= 6) return '••••••';
  return `${secret.slice(0, 3)}••••••••••${secret.slice(-3)}`;
};

export const isMaskedSecret = (secret?: string): boolean => {
  if (!secret) return false;
  return secret === '••••••' || /^.{3}•{10}.{3}$/u.test(secret);
};

export const maskProviderProfile = (profile: ProviderProfile): ProviderProfile => ({
  ...profile,
  apiKey: maskSecret(profile.apiKey),
  appSecret: maskSecret(profile.appSecret),
});

export const validateProviderProfile = (profile: ProviderProfile): ProviderValidationResult => {
  const errors: string[] = [];
  if (!profile.id.trim()) errors.push('请输入配置 ID');
  if (!profile.name.trim()) errors.push('请输入服务名称');
  if (isMaskedSecret(profile.apiKey)) errors.push('API Key 不能是掩码，请输入真实密钥');
  if (isMaskedSecret(profile.appSecret)) errors.push('应用密钥不能是掩码，请输入真实密钥');
  if ((profile.prompt?.length ?? 0) > 4_000) errors.push('翻译提示词不能超过 4000 个字符');

  if (profile.kind === 'openai-compatible') {
    if (!profile.baseUrl?.trim()) errors.push('请输入 Base URL');
    else if (!isSafeProviderUrl(profile.baseUrl)) errors.push('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
    if (!profile.model?.trim()) errors.push('请输入模型名称');
    if (!profile.apiKey?.trim()) errors.push('请输入 API Key');
  }

  if (profile.kind === 'openai-responses') {
    if (!profile.baseUrl?.trim()) errors.push('请输入 Base URL');
    else if (!isSafeProviderUrl(profile.baseUrl)) {
      errors.push('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
    }
    if (!profile.model?.trim()) errors.push('请输入模型名称');
    if (!profile.apiKey?.trim()) errors.push('请输入 API Key');
  }

  if (profile.kind === 'anthropic-messages') {
    if (profile.baseUrl?.trim() && !isSafeProviderUrl(profile.baseUrl)) {
      errors.push('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
    }
    if (!profile.model?.trim()) errors.push('请输入模型名称');
    if (!profile.apiKey?.trim()) errors.push('请输入 API Key');
  }

  if (profile.kind === 'custom-http') {
    if (!profile.baseUrl?.trim()) errors.push('请输入翻译接口 URL');
    else if (!isSafeProviderUrl(profile.baseUrl)) errors.push('翻译接口 URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
    if (!profile.apiKey?.trim()) errors.push('请输入 API Key');
  }

  if (profile.kind === 'tencent-tmt') {
    const secretParts = profile.apiKey?.split(':') ?? [];
    if (secretParts.length !== 2 || secretParts.some((part) => !part.trim())) {
      errors.push('腾讯云密钥格式应为 SecretId:SecretKey');
    }
    if (!profile.region?.trim()) errors.push('请输入腾讯云地域');
  }

  if (profile.kind === 'azure-translator') {
    if (!profile.apiKey?.trim()) errors.push('请输入 Azure Key');
    if (profile.baseUrl?.trim() && !isSafeProviderUrl(profile.baseUrl)) {
      errors.push('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
    }
  }

  if (profile.kind === 'youdao') {
    if (!profile.apiKey?.trim()) errors.push('请输入有道应用 ID（App Key）');
    if (!profile.appSecret?.trim()) errors.push('请输入有道应用密钥（App Secret）');
  }

  if (profile.kind === 'deepl' && !profile.apiKey?.trim()) {
    errors.push('请输入 DeepL API Key');
  }

  return { valid: errors.length === 0, errors };
};
