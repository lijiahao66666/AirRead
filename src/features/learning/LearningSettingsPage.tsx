import { useEffect, useMemo, useRef, useState } from 'react';
import { BookOpenText, Check, Download, KeyRound, Pencil, Plus, Save, Trash2, Volume2, X } from 'lucide-react';

import { isMaskedSecret, maskProviderProfile, type ProviderKind, type ProviderProfile } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { isLearningModel } from '../../domain/learning/learningGenerator';
import { connectAutomaticStoryArchive, isAutomaticStoryArchiveConnected, supportsAutomaticStoryArchive } from '../../domain/learning/storyArchive';
import { downloadStoryEpub } from '../../domain/learning/storyEpub';
import type { LearningPack, LearningStoryMemory, LearningStoryProfile } from '../../domain/learning/learningTypes';
import { DailyMinutesInput } from './DailyMinutesInput';

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
  storyProfile: LearningStoryProfile;
  storyMemory?: LearningStoryMemory;
  packs: Record<string, LearningPack>;
  onMinutesChange: (minutes: number) => void;
  onModelChange: (id: string | undefined) => void;
  onStoryProfileChange: (premise: string) => void;
  onChapterWordCountChange: (value: number) => void;
  onStartNewStory: (premise: string) => void;
  generating?: boolean;
  generationError?: string;
};

export function LearningSettingsPage({ store, dailyMinutes, selectedModelId, storyProfile, storyMemory, packs, onMinutesChange, onModelChange, onStoryProfileChange, onChapterWordCountChange, onStartNewStory, generating = false, generationError }: LearningSettingsPageProps) {
  const [profiles, setProfiles] = useState(() => store.list().filter(isLearningModel));
  const [editing, setEditing] = useState<ProviderProfile>();
  const [editingOriginal, setEditingOriginal] = useState<ProviderProfile>();
  const [error, setError] = useState<string>();
  const [saved, setSaved] = useState(false);
  const [storyPremise, setStoryPremise] = useState(storyProfile.premise);
  const [storySaved, setStorySaved] = useState(false);
  const [confirmingNewStory, setConfirmingNewStory] = useState(false);
  const [storyActionMessage, setStoryActionMessage] = useState<string>();
  const [startingNewStory, setStartingNewStory] = useState(false);
  const startingStoryId = useRef<string | undefined>(undefined);
  const [archiveConnected, setArchiveConnected] = useState(false);
  const selected = useMemo(() => profiles.find((profile) => profile.id === selectedModelId), [profiles, selectedModelId]);

  useEffect(() => setStoryPremise(storyProfile.premise), [storyProfile.premise]);

  useEffect(() => {
    if (!startingNewStory || !storyMemory || storyMemory.storyId === startingStoryId.current) return;
    setStartingNewStory(false);
    setStoryActionMessage('第一章已准备好，请打开“今日学习”查看。');
  }, [startingNewStory, storyMemory?.storyId]);

  useEffect(() => {
    let active = true;
    if (!storyMemory || !supportsAutomaticStoryArchive()) {
      setArchiveConnected(false);
      return () => { active = false; };
    }
    void isAutomaticStoryArchiveConnected(storyMemory.storyId).then((connected) => {
      if (active) setArchiveConnected(connected);
    });
    return () => { active = false; };
  }, [storyMemory?.storyId]);

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
  const saveStoryProfile = () => {
    onStoryProfileChange(storyPremise);
    setStorySaved(true);
    setStoryActionMessage(undefined);
  };
  const beginNewStory = () => {
    const hasStoryData = Boolean(storyMemory) || Object.keys(packs).length > 0;
    if (hasStoryData) {
      setConfirmingNewStory(true);
      setStoryActionMessage(undefined);
      return;
    }
    confirmNewStory();
  };
  const confirmNewStory = () => {
    startingStoryId.current = storyMemory?.storyId;
    onStartNewStory(storyPremise);
    setStorySaved(false);
    setConfirmingNewStory(false);
    setStartingNewStory(true);
    setStoryActionMessage((selectedModelId || profiles.length > 0)
      ? '已开始新故事，打开“今日学习”即可准备第一章。'
      : '已开始新故事。请先添加并选择模型，再打开“今日学习”准备第一章。');
  };
  const exportStory = () => {
    if (!storyMemory) return;
    try {
      downloadStoryEpub(storyMemory, packs);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'EPUB 导出失败，请稍后重试');
    }
  };
  const connectArchive = async () => {
    if (!storyMemory) return;
    try {
      await connectAutomaticStoryArchive(storyMemory, packs);
      setArchiveConnected(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '自动存档连接失败，请改用 EPUB 导出');
    }
  };
  return <section className="learning-page" aria-labelledby="learning-settings-title">
    <header className="learning-page__header"><div><p className="eyebrow">只保留必要设置</p><h2 id="learning-settings-title">学习设置</h2><p className="page-lede">学习目标固定。这里只调整每日时间、模型和系统朗读说明。</p></div></header>
    <section className="settings-section learning-time-setting"><div><span className="learning-settings-icon"><ClockIcon /></span><div><p className="eyebrow">学习节奏</p><h3>每日可用时间</h3><p>变更后会重新准备今天的学习内容与训练量。</p></div></div><label><DailyMinutesInput value={dailyMinutes} onChange={onMinutesChange} /><span>分钟</span></label></section>
    <section className="settings-section story-setting"><div className="learning-settings-section-heading"><div><p className="eyebrow">原创连载</p><h3>故事设定</h3><p>可留空，AI 会自行选择适合长期连载的原创题材。设定只会在开始新故事时生效，不会篡改正在连载的世界观。</p></div><BookOpenText size={23} /></div>{storyMemory ? <div className="story-setting__current"><div><span>当前连载</span><strong>{storyMemory.title}</strong><small>{storyMemory.genre} · 已完成第 {storyMemory.chapterNumber} 章</small></div><div className={`story-setting__archive-actions${archiveConnected ? ' story-setting__archive-actions--connected' : ''}`}>{archiveConnected ? <><button type="button" className="secondary-button" onClick={() => { void connectArchive(); }}>重新选择存储目录</button><button type="button" className="secondary-button" onClick={exportStory}><Download size={16} /> 导出 EPUB</button></> : supportsAutomaticStoryArchive() ? <><button type="button" className="secondary-button" onClick={() => { void connectArchive(); }}>选择存储目录</button><span className="story-setting__archive-hint">选择一个目录，AirRead 会在其中创建并持续更新 EPUB。</span></> : <span className="story-setting__archive-hint">当前浏览器不支持目录存档，请使用支持目录访问的 Chrome 或安卓浏览器。</span>}</div></div> : <p className="story-setting__empty">还没有开始连载。配置模型后，打开“今日学习”即可生成第一章。</p>}<label className="story-setting__field"><span>每章英文词数（80–3000）</span><input type="number" min="80" max="3000" step="10" value={storyProfile.chapterWordCount} onChange={(event) => onChapterWordCountChange(Number(event.target.value))} aria-label="每章英文词数" /></label><label className="story-setting__field"><span>你的大概设定（可选）</span><textarea value={storyPremise} onChange={(event) => { setStoryPremise(event.target.value); setStorySaved(false); setStoryActionMessage(undefined); }} rows={4} maxLength={1000} placeholder="例如：一个在上海通勤的产品经理，偶然收到来自未来的英文语音；希望是轻科幻、悬疑、有成长线。" /></label><div className="story-setting__actions"><button type="button" className="secondary-button" onClick={saveStoryProfile}><Save size={16} /> 保存设定</button><button type="button" className="primary-action" onClick={beginNewStory} disabled={startingNewStory && generating}>{startingNewStory && generating ? '正在准备第一章…' : '开始新故事'}</button></div>{confirmingNewStory && <div className="story-setting__confirm" role="alert"><strong>确认开始新的连载？</strong><p>当前章节、故事记忆和训练进度会清空，间隔复习卡片会保留。建议先导出 EPUB 存档。</p><div><button type="button" className="secondary-button" onClick={() => setConfirmingNewStory(false)}>取消</button><button type="button" className="primary-action" onClick={confirmNewStory}>确认开始</button></div></div>}{startingNewStory && generating && <p className="story-setting__status" role="status">正在准备第一章，模型生成可能需要几分钟…</p>}{startingNewStory && generationError && <p className="story-setting__status story-setting__status--error" role="alert">第一章生成失败：{generationError}</p>}{storySaved && <p className="settings-saved" role="status">故事设定已保存</p>}{storyActionMessage && <p className="story-setting__status" role="status">{storyActionMessage}</p>}<p className="story-setting__note">“开始新故事”会清空当前连载的章节、故事记忆和训练进度，但保留间隔复习卡片；打开“今日学习”后会按新设定准备第一章。章节和长期记忆会保存在当前浏览器，定期导出 EPUB 到“文件/下载”后，即使清除浏览器数据也能保留已写内容。</p></section>
    <section className="settings-section"><div className="learning-settings-section-heading"><div><p className="eyebrow">AI 内容生成</p><h3>模型服务</h3><p className="settings-service-note"><span>API Key 只保存在当前浏览器。</span><span>AirRead 不提供模型额度。</span></p></div><button type="button" className="secondary-button" onClick={startCreate}><Plus size={16} /> 添加模型</button></div>{profiles.length === 0 ? <div className="settings-empty"><KeyRound size={20} /><p>还没有可用模型。添加一个模型后，系统可以按你的学习时间生成个性化学习包。</p></div> : <div className="model-list">{profiles.map((profile) => <article className={`model-row${selected?.id === profile.id ? ' model-row--selected' : ''}`} key={profile.id}><button type="button" className="model-row__select" onClick={() => { store.select(profile.id); onModelChange(profile.id); }}><span className="model-row__radio" aria-hidden="true">{selected?.id === profile.id && <Check size={14} />}</span><span><strong>{profile.name}</strong><small>{modelKinds.find((kind) => kind.value === profile.kind)?.label}</small></span></button><div><button type="button" className="icon-button" onClick={() => startEdit(profile)} aria-label={`编辑 ${profile.name}`}><Pencil size={16} /></button><button type="button" className="icon-button" onClick={() => removeModel(profile)} aria-label={`删除 ${profile.name}`}><Trash2 size={16} /></button></div></article>)}</div>}</section>
    <section className="settings-section"><div className="learning-settings-section-heading"><div><p className="eyebrow">声音</p><h3>学习资料音频</h3><p>AI 原创连载没有原版录音；朗读按钮使用系统 TTS 辅助，不调用模型生成语音，也不会伪装成真人录音。</p></div><Volume2 size={23} /></div></section>
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
