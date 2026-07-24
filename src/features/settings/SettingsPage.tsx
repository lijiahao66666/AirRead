import { useEffect, useMemo, useState } from 'react';
import { Check, CircleOff, Headphones, Pencil, Plus, Power, ShieldCheck, Trash2 } from 'lucide-react';

import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { BUILT_IN_FREE_PROFILE, isMaskedSecret, maskProviderProfile, type ProviderProfile } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { ProviderConnectionError, type TranslationRequest } from '../../domain/ai/translationTypes';
import {
  availableSpeechVoices,
  findSpeechVoice,
  languageLabel,
  READER_LANGUAGE_OPTIONS,
  ReaderPreferencesStore,
  speechLocaleForLanguage,
  SPEECH_RATE_OPTIONS,
  type ReaderPreferences,
} from '../reader/readerPreferences';
import { ProviderEditor } from './ProviderEditor';
import './settings.css';

export type SettingsPageProps = {
  store?: ProviderProfileStore;
  readerStore?: ReaderPreferencesStore;
  testConnection?: (profile: ProviderProfile) => Promise<void>;
};

const testRequest: TranslationRequest = { text: 'AirRead', sourceLanguage: 'en', targetLanguage: 'zh-CN' };

export function SettingsPage({ store = new ProviderProfileStore(), readerStore, testConnection = async (profile) => { await createTranslationEngine(profile).translate(testRequest); } }: SettingsPageProps) {
  const preferencesStore = useMemo(() => readerStore ?? new ReaderPreferencesStore(), [readerStore]);
  const [profiles, setProfiles] = useState(() => store.list());
  const [selectedId, setSelectedId] = useState(() => store.selected().id);
  const [editing, setEditing] = useState<ProviderProfile>();
  const [editingOriginal, setEditingOriginal] = useState<ProviderProfile>();
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [testing, setTesting] = useState(false);
  const [readerPreferences, setReaderPreferences] = useState<ReaderPreferences>(() => preferencesStore.get());
  const [speechVoices, setSpeechVoices] = useState<SpeechSynthesisVoice[]>([]);
  const speechSupported = typeof window.speechSynthesis !== 'undefined' && typeof window.SpeechSynthesisUtterance !== 'undefined';
  useEffect(() => {
    if (!speechSupported) return undefined;
    const refreshVoices = () => setSpeechVoices(availableSpeechVoices());
    refreshVoices();
    window.speechSynthesis.addEventListener?.('voiceschanged', refreshVoices);
    return () => window.speechSynthesis.removeEventListener?.('voiceschanged', refreshVoices);
  }, [speechSupported]);
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
  const updateReaderPreferences = (patch: Partial<ReaderPreferences>) => {
    const next = preferencesStore.update(patch);
    setReaderPreferences(next);
  };
  const previewVoice = () => {
    if (!speechSupported) return;
    const locale = speechLocaleForLanguage(readerPreferences.sourceLanguage) ?? 'en-US';
    const voice = findSpeechVoice(speechVoices, readerPreferences.voiceURI, locale);
    const previewText = readerPreferences.sourceLanguage === 'zh-CN' || readerPreferences.sourceLanguage === 'zh-TW' ? '欢迎来到 AirRead。' : 'Welcome to AirRead.';
    const utterance = new SpeechSynthesisUtterance(previewText);
    utterance.lang = voice?.lang ?? locale;
    utterance.voice = voice ?? null;
    utterance.rate = readerPreferences.speechRate;
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utterance);
  };
  const voiceOptions = speechVoices.map((voice) => ({ value: voice.voiceURI, label: `${voice.name} · ${voice.lang}${voice.localService ? ' · 本机' : ' · 在线'}` }));

  return <section className="settings-page" aria-labelledby="settings-title">
    <header className="settings-page__header"><div><p className="eyebrow">阅读与翻译</p><h2 id="settings-title">设置</h2><p className="page-lede">先设置阅读语言和朗读声音，再选择适合自己的翻译服务；密钥只保存在当前浏览器。</p></div><ShieldCheck size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="settings-card settings-privacy"><ShieldCheck size={21} /><p>书籍和服务密钥只保存在当前浏览器。使用第三方翻译时，待翻译文本会直接发送到该服务。</p></section>
    {notice && <div className="settings-notice" role="status">{notice}</div>}
    {error && !editing && <div className="settings-alert" role="alert">{error}</div>}
    <section className="settings-card settings-reading-preferences" aria-labelledby="reading-preferences-title">
      <div className="settings-card__heading"><div><p className="eyebrow">阅读体验</p><h3 id="reading-preferences-title">阅读偏好</h3><p className="settings-card__description">阅读页的划词翻译、本章双语和朗读都会使用这里的默认设置；书籍工作室制作时仍可单独调整。</p></div><Headphones size={28} aria-hidden="true" /></div>
      <div className="settings-form-grid settings-reading-preferences__form">
        <label>翻译源语言<select aria-label="翻译源语言" value={readerPreferences.sourceLanguage} onChange={(event) => updateReaderPreferences({ sourceLanguage: event.target.value as ReaderPreferences['sourceLanguage'] })}>{READER_LANGUAGE_OPTIONS.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></label>
        <label>翻译目标语言<select aria-label="翻译目标语言" value={readerPreferences.targetLanguage} onChange={(event) => updateReaderPreferences({ targetLanguage: event.target.value as ReaderPreferences['targetLanguage'] })}>{READER_LANGUAGE_OPTIONS.filter((option) => option.value !== 'auto').map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></label>
        <label className="settings-form-grid__wide">朗读声音<select aria-label="朗读声音" value={readerPreferences.voiceURI} onChange={(event) => updateReaderPreferences({ voiceURI: event.target.value })} disabled={!speechSupported}><option value="">自动匹配（推荐）</option>{voiceOptions.map((voice) => <option value={voice.value} key={voice.value}>{voice.label}</option>)}</select></label>
        <label>朗读速度<select aria-label="朗读速度" value={readerPreferences.speechRate} onChange={(event) => updateReaderPreferences({ speechRate: Number(event.target.value) })}>{SPEECH_RATE_OPTIONS.map((rate) => <option value={rate} key={rate}>{rate.toFixed(1)} 倍</option>)}</select></label>
        <div className="settings-reading-preferences__preview"><button type="button" className="secondary-button" onClick={previewVoice} disabled={!speechSupported}><Headphones size={16} /> 试听当前声音</button><span>{speechSupported ? `${languageLabel(readerPreferences.sourceLanguage)} · ${speechVoices.length ? `${speechVoices.length} 个可用声音` : '声音加载中'}` : '当前浏览器不支持设备朗读'}</span></div>
      </div>
      <p className="settings-reading-preferences__hint">默认会按源语言自动匹配系统声音。声音质量由浏览器和操作系统提供；如果觉得声音生硬，可以在系统语音设置中安装增强或高级语音，再回到这里选择。</p>
    </section>
    <section className="settings-card"><div className="settings-card__heading"><div><p className="eyebrow">翻译服务</p><h3>服务配置</h3></div><button type="button" className="primary-action" onClick={startCreate}><Plus size={17} /> 添加翻译服务</button></div><div className="provider-list">{profiles.map((profile) => <article className={`provider-row ${profile.id === selectedId ? 'provider-row--selected' : ''}`} key={profile.id}><div className="provider-row__main"><span className="provider-row__icon">{profile.id === BUILT_IN_FREE_PROFILE.id ? <Check size={17} /> : <Power size={17} />}</span><div><h4>{profile.name}</h4><p>{profile.builtIn ? '免费 · 无需配置' : profile.kind === 'openai-compatible' ? `${profile.model || '未设置模型'} · ${profile.baseUrl || '未设置地址'}` : profile.kind === 'tencent-tmt' ? '腾讯云翻译 TMT' : 'Azure 翻译'}</p></div></div><div className="provider-row__status">{profile.enabled ? <span className="provider-enabled">{profile.id === selectedId ? '当前使用' : '已启用'}</span> : <span className="provider-disabled">已停用</span>}</div><div className="provider-row__actions">{profile.enabled && profile.id !== selectedId && <button type="button" className="text-button" onClick={() => select(profile)} aria-label={`设为当前 ${profile.name}`}>设为当前</button>}{!profile.builtIn && <><button type="button" className="icon-button" onClick={() => startEdit(profile)} aria-label={`编辑 ${profile.name}`}><Pencil size={16} /></button><button type="button" className="icon-button" onClick={() => toggle(profile)} aria-label={`${profile.enabled ? '停用' : '启用'} ${profile.name}`}><Power size={16} /></button><button type="button" className="icon-button" onClick={() => remove(profile)} aria-label={`删除 ${profile.name}`}><Trash2 size={16} /></button></>}</div></article>)}</div></section>
    {editing && <section className="settings-card"><ProviderEditor profile={editing} validationProfile={resolvedEditing} mode={editingOriginal ? 'edit' : 'create'} onChange={setEditing} onSave={save} onCancel={() => { setEditing(undefined); setEditingOriginal(undefined); setError(undefined); }} onTest={test} testing={testing} error={error} /></section>}
    <section className="settings-card settings-guidance"><div><p className="eyebrow">请求如何发送</p><h3>浏览器直接连接</h3><p>翻译请求由当前浏览器直接发送到所选服务。部分服务不允许网页直接连接；若测试失败，请改用支持浏览器访问的地址，或在自己的设备上运行中转服务。</p></div><CircleOff size={28} aria-hidden="true" /></section>
  </section>;
}
