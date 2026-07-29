import { useEffect, useRef, useState } from 'react';
import { Pencil, Plus, ShieldCheck, Trash2 } from 'lucide-react';

import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { isMaskedSecret, maskProviderProfile, type FreeTranslationRoute, type ProviderProfile } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { ProviderConnectionError, type TranslationRequest } from '../../domain/ai/translationTypes';
import { ProviderEditor } from './ProviderEditor';
import './settings.css';

export type SettingsPageProps = {
  store?: ProviderProfileStore;
  testConnection?: (profile: ProviderProfile) => Promise<void>;
};

const testRequest: TranslationRequest = { text: 'AirRead', sourceLanguage: 'en', targetLanguage: 'zh-CN' };
const freeRouteLabels: Record<FreeTranslationRoute, string> = {
  mymemory: 'MyMemory',
  google: 'Google Translate',
  'azure-edge': 'Azure Edge',
  auto: '自动切换',
};
const freeRouteHints: Record<FreeTranslationRoute, string> = {
  mymemory: 'MyMemory 免费线路，具体额度和可用性由服务方决定。',
  google: 'Google Translate GTX 线路，需要当前网络可以访问 Google。',
  'azure-edge': 'Azure Edge 无需 Key，但属于 Edge 使用的非官方接口，可能变化。',
  auto: '按 MyMemory → Azure Edge → Google Translate 顺序尝试，返回第一个有效译文。',
};

const providerKindLabels: Record<ProviderProfile['kind'], string> = {
  free: '免费翻译',
  'openai-compatible': 'OpenAI 兼容协议（Chat Completions）',
  'openai-responses': 'OpenAI Responses API',
  'anthropic-messages': 'Anthropic Messages API',
  'custom-http': '自定义 HTTP 翻译（JSON）',
  'tencent-tmt': '腾讯云翻译 TMT',
  'azure-translator': 'Azure AI Translator',
  youdao: '有道智云文本翻译',
  deepl: 'DeepL API',
};

export function SettingsPage({ store = new ProviderProfileStore(), testConnection = async (profile) => { await createTranslationEngine(profile).translate(testRequest); } }: SettingsPageProps) {
  const [profiles, setProfiles] = useState(() => store.list());
  const [selectedId, setSelectedId] = useState(() => store.selected().id);
  const [freeRoute, setFreeRoute] = useState<FreeTranslationRoute>(() => store.getFreeRoute());
  const [freeRouteEditorOpen, setFreeRouteEditorOpen] = useState(false);
  const [editing, setEditing] = useState<ProviderProfile>();
  const [editingOriginal, setEditingOriginal] = useState<ProviderProfile>();
  const editorRef = useRef<HTMLElement>(null);
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<{ tone: 'success' | 'error'; message: string }>();
  const refresh = () => { setProfiles(store.list()); setSelectedId(store.selected().id); setFreeRoute(store.getFreeRoute()); };
  const updateEditing = (profile: ProviderProfile) => { setEditing(profile); setTestResult(undefined); };
  const closeEditor = () => { setEditing(undefined); setEditingOriginal(undefined); setError(undefined); setTestResult(undefined); };
  const startCreate = () => { setError(undefined); setNotice(undefined); setTestResult(undefined); setEditingOriginal(undefined); setEditing({ id: `provider-${Date.now()}`, name: '我的翻译服务', kind: 'openai-compatible', enabled: true }); };
  const startEdit = (profile: ProviderProfile) => { setError(undefined); setNotice(undefined); setTestResult(undefined); setEditingOriginal(profile); setEditing(maskProviderProfile(profile)); };
  const toggleEdit = (profile: ProviderProfile) => { if (editingOriginal?.id === profile.id) { closeEditor(); return; } startEdit(profile); };
  const resolvedEditing = editing ? {
    ...editing,
    ...(isMaskedSecret(editing.apiKey) ? { apiKey: editingOriginal?.apiKey } : {}),
    ...(isMaskedSecret(editing.appSecret) ? { appSecret: editingOriginal?.appSecret } : {}),
  } : undefined;
  const save = () => {
    if (!editing) return;
    try { store.save(editing); setEditing(undefined); setEditingOriginal(undefined); setError(undefined); setTestResult(undefined); setNotice('配置已保存'); refresh(); } catch (cause) { setNotice(undefined); setError(cause instanceof Error ? cause.message : '保存配置失败'); }
  };
  const select = (profile: ProviderProfile) => { try { store.select(profile.id); refresh(); setNotice(`已选择 ${profile.name}`); } catch (cause) { setError(cause instanceof Error ? cause.message : '选择 Provider 失败'); } };
  const remove = (profile: ProviderProfile) => { try { store.remove(profile.id); refresh(); setNotice('配置已删除'); } catch (cause) { setError(cause instanceof Error ? cause.message : '删除 Provider 失败'); } };
  const updateFreeRoute = (route: FreeTranslationRoute) => { try { store.setFreeRoute(route); setFreeRoute(route); setError(undefined); setNotice(undefined); } catch (cause) { setError(cause instanceof Error ? cause.message : '保存免费翻译线路失败'); } };
  const test = async () => {
    if (!resolvedEditing) return;
    setTesting(true); setError(undefined); setTestResult(undefined);
    try { await testConnection(resolvedEditing); setTestResult({ tone: 'success', message: '连接成功' }); }
    catch (cause) { setTestResult({ tone: 'error', message: cause instanceof ProviderConnectionError ? '该翻译服务不允许浏览器直接连接。请使用支持网页调用的地址，或运行你自己的本地中转服务' : '连接测试失败，请检查翻译服务配置' }); }
    finally { setTesting(false); }
  };
  useEffect(() => {
    if (!editing) return undefined;
    const timer = window.setTimeout(() => editorRef.current?.scrollIntoView?.({ behavior: 'smooth', block: 'start' }), 0);
    return () => window.clearTimeout(timer);
  }, [editing?.id]);

  const renderEditor = (embedded = false) => editing && <ProviderEditor
    profile={editing}
    validationProfile={resolvedEditing}
    mode={editingOriginal ? 'edit' : 'create'}
    showClose={!embedded}
    onChange={updateEditing}
    onSave={save}
    onCancel={closeEditor}
    onTest={test}
    testing={testing}
    error={error}
    testResult={testResult}
  />;

  return <section className="settings-page" aria-labelledby="translation-settings-title">
    <header className="settings-page__header"><div><p className="eyebrow">本地翻译</p><h2 id="translation-settings-title">翻译服务</h2><p className="page-lede">选择免费线路，或连接自己的大模型与专业翻译服务。</p></div><ShieldCheck size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    {notice && <div className="settings-notice" role="status">{notice}</div>}
    {error && !editing && <div className="settings-alert" role="alert">{error}</div>}
    <section className="settings-card settings-services"><div className="settings-card__heading"><div><p className="eyebrow">翻译服务</p><h3>服务与线路</h3></div><button type="button" className="primary-action" onClick={startCreate}><Plus size={17} /> 添加翻译服务</button></div><div className="provider-list">{profiles.map((profile) => {
      const isBuiltIn = profile.builtIn;
      const editorOpen = editingOriginal?.id === profile.id;
      const editorId = `provider-editor-${profile.id}`;
      return <article className={`provider-row ${profile.id === selectedId ? 'provider-row--selected' : ''} ${isBuiltIn ? 'provider-row--built-in' : ''} ${editorOpen ? 'provider-row--editing' : ''}`} key={profile.id}>
        <div className="provider-row__main"><div><h4>{profile.name}</h4><p>{isBuiltIn ? `当前线路 · ${freeRouteLabels[freeRoute]}` : providerKindLabels[profile.kind]}</p></div></div>
        <div className="provider-row__actions">
          {profile.id === selectedId ? <span className="provider-current">当前使用</span> : <button type="button" className="text-button" onClick={() => select(profile)} aria-label={`设为当前 ${profile.name}`}>设为当前</button>}
          {isBuiltIn ? <button type="button" className="icon-button provider-row__editor-trigger" onClick={() => setFreeRouteEditorOpen((open) => !open)} aria-expanded={freeRouteEditorOpen} aria-controls="free-translation-route-editor" aria-label={freeRouteEditorOpen ? '收起免费翻译线路编辑' : '编辑免费翻译线路'} title="编辑免费翻译线路"><Pencil size={16} /></button> : <><button type="button" className="icon-button provider-row__editor-trigger" onClick={() => toggleEdit(profile)} aria-expanded={editorOpen} aria-controls={editorId} aria-label={editorOpen ? `收起 ${profile.name} 编辑` : `编辑 ${profile.name}`} title={`编辑 ${profile.name}`}><Pencil size={16} /></button><button type="button" className="icon-button" onClick={() => remove(profile)} aria-label={`删除 ${profile.name}`}><Trash2 size={16} /></button></>}
        </div>
        {isBuiltIn && freeRouteEditorOpen && <div className="free-route-settings" id="free-translation-route-editor"><label className="free-route-field" htmlFor="free-translation-route">免费翻译线路<select id="free-translation-route" aria-label="免费翻译线路" value={freeRoute} onChange={(event) => updateFreeRoute(event.target.value as FreeTranslationRoute)}>{Object.entries(freeRouteLabels).map(([route, label]) => <option value={route} key={route}>{label}</option>)}</select></label><p>{freeRouteHints[freeRoute]}</p></div>}
        {!isBuiltIn && editorOpen && <section className="provider-row__editor" id={editorId} ref={editorRef}>{renderEditor(true)}</section>}
      </article>;
    })}</div></section>
    {editing && !editingOriginal && <section className="settings-card" ref={editorRef}>{renderEditor()}</section>}
    <details className="settings-disclosure"><summary>关于本地数据与连接</summary><div><p>书籍和服务密钥只保存在当前浏览器。使用第三方翻译时，待翻译文本会直接发送到该服务。</p><p>翻译请求由当前浏览器直接发送到所选服务。部分服务不允许网页直接连接；若测试失败，请改用支持浏览器访问的地址，或在自己的设备上运行中转服务。</p></div></details>
  </section>;
}
