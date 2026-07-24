import { useState } from 'react';
import { Check, CircleOff, Pencil, Plus, Power, ShieldCheck, Trash2 } from 'lucide-react';

import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { BUILT_IN_FREE_PROFILE, isMaskedSecret, maskProviderProfile, type ProviderProfile } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { ProviderConnectionError, type TranslationRequest } from '../../domain/ai/translationTypes';
import { ProviderEditor } from './ProviderEditor';
import './settings.css';

export type SettingsPageProps = {
  store?: ProviderProfileStore;
  testConnection?: (profile: ProviderProfile) => Promise<void>;
};

const testRequest: TranslationRequest = { text: 'AirRead', sourceLanguage: 'en', targetLanguage: 'zh-CN' };

export function SettingsPage({ store = new ProviderProfileStore(), testConnection = async (profile) => { await createTranslationEngine(profile).translate(testRequest); } }: SettingsPageProps) {
  const [profiles, setProfiles] = useState(() => store.list());
  const [selectedId, setSelectedId] = useState(() => store.selected().id);
  const [editing, setEditing] = useState<ProviderProfile>();
  const [editingOriginal, setEditingOriginal] = useState<ProviderProfile>();
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [testing, setTesting] = useState(false);
  const refresh = () => { setProfiles(store.list()); setSelectedId(store.selected().id); };
  const startCreate = () => { setError(undefined); setNotice(undefined); setEditingOriginal(undefined); setEditing({ id: `provider-${Date.now()}`, name: '', kind: 'openai-compatible', enabled: true }); };
  const startEdit = (profile: ProviderProfile) => { setError(undefined); setNotice(undefined); setEditingOriginal(profile); setEditing(maskProviderProfile(profile)); };
  const resolvedEditing = editing && isMaskedSecret(editing.apiKey) ? { ...editing, apiKey: editingOriginal?.apiKey } : editing;
  const save = () => {
    if (!editing) return;
    try { store.save(editing); setEditing(undefined); setEditingOriginal(undefined); setError(undefined); setNotice('配置已保存'); refresh(); } catch (cause) { setNotice(undefined); setError(cause instanceof Error ? cause.message : '保存配置失败'); }
  };
  const select = (profile: ProviderProfile) => { try { store.select(profile.id); refresh(); setNotice(`已选择 ${profile.name}`); } catch (cause) { setError(cause instanceof Error ? cause.message : '选择 Provider 失败'); } };
  const toggle = (profile: ProviderProfile) => { try { store.save({ ...profile, enabled: !profile.enabled }); refresh(); } catch (cause) { setError(cause instanceof Error ? cause.message : '更新 Provider 失败'); } };
  const remove = (profile: ProviderProfile) => { try { store.remove(profile.id); refresh(); setNotice('配置已删除'); } catch (cause) { setError(cause instanceof Error ? cause.message : '删除 Provider 失败'); } };
  const test = async () => {
    if (!resolvedEditing) return;
    setTesting(true); setError(undefined); setNotice(undefined);
    try { await testConnection(resolvedEditing); setNotice('连接成功'); }
    catch (cause) { setError(cause instanceof ProviderConnectionError ? '该翻译服务不允许浏览器直接连接。请使用支持网页调用的地址，或运行你自己的本地中转服务' : '连接测试失败，请检查翻译服务配置'); }
    finally { setTesting(false); }
  };

  return <section className="settings-page" aria-labelledby="settings-title">
    <header className="settings-page__header"><div><p className="eyebrow">翻译与隐私</p><h2 id="settings-title">设置</h2><p className="page-lede">翻译服务和密钥由你管理。AirRead 不会代你转发请求，也不会保存你的密钥。</p></div><ShieldCheck size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="settings-card settings-privacy"><ShieldCheck size={21} /><p>书籍和服务密钥只保存在当前浏览器。使用第三方翻译时，选中的文本会直接发送到该服务。</p></section>
    {notice && <div className="settings-notice" role="status">{notice}</div>}
    {error && !editing && <div className="settings-alert" role="alert">{error}</div>}
    <section className="settings-card"><div className="settings-card__heading"><div><p className="eyebrow">翻译服务</p><h3>服务配置</h3></div><button type="button" className="primary-action" onClick={startCreate}><Plus size={17} /> 添加翻译服务</button></div><div className="provider-list">{profiles.map((profile) => <article className={`provider-row ${profile.id === selectedId ? 'provider-row--selected' : ''}`} key={profile.id}><div className="provider-row__main"><span className="provider-row__icon">{profile.id === BUILT_IN_FREE_PROFILE.id ? <Check size={17} /> : <Power size={17} />}</span><div><h4>{profile.name}</h4><p>{profile.builtIn ? '免费 · 无需配置' : profile.kind === 'openai-compatible' ? `${profile.model || '未设置模型'} · ${profile.baseUrl || '未设置地址'}` : profile.kind === 'tencent-tmt' ? '腾讯云翻译 TMT' : 'Azure 翻译'}</p></div></div><div className="provider-row__status">{profile.enabled ? <span className="provider-enabled">{profile.id === selectedId ? '当前使用' : '已启用'}</span> : <span className="provider-disabled">已停用</span>}</div><div className="provider-row__actions">{profile.enabled && profile.id !== selectedId && <button type="button" className="text-button" onClick={() => select(profile)} aria-label={`设为当前 ${profile.name}`}>设为当前</button>}{!profile.builtIn && <><button type="button" className="icon-button" onClick={() => startEdit(profile)} aria-label={`编辑 ${profile.name}`}><Pencil size={16} /></button><button type="button" className="icon-button" onClick={() => toggle(profile)} aria-label={`${profile.enabled ? '停用' : '启用'} ${profile.name}`}><Power size={16} /></button><button type="button" className="icon-button" onClick={() => remove(profile)} aria-label={`删除 ${profile.name}`}><Trash2 size={16} /></button></>}</div></article>)}</div></section>
    {editing && <section className="settings-card"><ProviderEditor profile={editing} validationProfile={resolvedEditing} mode={editingOriginal ? 'edit' : 'create'} onChange={setEditing} onSave={save} onCancel={() => { setEditing(undefined); setEditingOriginal(undefined); setError(undefined); }} onTest={test} testing={testing} error={error} /></section>}
    <section className="settings-card settings-guidance"><div><p className="eyebrow">请求如何发送</p><h3>浏览器直接连接</h3><p>AirRead 会从当前浏览器直接请求你选择的服务，不经过 AirRead 服务器。部分服务不允许网页直接连接；若测试失败，请改用支持浏览器访问的地址，或在自己的设备上运行中转服务。</p></div><CircleOff size={28} aria-hidden="true" /></section>
  </section>;
}
