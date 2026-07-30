import { useRef, useState } from 'react';
import { AlertTriangle, ArrowLeft, BookOpenCheck, Check, ChevronRight, CirclePause, CirclePlay, Download, Languages, LibraryBig, RotateCcw, X } from 'lucide-react';

import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import { writeBilingualEpub } from '../../domain/books/epubWriter';
import { createStudioState, studioReducer, buildStudioChapters, type StudioConfig, type StudioState } from './studioState';
import type { Book } from '../../domain/books/book';
import { BookCover } from '../../ui/BookCover';
import { BookSourceSearchPage } from './BookSourceSearchPage';
import './studio.css';

export type BookStudioPageProps = {
  books: Book[];
  providerStore?: ProviderProfileStore;
  engineFactory?: (profile: ReturnType<ProviderProfileStore['selected']>) => TranslationEngine;
  onSaveBook: (book: Book) => void | Promise<void>;
  onDownload?: (blob: Blob, filename: string) => void;
  writeEpub?: typeof writeBilingualEpub;
  readBlob?: (blob: Blob) => Promise<Uint8Array>;
};

const STAGES = [
  ['select', '选择书籍'], ['inspect', '检查内容'], ['translate', '翻译设置'], ['progress', '制作进度'], ['complete', '完成'],
] as const;

export function BookStudioPage({ books, providerStore = new ProviderProfileStore(), engineFactory = createTranslationEngine, onSaveBook, onDownload, writeEpub = writeBilingualEpub, readBlob = blobBytes }: BookStudioPageProps) {
  const [activeTool, setActiveTool] = useState<'hub' | 'bilingual' | 'sources'>('hub');
  const [state, setState] = useState<StudioState | undefined>(undefined);
  const stateRef = useRef<StudioState | undefined>(undefined);
  const [error, setError] = useState<string>();
  const [configDraft, setConfigDraft] = useState<StudioConfig>({ sourceLanguage: 'auto', targetLanguage: 'zh-CN', providerId: providerStore.selected().id, glossary: {}, outputBilingual: true });
  const [glossaryText, setGlossaryText] = useState('');
  const pauseWaiters = useRef<Array<() => void>>([]);
  const runSequence = useRef(0);
  const activeRun = useRef<number | undefined>(undefined);
  const [activeRunId, setActiveRunId] = useState<number | undefined>(undefined);
  const finalizingRef = useRef(false);
  const [finalizing, setFinalizing] = useState(false);
  const [exportRetryable, setExportRetryable] = useState(false);
  const profiles = providerStore.list();

  const apply = (action: Parameters<typeof studioReducer>[1]) => {
    if (!stateRef.current) return;
    const next = studioReducer(stateRef.current, action);
    stateRef.current = next;
    setState(next);
  };

  const selectBook = (book: Book) => {
    try {
      const next = createStudioState(book);
      stateRef.current = next;
      setState(next);
      setExportRetryable(false);
      setError(undefined);
    } catch (cause) {
      setError(safeError(cause, '无法检查这本 EPUB'));
    }
  };

  const beginTranslation = () => {
    if (!stateRef.current) return;
    apply({ type: 'configure', config: configDraft });
    void runTranslation();
  };

  const waitIfPaused = async () => {
    if (stateRef.current?.status !== 'paused') return;
    await new Promise<void>((resolve) => pauseWaiters.current.push(resolve));
  };

  const runTranslation = async (retryOnly = false) => {
    if (activeRun.current !== undefined) {
      setError('当前制作仍在运行，请等待本批次结束');
      return;
    }
    const runToken = ++runSequence.current;
    activeRun.current = runToken;
    setActiveRunId(runToken);
    const isActive = () => activeRun.current === runToken && stateRef.current?.status !== 'cancelled';
    try {
      const initial = stateRef.current;
      if (!initial) return;
      const profile = providerStore.get(initial.config.providerId) ?? providerStore.selected();
      let engine: TranslationEngine;
      try {
        engine = engineFactory(profile);
      } catch (cause) {
        setError(safeError(cause, '翻译服务配置无效'));
        return;
      }
      apply(retryOnly ? { type: 'retry-failed' } : { type: 'start' });
      const queue = (stateRef.current?.paragraphs ?? []).filter((paragraph) => paragraph.status === 'pending');
      for (const paragraph of queue) {
        await waitIfPaused();
        if (!isActive()) return;
        apply({ type: 'paragraph-started', paragraphId: paragraph.id });
        try {
          const translated = await engine.translate({
            text: paragraph.original,
            sourceLanguage: initial.config.sourceLanguage === 'auto' ? undefined : initial.config.sourceLanguage,
            targetLanguage: initial.config.targetLanguage,
            glossary: initial.config.glossary,
          });
          if (!isActive()) return;
          apply({ type: 'paragraph-succeeded', paragraphId: paragraph.id, translation: translated });
        } catch (cause) {
          if (!isActive()) return;
          apply({ type: 'paragraph-failed', paragraphId: paragraph.id, error: safeError(cause, '翻译失败') });
        }
      }
      const completed = stateRef.current;
      if (!isActive() || !completed || completed.paragraphs.some((paragraph) => paragraph.status !== 'success')) return;
      setExportRetryable(true);
      const chapters = buildStudioChapters(completed);
      if (!isActive()) return;
      const blob = await writeEpub(completed.book, chapters);
      if (!isActive()) return;
      const bytes = await readBlob(blob);
      if (!isActive()) return;
      const generated: Book = {
        ...completed.book,
        id: createId(),
        title: `${completed.book.title} · 双语版`,
        bytes,
        importedAt: Date.now(),
        readingChapter: 0,
        readingProgress: 0,
        generatedBilingual: true,
      };
      if (!isActive()) return;
      finalizingRef.current = true;
      setFinalizing(true);
      try {
        await onSaveBook(generated);
      } finally {
        finalizingRef.current = false;
        setFinalizing(false);
      }
      if (!isActive()) return;
      apply({ type: 'complete', blob });
      setExportRetryable(false);
      setError(undefined);
    } catch (cause) {
      if (isActive()) setError(safeError(cause, '导出双语 EPUB 失败'));
    } finally {
      if (activeRun.current === runToken) activeRun.current = undefined;
      setActiveRunId((current) => current === runToken ? undefined : current);
    }
  };

  const resume = () => {
    apply({ type: 'resume' });
    const waiters = pauseWaiters.current.splice(0);
    waiters.forEach((resolve) => resolve());
  };

  const cancel = () => {
    if (finalizingRef.current) return;
    activeRun.current = undefined;
    setActiveRunId(undefined);
    setExportRetryable(false);
    apply({ type: 'cancel' });
    pauseWaiters.current.splice(0).forEach((resolve) => resolve());
  };

  const download = () => {
    if (!state?.blob) return;
    const filename = `${safeFilename(state.book.title)}-双语版.epub`;
    if (onDownload) onDownload(state.blob, filename);
    else {
      const url = URL.createObjectURL(state.blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filename;
      anchor.click();
      URL.revokeObjectURL(url);
    }
  };

  const config = state?.config ?? configDraft;
  const setConfig = (patch: Partial<StudioConfig>) => {
    const next = { ...config, ...patch };
    setConfigDraft(next);
    if (stateRef.current?.stage === 'translate') apply({ type: 'configure', config: next });
  };
  const parseGlossary = (value: string): Record<string, string> => Object.fromEntries(value.split(/\r?\n/).map((line) => line.split('=').map((part) => part.trim())).filter(([source, target]) => Boolean(source && target)) as Array<[string, string]>);
  const stageIndex = state?.status === 'cancelled' ? -1 : state ? STAGES.findIndex(([stage]) => stage === state.stage) : 0;

  if (activeTool === 'hub') {
    return <section className="studio-page" aria-labelledby="studio-title">
      <header className="studio-page__header"><div><p className="eyebrow">本地书籍工具</p><h2 id="studio-title">书籍工作室</h2><p className="page-lede">制作自己的双语书，或搜索可访问的书目信息。</p></div><BookOpenCheck size={40} strokeWidth={1.35} aria-hidden="true" /></header>
      <div className="studio-tool-grid">
        <article className="studio-tool-card studio-tool-card--available">
          <div className="studio-tool-card__top"><span className="studio-tool-card__icon"><Languages size={24} /></span><span className="studio-tool-status studio-tool-status--available">已可用</span></div>
          <div><p className="eyebrow">EPUB · 翻译</p><h3>制作双语书</h3><p>按章节检查和翻译 EPUB，支持暂停、失败重试，并导出新的双语版本。</p></div>
          <button type="button" className="primary-action studio-tool-action" onClick={() => setActiveTool('bilingual')}>开始制作双语书 <ChevronRight size={18} /></button>
        </article>
        <article className="studio-tool-card studio-tool-card--available">
          <div className="studio-tool-card__top"><span className="studio-tool-card__icon"><LibraryBig size={24} /></span><span className="studio-tool-status studio-tool-status--available">自动聚合</span></div>
          <div><p className="eyebrow">书目资源 · 统一检索</p><h3>书籍搜索</h3><p>输入一次关键词，自动检索当前可访问的中文书目与公共领域书目。</p></div>
          <button type="button" className="primary-action studio-tool-action" onClick={() => setActiveTool('sources')}>搜索全部书源 <ChevronRight size={18} /></button>
        </article>
      </div>
    </section>;
  }

  if (activeTool === 'sources') return <BookSourceSearchPage onBack={() => setActiveTool('hub')} />;

  return <section className="studio-page" aria-labelledby="studio-title">
    <button type="button" className="studio-tool-back" onClick={() => setActiveTool('hub')} disabled={activeRunId !== undefined || finalizing}><ArrowLeft size={17} /> 返回工具列表</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 双语工具</p><h2 id="studio-title">制作双语书</h2><p className="page-lede">选择一本 EPUB，按章节顺序翻译，完成后保存一份新的双语书到书架。</p></div><Languages size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <nav className="studio-steps" aria-label="制作步骤">{STAGES.map(([stage, label], index) => <div className={`studio-step ${index <= stageIndex ? 'studio-step--active' : ''} ${index === stageIndex ? 'studio-step--current' : ''}`} key={stage}><span>{index < stageIndex ? <Check size={16} /> : index + 1}</span><strong>{label}</strong></div>)}</nav>
    {error && <div className="studio-alert" role="alert"><AlertTriangle size={17} /> {error}</div>}
    {!state && <section className="studio-card studio-select-card"><div className="studio-card__heading"><div><p className="eyebrow">第一步</p><h3>选择一本 EPUB</h3></div><span>{books.filter((book) => book.format === 'epub').length} 本可制作</span></div>{books.filter((book) => book.format === 'epub').length === 0 && <div className="studio-empty">请先从书架导入 EPUB 文件。</div>}<div className="studio-book-list">{books.filter((book) => book.format === 'epub').map((book) => <button type="button" className="studio-book-option" key={book.id} onClick={() => selectBook(book)} aria-label={`选择 ${book.title}`}><span className="studio-book-option__cover"><BookCover src={book.coverDataUrl} variant="file" /></span><span><strong>{book.title}</strong><small>{book.author || '未填写作者'}</small></span><ChevronRight size={20} /></button>)}</div></section>}
    {state?.stage === 'inspect' && <section className="studio-card" aria-labelledby="inspect-title"><div className="studio-card__heading"><div><p className="eyebrow">第二步</p><h3 id="inspect-title">检查书籍内容</h3></div><button type="button" className="text-button" onClick={() => { stateRef.current = undefined; setState(undefined); }}>重新选择</button></div><div className="studio-book-summary"><div className="studio-summary__cover"><BookCover src={state.book.coverDataUrl} variant="file" /></div><div><h4>{state.book.title}</h4><p>{state.book.author || '未填写作者'}</p><dl><div><dt>章节</dt><dd>{state.chapters.length} 个章节</dd></div><div><dt>可翻译字符</dt><dd>{state.totalCharacters.toLocaleString()} 字符</dd></div></dl></div></div><div className="studio-card__footer"><button type="button" className="primary-action" onClick={() => { setConfigDraft(config); apply({ type: 'configure', config }); }}>下一步：翻译设置 <ChevronRight size={17} /></button></div></section>}
    {state?.stage === 'translate' && <section className="studio-card" aria-labelledby="translate-title"><div className="studio-card__heading"><div><p className="eyebrow">第三步</p><h3 id="translate-title">翻译设置</h3></div></div><div className="studio-form-grid"><label>源语言<select aria-label="源语言" value={config.sourceLanguage} onChange={(event) => setConfig({ sourceLanguage: event.target.value })}><option value="auto">自动检测</option><option value="en">英语</option><option value="ja">日语</option><option value="ko">韩语</option><option value="zh-CN">简体中文</option></select></label><label>目标语言<select aria-label="目标语言" value={config.targetLanguage} onChange={(event) => setConfig({ targetLanguage: event.target.value })}><option value="zh-CN">简体中文</option><option value="zh-TW">繁体中文</option><option value="en">英语</option><option value="ja">日语</option></select></label><label>翻译服务<select aria-label="翻译服务" value={config.providerId} onChange={(event) => setConfig({ providerId: event.target.value })}>{profiles.filter((profile) => profile.enabled).map((profile) => <option key={profile.id} value={profile.id}>{profile.name}</option>)}</select></label></div><label className="studio-field-label" htmlFor="studio-glossary">术语表</label><textarea id="studio-glossary" aria-label="术语表" placeholder="每行一个术语：原文=译文" value={glossaryText} onChange={(event) => { setGlossaryText(event.target.value); setConfig({ glossary: parseGlossary(event.target.value) }); }} /><label className="studio-checkbox"><input type="checkbox" checked={config.outputBilingual} onChange={(event) => setConfig({ outputBilingual: event.target.checked })} /> 输出双语对照</label><p className="studio-privacy-note">书籍和服务密钥只保存在当前浏览器。制作时，待翻译文本会直接发送到你选择的服务。</p><div className="studio-card__footer"><button type="button" className="secondary-button" onClick={() => { stateRef.current = { ...state, stage: 'inspect' }; setState(stateRef.current); }}><ArrowLeft size={17} /> 上一步</button><button type="button" className="primary-action" onClick={beginTranslation}>开始制作 <ChevronRight size={17} /></button></div></section>}
    {state?.stage === 'progress' && state.status !== 'cancelled' && <section className="studio-card" aria-labelledby="progress-title"><div className="studio-card__heading"><div><p className="eyebrow">第四步</p><h3 id="progress-title">制作进度</h3></div><span className="studio-progress-count">{state.paragraphs.filter((paragraph) => paragraph.status === 'success').length} / {state.paragraphs.length} 段</span></div><div className="studio-progress-track"><span style={{ width: `${Math.round((state.paragraphs.filter((paragraph) => paragraph.status === 'success').length / Math.max(1, state.paragraphs.length)) * 100)}%` }} /></div>{state.status === 'paused' && <p className="studio-status studio-status--paused">已暂停</p>}{state.paragraphs.some((paragraph) => paragraph.status === 'failed') && <div className="studio-failed" role="alert"><strong>{state.paragraphs.filter((paragraph) => paragraph.status === 'failed').length} 段翻译失败</strong><ul>{state.paragraphs.filter((paragraph) => paragraph.status === 'failed').map((paragraph) => <li key={paragraph.id}>{paragraph.original}<span>{paragraph.error}</span></li>)}</ul><button type="button" className="secondary-button" onClick={() => void runTranslation(true)} disabled={activeRunId !== undefined}><RotateCcw size={16} /> 重试失败段落</button></div>}{exportRetryable && activeRunId === undefined && <button type="button" className="secondary-button" onClick={() => void runTranslation()}><RotateCcw size={16} /> 重试导出</button>}<div className="studio-card__footer"><button type="button" className="secondary-button" onClick={cancel} disabled={finalizing}><X size={16} /> 取消制作</button>{state.status === 'paused' ? <button type="button" className="primary-action" onClick={resume}><CirclePlay size={17} /> 继续制作</button> : <button type="button" className="secondary-button" onClick={() => apply({ type: 'pause' })} disabled={state.status !== 'running' || finalizing}><CirclePause size={17} /> 暂停制作</button>}</div></section>}
    {state?.status === 'cancelled' && <section className="studio-card studio-result-card"><X size={30} /><h3>制作已取消</h3><p>本次批量翻译没有写回或保存任何新书。</p><button type="button" className="primary-action" onClick={() => { stateRef.current = undefined; setState(undefined); }}>重新开始</button></section>}
    {state?.stage === 'complete' && <section className="studio-card studio-result-card" aria-labelledby="complete-title"><span className="studio-success-icon"><Check size={28} /></span><p className="eyebrow">第五步</p><h3 id="complete-title">双语书制作完成</h3><p>已生成《{state.book.title} · 双语版》，并保存回书架。</p><button type="button" className="primary-action" onClick={download}><Download size={17} /> 下载双语 EPUB</button></section>}
  </section>;
}

function safeError(cause: unknown, fallback: string): string {
  if (cause instanceof Error && cause.name === 'ProviderConnectionError') return '该翻译服务不允许浏览器直接连接。请使用支持网页调用的地址，或运行你自己的本地中转服务';
  return fallback;
}

function safeFilename(value: string): string { return value.replace(/[\\/:*?"<>|]/g, '-').trim() || 'AirRead'; }
function createId(): string { return typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`; }

function blobBytes(blob: Blob): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(new Uint8Array(reader.result as ArrayBuffer));
    reader.onerror = () => reject(reader.error ?? new Error('无法读取导出的 EPUB'));
    reader.readAsArrayBuffer(blob);
  });
}
