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
