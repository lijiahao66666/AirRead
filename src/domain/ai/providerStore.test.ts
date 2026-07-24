import { beforeEach, describe, expect, it } from 'vitest';

import { BUILT_IN_FREE_PROFILE, maskProviderProfile, type ProviderProfile } from './providerProfile';
import { ProviderProfileStore } from './providerStore';

describe('ProviderProfileStore', () => {
  beforeEach(() => localStorage.clear());

  it('always includes the free profile and selects it by default', () => {
    const store = new ProviderProfileStore(localStorage);

    expect(store.list()).toEqual([BUILT_IN_FREE_PROFILE]);
    expect(store.selected()).toEqual(BUILT_IN_FREE_PROFILE);
  });

  it('persists CRUD and selection locally', () => {
    const profile: ProviderProfile = {
      id: 'custom-openai', name: '自定义模型', kind: 'openai-compatible',
      baseUrl: 'https://models.example/v1', model: 'air-reader', apiKey: 'secret', enabled: true,
    };
    const store = new ProviderProfileStore(localStorage);
    store.save(profile);
    store.select(profile.id);

    const reloaded = new ProviderProfileStore(localStorage);
    expect(reloaded.selected()).toEqual(profile);

    reloaded.save({ ...profile, name: '更新后的模型', enabled: false });
    expect(reloaded.get(profile.id)?.name).toBe('更新后的模型');
    expect(reloaded.selected()).toEqual(BUILT_IN_FREE_PROFILE);

    reloaded.remove(profile.id);
    expect(reloaded.get(profile.id)).toBeUndefined();
  });

  it('protects the built-in profile and rejects invalid profiles', () => {
    const store = new ProviderProfileStore(localStorage);
    expect(() => store.remove(BUILT_IN_FREE_PROFILE.id)).toThrow('内置免费翻译不能删除');
    expect(() => store.save({
      id: 'invalid', name: '', kind: 'openai-compatible', enabled: true,
    })).toThrow('Provider 配置无效');
  });

  it('preserves an existing API key when a masked profile is saved', () => {
    const store = new ProviderProfileStore(localStorage);
    const profile: ProviderProfile = {
      id: 'masked-update', name: '原名称', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1', model: 'reader', apiKey: 'sk-real-secret',
    };
    store.save(profile);

    const masked = maskProviderProfile(profile);
    store.save({ ...masked, name: '新名称' });

    expect(store.get(profile.id)).toEqual({ ...profile, name: '新名称' });
    expect(localStorage.getItem('airread.providerProfiles.v1')).toContain('sk-real-secret');
    expect(localStorage.getItem('airread.providerProfiles.v1')).not.toContain('••••');
  });

  it('rejects a masked secret for a profile that has no saved credential', () => {
    const store = new ProviderProfileStore(localStorage);
    expect(() => store.save({
      id: 'new-masked', name: '错误配置', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1', model: 'reader', apiKey: 'sk-••••••••••ret',
    })).toThrow('掩码密钥不能用于新配置');
  });

  it('recovers from malformed local data without exposing it', () => {
    localStorage.setItem('airread.providerProfiles.v1', '{not-json');
    const store = new ProviderProfileStore(localStorage);
    expect(store.list()).toEqual([BUILT_IN_FREE_PROFILE]);
  });

  it('filters shape-valid profiles that fail provider-specific validation', () => {
    const valid: ProviderProfile = {
      id: 'valid-openai', name: '有效配置', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1', model: 'reader', apiKey: 'real-secret',
    };
    localStorage.setItem('airread.providerProfiles.v1', JSON.stringify([
      { id: 'incomplete', name: '不完整配置', kind: 'openai-compatible', enabled: true },
      { id: 'bad-tencent', name: '坏腾讯配置', kind: 'tencent-tmt', enabled: true, apiKey: 'not-a-pair', region: 'ap-guangzhou' },
      valid,
    ]));
    localStorage.setItem('airread.selectedProvider.v1', 'incomplete');

    const store = new ProviderProfileStore(localStorage);
    expect(store.list()).toEqual([BUILT_IN_FREE_PROFILE, valid]);
    expect(store.selected()).toEqual(BUILT_IN_FREE_PROFILE);
  });
});
