import { describe, expect, it } from 'vitest';

import {
  BUILT_IN_FREE_PROFILE,
  maskProviderProfile,
  validateProviderProfile,
  type ProviderProfile,
} from './providerProfile';

describe('provider profiles', () => {
  it('ships a built-in free profile with no credentials', () => {
    expect(BUILT_IN_FREE_PROFILE).toEqual({
      id: 'builtin-free',
      name: '免费翻译',
      kind: 'free',
      freeRoute: 'auto',
      enabled: true,
      builtIn: true,
    });
  });

  it('masks secrets without mutating the saved profile', () => {
    const profile: ProviderProfile = {
      id: 'openai-1',
      name: '我的模型',
      kind: 'openai-compatible',
      baseUrl: 'https://example.com/v1',
      model: 'reader-model',
      apiKey: 'sk-super-secret',
      enabled: true,
    };

    expect(maskProviderProfile(profile).apiKey).toBe('sk-••••••••••ret');
    expect(profile.apiKey).toBe('sk-super-secret');
  });

  it('validates provider-specific required fields and safe URLs', () => {
    expect(validateProviderProfile({
      id: 'openai-1', name: 'OpenAI', kind: 'openai-compatible', enabled: true,
    }).errors).toEqual(expect.arrayContaining(['请输入 Base URL', '请输入模型名称', '请输入 API Key']));

    expect(validateProviderProfile({
      id: 'bad-url', name: 'OpenAI', kind: 'openai-compatible', enabled: true,
      baseUrl: 'javascript:alert(1)', model: 'model', apiKey: 'secret',
    }).errors).toContain('Base URL 必须使用 HTTPS（本地开发可使用 HTTP localhost）');

    expect(validateProviderProfile({
      id: 'tencent', name: '腾讯', kind: 'tencent-tmt', enabled: true,
      apiKey: 'secret-id:secret-key', region: 'ap-guangzhou',
    }).valid).toBe(true);

    expect(validateProviderProfile({
      id: 'azure', name: 'Azure', kind: 'azure-translator', enabled: true,
      apiKey: 'azure-key',
    }).valid).toBe(true);

    expect(validateProviderProfile({
      id: 'youdao', name: '有道', kind: 'youdao', enabled: true,
      apiKey: 'app-key', appSecret: 'app-secret',
    }).valid).toBe(true);

    expect(validateProviderProfile({
      id: 'deepl', name: 'DeepL', kind: 'deepl', enabled: true,
      apiKey: 'deepl-key',
    }).valid).toBe(true);

    expect(validateProviderProfile({
      id: 'anthropic', name: 'Claude', kind: 'anthropic-messages', enabled: true,
      model: 'claude-3-5-sonnet', apiKey: 'anthropic-key',
    }).valid).toBe(true);

    expect(validateProviderProfile({
      id: 'responses', name: 'OpenAI Responses', kind: 'openai-responses', enabled: true,
      baseUrl: 'https://api.openai.com/v1', model: 'gpt-4.1-mini', apiKey: 'responses-key',
    }).valid).toBe(true);
  });

  it('requires both credentials for Youdao and a key for DeepL', () => {
    expect(validateProviderProfile({ id: 'youdao', name: '有道', kind: 'youdao', enabled: true, apiKey: 'app-key' }).errors).toContain('请输入有道应用密钥（App Secret）');
    expect(validateProviderProfile({ id: 'youdao', name: '有道', kind: 'youdao', enabled: true, appSecret: 'app-secret' }).errors).toContain('请输入有道应用 ID（App Key）');
    expect(validateProviderProfile({ id: 'deepl', name: 'DeepL', kind: 'deepl', enabled: true }).errors).toContain('请输入 DeepL API Key');
    expect(validateProviderProfile({ id: 'anthropic', name: 'Claude', kind: 'anthropic-messages', enabled: true, apiKey: 'key' }).errors).toContain('请输入模型名称');
    expect(validateProviderProfile({ id: 'responses', name: 'OpenAI Responses', kind: 'openai-responses', enabled: true, model: 'gpt-4.1-mini', apiKey: 'key' }).errors).toContain('请输入 Base URL');
  });

  it('masks both provider secrets', () => {
    const masked = maskProviderProfile({ id: 'youdao', name: '有道', kind: 'youdao', enabled: true, apiKey: 'app-key-value', appSecret: 'app-secret-value' });
    expect(masked.apiKey).toBe('app••••••••••lue');
    expect(masked.appSecret).toBe('app••••••••••lue');
  });

  it('rejects Tencent credentials with more than one separator', () => {
    const result = validateProviderProfile({
      id: 'tencent', name: '腾讯', kind: 'tencent-tmt', enabled: true,
      apiKey: 'secret-id:secret-key:extra', region: 'ap-guangzhou',
    });
    expect(result.valid).toBe(false);
    expect(result.errors).toContain('腾讯云密钥格式应为 SecretId:SecretKey');
  });
});
