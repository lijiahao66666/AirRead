import { Eye, EyeOff, FlaskConical, Save, X } from 'lucide-react';
import { useState } from 'react';

import { validateProviderProfile, type ProviderKind, type ProviderProfile } from '../../domain/ai/providerProfile';

export type ProviderEditorProps = {
  profile: ProviderProfile;
  validationProfile?: ProviderProfile;
  onChange: (profile: ProviderProfile) => void;
  onSave: () => void;
  onCancel: () => void;
  onTest: () => void;
  mode?: 'create' | 'edit';
  error?: string;
  testing?: boolean;
};

const kindLabels: Record<ProviderKind, string> = {
  free: '免费翻译',
  'openai-compatible': 'OpenAI 兼容模型',
  'tencent-tmt': '腾讯云翻译 TMT',
  'azure-translator': 'Azure 翻译',
};

export function ProviderEditor({ profile, validationProfile, onChange, onSave, onCancel, onTest, mode = 'edit', error, testing = false }: ProviderEditorProps) {
  const [secretVisible, setSecretVisible] = useState(false);
  const update = (patch: Partial<ProviderProfile>) => onChange({ ...profile, ...patch });
  const needsModel = profile.kind === 'openai-compatible';
  const needsUrl = profile.kind === 'openai-compatible' || profile.kind === 'azure-translator';
  const needsRegion = profile.kind === 'tencent-tmt' || profile.kind === 'azure-translator';
  const valid = validateProviderProfile(validationProfile ?? profile).valid;

  return <form className="provider-editor" onSubmit={(event) => { event.preventDefault(); onSave(); }}>
    <div className="settings-editor__header"><div><p className="eyebrow">翻译服务</p><h3>{mode === 'create' ? '添加翻译服务' : '编辑翻译服务'}</h3></div><button type="button" className="icon-button" onClick={onCancel} aria-label="关闭编辑器"><X size={18} /></button></div>
    <div className="settings-form-grid">
      <label>服务名称<input aria-label="服务名称" value={profile.name} onChange={(event) => update({ name: event.target.value })} placeholder="例如：我的模型服务" /></label>
      <label>服务类型<select aria-label="服务类型" value={profile.kind} onChange={(event) => update({ kind: event.target.value as ProviderKind })}>{Object.entries(kindLabels).filter(([kind]) => kind !== 'free').map(([kind, label]) => <option value={kind} key={kind}>{label}</option>)}</select></label>
      {needsUrl && <label className="settings-form-grid__wide">Base URL<input aria-label="Base URL" value={profile.baseUrl ?? ''} onChange={(event) => update({ baseUrl: event.target.value })} placeholder="https://..." /></label>}
      {needsModel && <label>模型名称<input aria-label="模型名称" value={profile.model ?? ''} onChange={(event) => update({ model: event.target.value })} placeholder="模型名称" /></label>}
      <label className={needsRegion ? '' : 'settings-form-grid__wide'}>API Key<input aria-label="API Key" type={secretVisible ? 'text' : 'password'} value={profile.apiKey ?? ''} onChange={(event) => update({ apiKey: event.target.value })} placeholder="只保存在当前浏览器" /><button type="button" className="secret-toggle" onClick={() => setSecretVisible((visible) => !visible)}>{secretVisible ? <><EyeOff size={15} /> 隐藏密钥</> : <><Eye size={15} /> 显示密钥</>}</button></label>
      {needsRegion && <label>{profile.kind === 'tencent-tmt' ? '腾讯云地域' : 'Azure 区域（可选）'}<input aria-label={profile.kind === 'tencent-tmt' ? '腾讯云地域' : 'Azure 区域（可选）'} value={profile.region ?? ''} onChange={(event) => update({ region: event.target.value })} placeholder={profile.kind === 'tencent-tmt' ? 'ap-guangzhou' : 'eastasia'} /></label>}
    </div>
    {profile.kind === 'azure-translator' && <p className="provider-editor__hint">Azure Translator F0 每月提供 200 万字符免费额度，但仍需要你自己的 Azure Translator 资源、Key 和账户额度；这不是 AirRead 提供的公共额度。</p>}
    {error && <div className="settings-alert" role="alert">{error}</div>}
    <div className="settings-editor__actions"><button type="button" className="secondary-button" onClick={onCancel}>取消</button><button type="button" className="secondary-button" onClick={onTest} disabled={testing || !valid}><FlaskConical size={16} /> {testing ? '测试中…' : '测试连接'}</button><button type="submit" className="primary-action" disabled={!valid}><Save size={16} /> 保存配置</button></div>
  </form>;
}
