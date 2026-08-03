import { isMaskedSecret, maskSecret, validateProviderProfile, type ProviderKind, type ProviderProfile } from './providerProfile';

const PROFILES_KEY = 'airread.learningModelProfiles.v1';
const LEGACY_PROFILES_KEY = 'airread.providerProfiles.v1';
const SELECTED_KEY = 'airread.learningSelectedModel.v1';
const PROVIDER_KINDS: ProviderKind[] = ['openai-compatible', 'openai-responses', 'anthropic-messages'];

type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

const isProfile = (value: unknown): value is ProviderProfile => {
  if (!value || typeof value !== 'object') return false;
  const profile = value as Partial<ProviderProfile>;
  return typeof profile.id === 'string' && typeof profile.name === 'string' && PROVIDER_KINDS.includes(profile.kind as ProviderKind) && typeof profile.enabled === 'boolean';
};

export class ProviderProfileStore {
  constructor(private readonly storage: StorageLike = window.localStorage) {}

  list(): ProviderProfile[] {
    const profiles = this.readProfiles(PROFILES_KEY);
    if (profiles.length > 0) return profiles;
    const migrated = this.readProfiles(LEGACY_PROFILES_KEY);
    if (migrated.length > 0) this.writeProfiles(migrated);
    return migrated;
  }

  get(id: string): ProviderProfile | undefined {
    return this.list().find((profile) => profile.id === id);
  }

  selected(): ProviderProfile | undefined {
    const selectedId = this.storage.getItem(SELECTED_KEY);
    const selected = selectedId ? this.get(selectedId) : undefined;
    return selected?.enabled ? selected : this.list().find((profile) => profile.enabled);
  }

  select(id: string): void {
    const profile = this.get(id);
    if (!profile) throw new Error('模型服务不存在');
    this.storage.setItem(SELECTED_KEY, id);
  }

  save(profile: ProviderProfile): void {
    const profiles = this.list();
    const index = profiles.findIndex((candidate) => candidate.id === profile.id);
    const existing = index === -1 ? undefined : profiles[index];
    const saved = { ...profile };
    if (isMaskedSecret(saved.apiKey)) {
      if (!existing?.apiKey || saved.apiKey !== maskSecret(existing.apiKey)) throw new Error('请重新输入真实的 API Key');
      saved.apiKey = existing.apiKey;
    }
    const validation = validateProviderProfile(saved);
    if (!validation.valid) throw new Error(validation.errors.join('；'));
    if (index === -1) profiles.push(saved);
    else profiles[index] = saved;
    this.writeProfiles(profiles);
  }

  remove(id: string): void {
    this.writeProfiles(this.list().filter((profile) => profile.id !== id));
    if (this.storage.getItem(SELECTED_KEY) === id) this.storage.removeItem(SELECTED_KEY);
  }

  private readProfiles(key: string): ProviderProfile[] {
    const raw = this.storage.getItem(key);
    if (!raw) return [];
    try {
      const parsed: unknown = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed.filter(isProfile).filter((profile) => validateProviderProfile(profile).valid) : [];
    } catch {
      return [];
    }
  }

  private writeProfiles(profiles: ProviderProfile[]): void {
    this.storage.setItem(PROFILES_KEY, JSON.stringify(profiles));
  }
}
