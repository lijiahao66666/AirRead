export type ProviderKind = 'openai-compatible' | 'openai-responses' | 'anthropic-messages';

export type ProviderProfile = {
  id: string;
  name: string;
  kind: ProviderKind;
  baseUrl?: string;
  model?: string;
  prompt?: string;
  apiKey?: string;
  enabled: boolean;
};

export type ProviderValidationResult = {
  valid: boolean;
  errors: string[];
};

const isSafeProviderUrl = (value: string): boolean => {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname));
  } catch {
    return false;
  }
};

export const maskSecret = (secret?: string): string | undefined => {
  if (!secret) return secret;
  if (secret.length <= 6) return '••••••';
  return `${secret.slice(0, 3)}••••••••••${secret.slice(-3)}`;
};

export const isMaskedSecret = (secret?: string): boolean => Boolean(secret && (secret === '••••••' || /^.{3}•{10}.{3}$/u.test(secret)));

export const maskProviderProfile = (profile: ProviderProfile): ProviderProfile => ({ ...profile, apiKey: maskSecret(profile.apiKey) });

export const validateProviderProfile = (profile: ProviderProfile): ProviderValidationResult => {
  const errors: string[] = [];
  if (!profile.id.trim()) errors.push('模型配置缺少标识，请重新添加');
  if (!profile.name.trim()) errors.push('请输入服务名称');
  if (!profile.model?.trim()) errors.push('请输入模型名称');
  if (!profile.apiKey?.trim() || isMaskedSecret(profile.apiKey)) errors.push('请输入真实的 API Key');
  if ((profile.prompt?.length ?? 0) > 2_000) errors.push('额外提示词不能超过 2000 个字符');
  if (profile.kind === 'anthropic-messages') {
    if (profile.baseUrl?.trim() && !isSafeProviderUrl(profile.baseUrl)) errors.push('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
  } else if (!profile.baseUrl?.trim()) {
    errors.push('请输入 Base URL');
  } else if (!isSafeProviderUrl(profile.baseUrl)) {
    errors.push('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');
  }
  return { valid: errors.length === 0, errors };
};
