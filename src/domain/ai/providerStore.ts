import {
  BUILT_IN_FREE_PROFILE,
  isMaskedSecret,
  maskSecret,
  validateProviderProfile,
  type ProviderKind,
  type ProviderProfile,
  type FreeTranslationRoute,
} from './providerProfile';

const PROFILES_KEY = 'airread.providerProfiles.v1';
const SELECTED_KEY = 'airread.selectedProvider.v1';
const PROVIDER_KINDS: ProviderKind[] = ['free', 'openai-compatible', 'tencent-tmt', 'azure-translator', 'youdao', 'deepl'];
const FREE_ROUTE_KEY = 'airread.freeTranslationRoute.v1';
const FREE_ROUTES: FreeTranslationRoute[] = ['mymemory', 'google', 'azure-edge', 'auto'];

type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

const isProfile = (value: unknown): value is ProviderProfile => {
  if (!value || typeof value !== 'object') return false;
  const profile = value as Partial<ProviderProfile>;
  return typeof profile.id === 'string'
    && typeof profile.name === 'string'
    && typeof profile.kind === 'string'
    && PROVIDER_KINDS.includes(profile.kind as ProviderKind)
    && typeof profile.enabled === 'boolean';
};

export class ProviderProfileStore {
  constructor(private readonly storage: StorageLike = window.localStorage) {}

  list(): ProviderProfile[] {
    return [{ ...BUILT_IN_FREE_PROFILE, freeRoute: this.getFreeRoute() }, ...this.readCustomProfiles()];
  }

  get(id: string): ProviderProfile | undefined {
    return this.list().find((profile) => profile.id === id);
  }

  selected(): ProviderProfile {
    const selectedId = this.storage.getItem(SELECTED_KEY);
    const selected = selectedId ? this.get(selectedId) : undefined;
    return selected?.enabled ? selected : this.list()[0];
  }

  getFreeRoute(): FreeTranslationRoute {
    const route = this.storage.getItem(FREE_ROUTE_KEY);
    return route && FREE_ROUTES.includes(route as FreeTranslationRoute) ? route as FreeTranslationRoute : BUILT_IN_FREE_PROFILE.freeRoute!;
  }

  setFreeRoute(route: FreeTranslationRoute): void {
    if (!FREE_ROUTES.includes(route)) throw new Error('免费翻译线路无效');
    this.storage.setItem(FREE_ROUTE_KEY, route);
  }

  select(id: string): void {
    const profile = this.get(id);
    if (!profile || !profile.enabled) throw new Error('只能选择已启用的 Provider');
    this.storage.setItem(SELECTED_KEY, id);
  }

  save(profile: ProviderProfile): void {
    if (profile.id === BUILT_IN_FREE_PROFILE.id || profile.builtIn) {
      throw new Error('内置免费翻译不能修改');
    }
    const profiles = this.readCustomProfiles();
    const index = profiles.findIndex((candidate) => candidate.id === profile.id);
    const existing = index === -1 ? undefined : profiles[index];
    const saved = { ...profile };
    if (isMaskedSecret(saved.apiKey)) {
      if (!existing?.apiKey || saved.apiKey !== maskSecret(existing.apiKey)) {
        throw new Error('掩码密钥不能用于新配置，请输入真实 API Key');
      }
      saved.apiKey = existing.apiKey;
    }
    if (isMaskedSecret(saved.appSecret)) {
      if (!existing?.appSecret || saved.appSecret !== maskSecret(existing.appSecret)) {
        throw new Error('掩码应用密钥不能用于新配置，请输入真实应用密钥');
      }
      saved.appSecret = existing.appSecret;
    }

    const validation = validateProviderProfile(saved);
    if (!validation.valid) throw new Error(`Provider 配置无效：${validation.errors.join('；')}`);

    delete saved.builtIn;
    if (index === -1) profiles.push(saved);
    else profiles[index] = saved;
    this.writeCustomProfiles(profiles);
  }

  remove(id: string): void {
    if (id === BUILT_IN_FREE_PROFILE.id) throw new Error('内置免费翻译不能删除');
    const profiles = this.readCustomProfiles().filter((profile) => profile.id !== id);
    this.writeCustomProfiles(profiles);
    if (this.storage.getItem(SELECTED_KEY) === id) this.storage.removeItem(SELECTED_KEY);
  }

  private readCustomProfiles(): ProviderProfile[] {
    const raw = this.storage.getItem(PROFILES_KEY);
    if (!raw) return [];
    try {
      const parsed: unknown = JSON.parse(raw);
      if (!Array.isArray(parsed)) return [];
      return parsed
        .filter(isProfile)
        .filter((profile) => profile.id !== BUILT_IN_FREE_PROFILE.id)
        .filter((profile) => validateProviderProfile(profile).valid);
    } catch {
      return [];
    }
  }

  private writeCustomProfiles(profiles: ProviderProfile[]): void {
    this.storage.setItem(PROFILES_KEY, JSON.stringify(profiles));
  }
}
