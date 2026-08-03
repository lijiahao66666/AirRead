import { useEffect, useMemo, useState } from 'react';
import { Check, KeyRound, Pencil, Plus, Save, Trash2, Volume2, X } from 'lucide-react';

import { isMaskedSecret, maskProviderProfile, type ProviderKind, type ProviderProfile } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { isLearningModel } from '../../domain/learning/learningGenerator';

const modelKinds: Array<{ value: ProviderKind; label: string }> = [
  { value: 'openai-compatible', label: 'OpenAI 兼容协议 · Chat Completions' },
  { value: 'openai-responses', label: 'OpenAI Responses API' },
  { value: 'anthropic-messages', label: 'Anthropic Messages API' },
];

const createId = (): string => typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `model-${Date.now()}`;

export type LearningSettingsPageProps = {
  store: ProviderProfileStore;
  dailyMinutes: number;
  selectedModelId?: string;
  onMinutesChange: (minutes: number) => void;
  onModelChange: (id: string | undefined) => void;
};

export function LearningSettingsPage({ store, dailyMinutes, selectedModelId, onMinutesChange, onModelChange }: LearningSettingsPageProps) {
  const [profiles, setProfiles] = useState(() => store.list().filter(isLearningModel));
  const [editing, setEditing] = useState<ProviderProfile>();
  const [editingOriginal, setEditingOriginal] = useState<ProviderProfile>();
  const [error, setError] = useState<string>();
  const [saved, setSaved] = useState(false);
  const [minutes, setMinutes] = useState(String(dailyMinutes));
  const selected = useMemo(() => profiles.find((profile) => profile.id === selectedModelId), [profiles, selectedModelId]);

  useEffect(() => setMinutes(String(dailyMinutes)), [dailyMinutes]);

  const refresh = () => setProfiles(store.list().filter(isLearningModel));
  const closeEditor = () => { setEditing(undefined); setEditingOriginal(undefined); setError(undefined); };
  const startCreate = () => { setError(undefined); setSaved(false); setEditingOriginal(undefined); setEditing({ id: createId(), name: '我的 AI 模型', kind: 'openai-compatible', enabled: true }); };
  const startEdit = (profile: ProviderProfile) => { setError(undefined); setSaved(false); setEditingOriginal(profile); setEditing(maskProviderProfile(profile)); };
  const updateEditing = (patch: Partial<ProviderProfile>) => setEditing((current) => current ? { ...current, ...patch } : current);
  const changeKind = (kind: ProviderKind) => setEditing((current) => current ? { id: current.id, name: current.name, kind, enabled: true } : current);
  const saveModel = () => {
    if (!editing) return;
    try {
      const resolved: ProviderProfile = { ...editing, ...(isMaskedSecret(editing.apiKey) ? { apiKey: editingOriginal?.apiKey } : {}) };
      store.save(resolved);
      refresh();
      onModelChange(resolved.id);
      closeEditor();
      setSaved(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '模型配置未保存，请检查字段后重试');
    }
  };
  const removeModel = (profile: ProviderProfile) => {
    if (!window.confirm(`删除“${profile.name}”的模型配置？`)) return;
    store.remove(profile.id);
    refresh();
    if (selectedModelId === profile.id) onModelChange(undefined);
  };
  const saveMinutes = () => {
    const next = Number(minutes);
    if (Number.isFinite(next)) onMinutesChange(next);
    else setMinutes(String(dailyMinutes));
  };

  return <section className="learning-page" aria-labelledby="learning-settings-title">
    <header className="learning-page__header"><div><p className="eyebrow">只保留必要设置</p><h2 id="learning-settings-title">学习设置</h2><p className="page-lede">学习目标固定。这里只调整每日时间、模型和系统朗读说明。</p></div></header>
    <section className="settings-section learning-time-setting"><div><span className="learning-settings-icon"><ClockIcon /></span><div><p className="eyebrow">学习节奏</p><h3>每日可用时间</h3><p>系统会按这个时间自动安排当天的学习和复习量。</p></div></div><label><input type="number" min="5" max="180" inputMode="numeric" aria-label="每日可用分钟数" value={minutes} onChange={(event) => setMinutes(event.target.value)} onBlur={saveMinutes} /><span>分钟</span></label></section>
    <section className="settings-section"><div className="learning-settings-section-heading"><div><p className="eyebrow">AI 内容生成</p><h3>模型服务</h3><p className="settings-service-note"><span>API Key 只保存在当前浏览器。</span><span>AirRead 不提供模型额度。</span></p></div><button type="button" className="secondary-button" onClick={startCreate}><Plus size={16} /> 添加模型</button></div>{profiles.length === 0 ? <div className="settings-empty"><KeyRound size={20} /><p>还没有可用模型。添加一个模型后，系统可以按你的学习时间生成个性化学习包。</p></div> : <div className="model-list">{profiles.map((profile) => <article className={`model-row${selected?.id === profile.id ? ' model-row--selected' : ''}`} key={profile.id}><button type="button" className="model-row__select" onClick={() => { store.select(profile.id); onModelChange(profile.id); }}><span className="model-row__radio" aria-hidden="true">{selected?.id === profile.id && <Check size={14} />}</span><span><strong>{profile.name}</strong><small>{modelKinds.find((kind) => kind.value === profile.kind)?.label}</small></span></button><div><button type="button" className="icon-button" onClick={() => startEdit(profile)} aria-label={`编辑 ${profile.name}`}><Pencil size={16} /></button><button type="button" className="icon-button" onClick={() => removeModel(profile)} aria-label={`删除 ${profile.name}`}><Trash2 size={16} /></button></div></article>)}</div>}</section>
    <section className="settings-section"><div className="learning-settings-section-heading"><div><p className="eyebrow">声音</p><h3>学习资料音频</h3><p>有原版录音时优先播放原音；没有原版录音时，朗读按钮使用系统 TTS 辅助，不调用模型生成语音。</p></div><Volume2 size={23} /></div></section>
    {saved && <p className="settings-saved" role="status">设置已保存</p>}
    {editing && <ModelEditor profile={editing} error={error} onChange={updateEditing} onSave={saveModel} onCancel={closeEditor} onKindChange={changeKind} />}
  </section>;
}

function ModelEditor({ profile, error, onChange, onSave, onCancel, onKindChange }: { profile: ProviderProfile; error?: string; onChange: (patch: Partial<ProviderProfile>) => void; onSave: () => void; onCancel: () => void; onKindChange: (kind: ProviderKind) => void }) {
  const needsBaseUrl = profile.kind !== 'anthropic-messages' || Boolean(profile.baseUrl);
  return <div className="model-editor-backdrop" role="presentation"><form className="model-editor" onSubmit={(event) => { event.preventDefault(); onSave(); }}><header><div><p className="eyebrow">模型服务</p><h3>添加可调用的语言模型</h3></div><button type="button" className="icon-button" onClick={onCancel} aria-label="关闭模型编辑"><X size={18} /></button></header><div className="model-editor__grid"><label>服务名称<input value={profile.name} onChange={(event) => onChange({ name: event.target.value })} placeholder="例如：我的学习模型" /></label><label>协议<select value={profile.kind} onChange={(event) => onKindChange(event.target.value as ProviderKind)}>{modelKinds.map((kind) => <option value={kind.value} key={kind.value}>{kind.label}</option>)}</select></label>{needsBaseUrl && <label className="model-editor__wide">Base URL<input value={profile.baseUrl ?? ''} onChange={(event) => onChange({ baseUrl: event.target.value })} placeholder={profile.kind === 'anthropic-messages' ? '可留空使用 Anthropic 默认地址' : 'https://api.example.com/v1'} /></label>}<label>模型名称<input value={profile.model ?? ''} onChange={(event) => onChange({ model: event.target.value })} placeholder="例如：gpt-4.1-mini" /></label><label>API Key<input type="password" value={profile.apiKey ?? ''} onChange={(event) => onChange({ apiKey: event.target.value })} placeholder="只保存在当前浏览器" /></label><label className="model-editor__wide">额外提示词<span>可选，用来约束内容风格；学习目标由 AirRead 自动附加。</span><textarea rows={3} value={profile.prompt ?? ''} onChange={(event) => onChange({ prompt: event.target.value })} placeholder="例如：内容自然、贴近日常交流，不要使用生硬教材句式。" /></label></div>{error && <p className="learning-error" role="alert">{error}</p>}<footer><button type="button" className="secondary-button" onClick={onCancel}>取消</button><button type="submit" className="primary-action"><Save size={16} /> 保存模型</button></footer></form></div>;
}

function ClockIcon() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><circle cx="12" cy="12" r="8.5" /><path d="M12 7v5l3 2" /></svg>;
}
