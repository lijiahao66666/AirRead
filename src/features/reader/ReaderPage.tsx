import { useEffect, useMemo, useRef, useState, type MouseEvent, type ReactNode, type TouchEvent } from 'react';
import { BookOpen, ChevronLeft, ChevronRight, Languages, List, Moon, PanelBottom, Settings2, Sun, X } from 'lucide-react';

import { TranslationCache } from '../../domain/ai/translationCache';
import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import type { Book, BookSelectionPreferences, BookTranslationPreferences, Chapter } from '../../domain/books/book';
import { ReaderSpeechControls, type SpeechPlaybackState } from './ReaderSpeechControls';
import { ReaderSpeechPreferences } from './ReaderSpeechPreferences';
import { ReaderToolbar } from './ReaderToolbar';
import { ReaderTranslationControls } from './ReaderTranslationControls';
import { SelectionActions } from './SelectionActions';
import { paragraphsForChapter, type ReaderParagraph } from './readerState';
import { availableSpeechVoices, findSpeechVoice, languageLabel, READER_LANGUAGE_OPTIONS, ReaderPreferencesStore, speechLocaleForLanguage, speechLocaleForText, speechPreviewText, SPEECH_RATE_OPTIONS, textMatchesTargetLanguage, type ReaderLanguage, type ReaderPreferences } from './readerPreferences';
import { paginateReaderParagraphs, type ReaderContentMode, type ReaderPageBlock } from './readerPagination';
import './reader.css';

type ProgressUpdate = Pick<Book, 'readingChapter' | 'readingProgress' | 'lastReadAt'>;
type TargetLanguage = Exclude<ReaderLanguage, 'auto'>;
type SelectionActionState = { paragraphId: string; source: string; targetLanguage: TargetLanguage; anchor: { x: number; y: number }; translation?: string; error?: string; notice?: string; loading: boolean; copied?: boolean };
type ChapterTranslationState = { running: boolean; completed: number; total: number; failed: number };
type SpeechQueueItem = { paragraphId: string; text: string; language: 'source' | 'target' };
export type ReaderPageProps = { book: Book; chapters: Chapter[]; engine?: TranslationEngine; onProgress: (progress: ProgressUpdate) => void | Promise<void>; onTranslationPreferencesChange?: (preferences?: BookTranslationPreferences) => void | Promise<void>; onSelectionPreferencesChange?: (preferences?: BookSelectionPreferences) => void | Promise<void>; onBack: () => void };

const errorMessage = (cause: unknown, fallback: string): string => cause instanceof Error && cause.message.trim() ? cause.message : fallback;
const emptyChapterTranslation = (): ChapterTranslationState => ({ running: false, completed: 0, total: 0, failed: 0 });
const hasTranslatableContent = (text: string): boolean => /[\p{L}\p{N}]/u.test(text);
const pageCapacityFor = (preferences: ReaderPreferences): number => ({ small: 820, medium: 680, large: 560, 'x-large': 450 })[preferences.fontSize];

type ReaderSheetProps = { title: string; children: ReactNode; onClose: () => void };
function ReaderSheet({ title, children, onClose }: ReaderSheetProps) {
  return <div className="reader-sheet-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <aside className="reader-sheet" role="dialog" aria-modal="true" aria-label={title}>
      <header className="reader-sheet__header"><div><span className="eyebrow">AirRead 灵阅</span><h2>{title}</h2></div><button type="button" className="icon-button" onClick={onClose} aria-label={`关闭${title}`}><X size={19} /></button></header>
      <div className="reader-sheet__body">{children}</div>
    </aside>
  </div>;
}

export function ReaderPage({ book, chapters, engine, onProgress, onTranslationPreferencesChange, onSelectionPreferencesChange, onBack }: ReaderPageProps) {
  const initialChapter = Math.min(book.readingChapter, Math.max(0, chapters.length - 1));
  const [chapterIndex, setChapterIndex] = useState(initialChapter);
  const [paragraphs, setParagraphs] = useState<ReaderParagraph[]>(() => paragraphsForChapter(chapters[initialChapter] ?? { id: 'empty', title: '暂无章节', href: '', content: '' }));
  const [selectionAction, setSelectionAction] = useState<SelectionActionState>();
  const [chapterTranslation, setChapterTranslation] = useState<ChapterTranslationState>(emptyChapterTranslation);
  const [contentMode, setContentMode] = useState<ReaderContentMode>('original');
  const [speechState, setSpeechState] = useState<SpeechPlaybackState>('idle');
  const [speechParagraphId, setSpeechParagraphId] = useState<string>();
  const [speechParagraphIndex, setSpeechParagraphIndex] = useState(0);
  const [pageIndex, setPageIndex] = useState(0);
  const [contentsOpen, setContentsOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [translationOpen, setTranslationOpen] = useState(false);
  const [chromeVisible, setChromeVisible] = useState(true);
  const [pageDirection, setPageDirection] = useState<-1 | 1>(1);
  const preferencesStore = useMemo(() => new ReaderPreferencesStore(), []);
  const [readerPreferences, setReaderPreferences] = useState<ReaderPreferences>(() => preferencesStore.get());
  const [speechVoices, setSpeechVoices] = useState<SpeechSynthesisVoice[]>([]);
  const [bookTranslationPreferences, setBookTranslationPreferences] = useState<BookTranslationPreferences>(() => book.translationPreferences ?? {});
  const [selectionPreferences, setSelectionPreferences] = useState<BookSelectionPreferences>(() => book.selectionPreferences ?? {});
  const [speechError, setSpeechError] = useState<string>();
  const [localProgress, setLocalProgress] = useState(book.readingProgress);
  const [progressError, setProgressError] = useState<string>();
  const activeEngine = useMemo(() => engine ?? createTranslationEngine(new ProviderProfileStore().selected()), [engine]);
  const cache = useMemo(() => new TranslationCache(), []);
  const selectionRequestSequence = useRef(0);
  const chapterRunSequence = useRef(0);
  const speechRunSequence = useRef(0);
  const progressTimer = useRef<number | undefined>(undefined);
  const touchStartX = useRef<number | undefined>(undefined);
  const touchStartY = useRef<number | undefined>(undefined);
  const touchHandled = useRef(false);
  const chapterEntry = useRef<'start' | 'end'>('start');
  const progressQueue = useRef(Promise.resolve());
  const onProgressRef = useRef(onProgress);
  onProgressRef.current = onProgress;
  const chapter = chapters[chapterIndex];
  const readerIdentity = `${book.id}:${chapterIndex}`;
  const readerIdentityRef = useRef(readerIdentity);
  readerIdentityRef.current = readerIdentity;
  const bookIdentityRef = useRef(book.id);
  bookIdentityRef.current = book.id;
  const speechSupported = typeof window.speechSynthesis !== 'undefined' && typeof window.SpeechSynthesisUtterance !== 'undefined';
  const speechRate = readerPreferences.speechRate;
  const bookSourceLanguage = READER_LANGUAGE_OPTIONS.some((option) => option.value === bookTranslationPreferences.sourceLanguage)
    ? bookTranslationPreferences.sourceLanguage as ReaderLanguage
    : readerPreferences.sourceLanguage;
  const bookTargetOverride = READER_LANGUAGE_OPTIONS.some((option) => option.value === bookTranslationPreferences.targetLanguage && option.value !== 'auto')
    ? bookTranslationPreferences.targetLanguage as TargetLanguage
    : undefined;
  const bookTargetLanguage = bookTargetOverride ?? readerPreferences.targetLanguage;
  const selectionTargetOverride = READER_LANGUAGE_OPTIONS.some((option) => option.value === selectionPreferences.targetLanguage && option.value !== 'auto')
    ? selectionPreferences.targetLanguage as TargetLanguage
    : undefined;
  const selectionTargetLanguage = selectionTargetOverride ?? readerPreferences.targetLanguage;

  const resetTransientState = () => {
    selectionRequestSequence.current += 1;
    chapterRunSequence.current += 1;
    speechRunSequence.current += 1;
    if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel();
    setSelectionAction(undefined);
    setChapterTranslation(emptyChapterTranslation());
    setContentMode('original');
    setSpeechState('idle');
    setSpeechParagraphId(undefined);
    setSpeechParagraphIndex(0);
    setSpeechError(undefined);
    setPageIndex(0);
    setTranslationOpen(false);
    setChromeVisible(true);
  };

  useEffect(() => {
    const nextChapter = Math.min(book.readingChapter, Math.max(0, chapters.length - 1));
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    setChapterIndex(nextChapter);
    setLocalProgress(book.readingProgress);
    setProgressError(undefined);
    resetTransientState();
  }, [book.id, book.bytes, book.text]);

  useEffect(() => setLocalProgress(book.readingProgress), [book.id, book.readingProgress]);

  useEffect(() => {
    setBookTranslationPreferences(book.translationPreferences ?? {});
    setSelectionPreferences(book.selectionPreferences ?? {});
  }, [book.id]);

  useEffect(() => {
    const onStorage = (event: StorageEvent) => { if (event.key === 'airread.readerPreferences.v1') setReaderPreferences(preferencesStore.get()); };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, [preferencesStore]);

  useEffect(() => {
    const speechSynthesis = window.speechSynthesis;
    if (!speechSupported || !speechSynthesis) return undefined;
    const refreshVoices = () => setSpeechVoices(availableSpeechVoices());
    refreshVoices();
    speechSynthesis.addEventListener?.('voiceschanged', refreshVoices);
    return () => speechSynthesis.removeEventListener?.('voiceschanged', refreshVoices);
  }, [speechSupported]);

  useEffect(() => {
    setParagraphs(paragraphsForChapter(chapter ?? { id: 'empty', title: '暂无章节', href: '', content: '' }));
    resetTransientState();
  }, [book.id, book.bytes, book.text, chapterIndex, chapter?.id]);

  useEffect(() => () => {
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    selectionRequestSequence.current += 1;
    chapterRunSequence.current += 1;
    speechRunSequence.current += 1;
    if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel();
  }, []);

  const persistProgress = (progress: ProgressUpdate) => {
    const targetBookId = book.id;
    setProgressError(undefined);
    progressQueue.current = progressQueue.current.then(() => onProgressRef.current(progress)).catch((cause) => {
      if (bookIdentityRef.current === targetBookId) setProgressError(errorMessage(cause, '保存阅读进度失败'));
    });
  };

  const updateProgress = (next: number) => {
    const bounded = Math.max(0, Math.min(1, next));
    setLocalProgress(bounded);
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    progressTimer.current = window.setTimeout(() => persistProgress({ readingChapter: chapterIndex, readingProgress: bounded, lastReadAt: Date.now() }), 150);
  };

  const updatePositionProgress = (nextPage: number, pageCount: number, targetChapter = chapterIndex) => {
    const boundedPage = Math.max(0, Math.min(Math.max(0, pageCount - 1), nextPage));
    const progress = chapters.length > 0 ? Math.min(1, (targetChapter + (pageCount > 1 ? boundedPage / pageCount : 0)) / chapters.length) : 0;
    updateProgress(progress);
  };

  const changeChapter = (next: number, entry: 'start' | 'end' = 'start') => {
    const bounded = Math.max(0, Math.min(chapters.length - 1, next));
    if (bounded === chapterIndex) return;
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    selectionRequestSequence.current += 1;
    chapterRunSequence.current += 1;
    speechRunSequence.current += 1;
    if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel();
    chapterEntry.current = entry;
    setChapterIndex(bounded);
    setPageIndex(0);
    persistProgress({ readingChapter: bounded, readingProgress: Math.min(1, bounded / Math.max(1, chapters.length)), lastReadAt: Date.now() });
  };

  const translateText = async (text: string, targetLanguage = bookTargetLanguage): Promise<string> => {
    const request = { text, targetLanguage, sourceLanguage: bookSourceLanguage === 'auto' ? undefined : bookSourceLanguage };
    const cached = await cache.get(activeEngine.cacheIdentity, request);
    if (cached) return cached;
    const result = await activeEngine.translate(request);
    await cache.set(activeEngine.cacheIdentity, request, result);
    return result;
  };
  const translationIsUnnecessary = (text: string, targetLanguage = bookTargetLanguage): boolean => bookSourceLanguage === targetLanguage || (bookSourceLanguage === 'auto' && textMatchesTargetLanguage(text, targetLanguage));

  const translateSelection = async (selection = selectionAction) => {
    if (!selection) return;
    const requestId = ++selectionRequestSequence.current;
    const requestIdentity = readerIdentity;
    if (translationIsUnnecessary(selection.source, selection.targetLanguage)) {
      setSelectionAction({ ...selection, loading: false, translation: undefined, error: undefined, notice: `原文已经是${languageLabel(selection.targetLanguage)}，无需翻译`, copied: false });
      return;
    }
    setSelectionAction({ ...selection, loading: true, translation: undefined, error: undefined, copied: false });
    try {
      const result = await translateText(selection.source, selection.targetLanguage);
      if (selectionRequestSequence.current !== requestId || readerIdentityRef.current !== requestIdentity) return;
      setSelectionAction({ ...selection, translation: result, loading: false, error: undefined, copied: false });
    } catch (cause) {
      if (selectionRequestSequence.current === requestId && readerIdentityRef.current === requestIdentity) setSelectionAction({ ...selection, error: errorMessage(cause, '翻译失败'), loading: false, translation: undefined, copied: false });
    }
  };

  const handleSelection = (event: MouseEvent<HTMLParagraphElement>) => {
    const selection = window.getSelection();
    const source = selection?.toString().trim() || '';
    const paragraphId = event.currentTarget.dataset.paragraphId;
    if (!source || !paragraphId) return;
    const fallbackRect = event.currentTarget.getBoundingClientRect();
    const rangeRect = selection && selection.rangeCount > 0 ? selection.getRangeAt(0).getBoundingClientRect() : undefined;
    const rect = rangeRect && (rangeRect.width > 0 || rangeRect.height > 0) ? rangeRect : fallbackRect;
    const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 390;
    setSelectionAction({ paragraphId, source, targetLanguage: selectionTargetLanguage, anchor: { x: Math.min(viewportWidth - 24, Math.max(24, rect.left + rect.width / 2)), y: Math.max(76, rect.top - 10) }, loading: false });
  };
  const dismissSelectionActions = () => { selectionRequestSequence.current += 1; setSelectionAction(undefined); window.getSelection()?.removeAllRanges(); };
  const persistSelectionPreferences = async (preferences?: BookSelectionPreferences) => {
    try { await onSelectionPreferencesChange?.(preferences); } catch { setProgressError('保存划词翻译设置失败'); }
  };
  const changeSelectionTargetLanguage = (targetOverride: '' | TargetLanguage) => {
    const current = selectionAction;
    if (!current) return;
    const targetLanguage = targetOverride || readerPreferences.targetLanguage;
    const next = { ...current, targetLanguage, translation: undefined, error: undefined, notice: undefined, loading: false };
    setSelectionAction(next);
    const nextPreferences: BookSelectionPreferences = targetOverride ? { targetLanguage: targetOverride } : {};
    setSelectionPreferences(nextPreferences);
    void persistSelectionPreferences(targetOverride ? nextPreferences : undefined);
    if (current.translation || current.notice || current.error) void translateSelection(next);
  };
  const copySelection = async () => {
    if (!selectionAction) return;
    try {
      if (!navigator.clipboard?.writeText) throw new Error('clipboard unavailable');
      await navigator.clipboard.writeText(selectionAction.source);
      setSelectionAction((current) => current?.source === selectionAction.source ? { ...current, copied: true, error: undefined } : current);
    } catch { setSelectionAction((current) => current?.source === selectionAction.source ? { ...current, error: '复制失败，请使用系统复制菜单' } : current); }
  };

  const persistBookTargetLanguage = async (language: '' | TargetLanguage) => {
    const nextPreferences: BookTranslationPreferences = { ...bookTranslationPreferences };
    if (language) nextPreferences.targetLanguage = language;
    else delete nextPreferences.targetLanguage;
    const persistedPreferences = nextPreferences.sourceLanguage || nextPreferences.targetLanguage ? nextPreferences : undefined;
    setBookTranslationPreferences(nextPreferences);
    try { await onTranslationPreferencesChange?.(persistedPreferences); } catch { setProgressError('保存本书翻译设置失败'); }
  };
  const clearBookTranslations = () => {
    chapterRunSequence.current += 1;
    setParagraphs((current) => current.map((paragraph) => ({ ...paragraph, translation: undefined })));
    setChapterTranslation(emptyChapterTranslation());
    setContentMode('original');
    setPageIndex(0);
  };
  const changeBookTargetLanguage = async (language: '' | TargetLanguage) => { clearBookTranslations(); await persistBookTargetLanguage(language); };

  const translateChapter = async () => {
    const targets = paragraphs.filter((paragraph) => !paragraph.translation && hasTranslatableContent(paragraph.original) && !translationIsUnnecessary(paragraph.original));
    if (targets.length === 0) return;
    const runId = ++chapterRunSequence.current;
    const requestIdentity = readerIdentity;
    let nextIndex = 0;
    let completed = 0;
    let failed = 0;
    setChapterTranslation({ running: true, completed: 0, total: targets.length, failed: 0 });
    const worker = async () => {
      while (chapterRunSequence.current === runId && readerIdentityRef.current === requestIdentity) {
        const target = targets[nextIndex++];
        if (!target) return;
        try {
          const result = await translateText(target.original);
          if (chapterRunSequence.current !== runId || readerIdentityRef.current !== requestIdentity) return;
          setParagraphs((current) => current.map((paragraph) => paragraph.id === target.id ? { ...paragraph, translation: result } : paragraph));
        } catch { failed += 1; }
        finally {
          if (chapterRunSequence.current === runId && readerIdentityRef.current === requestIdentity) { completed += 1; setChapterTranslation({ running: true, completed, total: targets.length, failed }); }
        }
      }
    };
    await Promise.all([worker(), worker()]);
    if (chapterRunSequence.current === runId && readerIdentityRef.current === requestIdentity) setChapterTranslation({ running: false, completed, total: targets.length, failed });
  };
  const stopChapterTranslation = () => { chapterRunSequence.current += 1; setChapterTranslation((current) => ({ ...current, running: false })); };

  const translatableParagraphs = paragraphs.filter((paragraph) => hasTranslatableContent(paragraph.original));
  const translationParagraphs = translatableParagraphs.filter((paragraph) => !translationIsUnnecessary(paragraph.original));
  const translatedCount = translationParagraphs.filter((paragraph) => paragraph.translation).length;
  const speechParagraphs = translatableParagraphs.flatMap<SpeechQueueItem>((paragraph) => {
    const source = { paragraphId: paragraph.id, text: paragraph.original, language: 'source' as const };
    const target = paragraph.translation
      ? { paragraphId: paragraph.id, text: paragraph.translation, language: 'target' as const }
      : undefined;
    if (contentMode === 'original') return [source];
    if (contentMode === 'translation') return target ? [target] : [];
    return target ? [source, target] : [source];
  });
  const sourcePreviewText = translatableParagraphs[0]?.original ?? book.title;
  const targetPreviewText = translatableParagraphs.find((paragraph) => paragraph.translation)?.translation ?? speechPreviewText(bookTargetLanguage);
  const sourceSpeechLocale = speechLocaleForText(sourcePreviewText, bookSourceLanguage);
  const targetSpeechLocale = speechLocaleForLanguage(bookTargetLanguage) ?? speechLocaleForText(targetPreviewText, bookTargetLanguage);
  const chapterLanguageNotice = translatableParagraphs.length > 0 && translationParagraphs.length === 0 ? `当前内容已是${languageLabel(bookTargetLanguage)}，无需翻译` : undefined;
  const pages = useMemo(() => paginateReaderParagraphs(paragraphs, { blockCapacity: pageCapacityFor(readerPreferences), contentMode }), [paragraphs, readerPreferences.fontSize, contentMode]);
  const pageCount = pages.length;
  const currentPage = pages[Math.min(pageIndex, pageCount - 1)] ?? [];
  useEffect(() => {
    if (chapterEntry.current === 'end') {
      setPageIndex(Math.max(0, pageCount - 1));
      chapterEntry.current = 'start';
      return;
    }
    setPageIndex((current) => Math.min(current, Math.max(0, pageCount - 1)));
  }, [pageCount]);

  const stopSpeech = () => { speechRunSequence.current += 1; if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel(); setSpeechState('idle'); setSpeechParagraphId(undefined); setSpeechParagraphIndex(0); setSpeechError(undefined); };
  const startSpeech = (startIndex = 0, rate = speechRate) => {
    if (!speechSupported || speechParagraphs.length === 0) return;
    const runId = ++speechRunSequence.current;
    const requestIdentity = readerIdentity;
    window.speechSynthesis.cancel();
    setSpeechError(undefined);
    const speakAt = (index: number) => {
      if (speechRunSequence.current !== runId || readerIdentityRef.current !== requestIdentity) return;
      const paragraph = speechParagraphs[index];
      if (!paragraph) { setSpeechState('idle'); setSpeechParagraphId(undefined); setSpeechParagraphIndex(0); return; }
      const utterance = new SpeechSynthesisUtterance(paragraph.text);
      const locale = speechLocaleForText(paragraph.text, paragraph.language === 'target' ? bookTargetLanguage : bookSourceLanguage);
      const voiceURI = paragraph.language === 'source' ? readerPreferences.sourceVoiceURI : readerPreferences.targetVoiceURI;
      const voice = findSpeechVoice(availableSpeechVoices(), voiceURI, locale);
      utterance.lang = voice?.lang ?? locale;
      if (voice) utterance.voice = voice;
      utterance.rate = rate;
      utterance.onend = () => speakAt(index + 1);
      utterance.onerror = () => { if (speechRunSequence.current === runId && readerIdentityRef.current === requestIdentity) { setSpeechState('idle'); setSpeechParagraphId(undefined); setSpeechError('朗读中断，请重试'); } };
      setSpeechState('playing');
      setSpeechParagraphId(paragraph.paragraphId);
      setSpeechParagraphIndex(index);
      const speakingPage = pages.findIndex((page) => page.some((block) => block.paragraphId === paragraph.paragraphId));
      if (speakingPage >= 0) setPageIndex(speakingPage);
      window.speechSynthesis.speak(utterance);
    };
    speakAt(startIndex);
  };
  const pauseSpeech = () => { if (!speechSupported || speechState !== 'playing') return; window.speechSynthesis.pause(); setSpeechState('paused'); };
  const resumeSpeech = () => { if (!speechSupported || speechState !== 'paused') return; window.speechSynthesis.resume(); setSpeechState('playing'); };
  const changeSpeechRate = () => {
    const nextRate = SPEECH_RATE_OPTIONS[(SPEECH_RATE_OPTIONS.indexOf(speechRate as typeof SPEECH_RATE_OPTIONS[number]) + 1) % SPEECH_RATE_OPTIONS.length];
    setReaderPreferences(preferencesStore.update({ speechRate: nextRate }));
    if (speechState === 'playing') startSpeech(speechParagraphIndex, nextRate);
  };
  const readSelection = () => {
    if (!selectionAction || !speechSupported) return;
    stopSpeech();
    const readingTranslation = Boolean(selectionAction.translation);
    const text = selectionAction.translation ?? selectionAction.source;
    const locale = speechLocaleForText(text, readingTranslation ? selectionAction.targetLanguage : bookSourceLanguage);
    const voice = findSpeechVoice(availableSpeechVoices(), readingTranslation ? readerPreferences.targetVoiceURI : readerPreferences.sourceVoiceURI, locale);
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = voice?.lang ?? locale;
    if (voice) utterance.voice = voice;
    utterance.rate = speechRate;
    window.speechSynthesis.speak(utterance);
  };

  const updateReaderPreference = <K extends keyof ReaderPreferences>(key: K, value: ReaderPreferences[K]) => {
    setReaderPreferences(preferencesStore.update({ [key]: value }));
    if (key === 'readingMode') setPageIndex(0);
  };
  const changeSpeechVoice = (kind: 'source' | 'target', voiceURI: string) => {
    stopSpeech();
    updateReaderPreference(kind === 'source' ? 'sourceVoiceURI' : 'targetVoiceURI', voiceURI);
  };
  const previewSpeechVoice = (kind: 'source' | 'target') => {
    if (!speechSupported) return;
    stopSpeech();
    const text = kind === 'source' ? sourcePreviewText : targetPreviewText;
    const locale = kind === 'source' ? sourceSpeechLocale : targetSpeechLocale;
    const voiceURI = kind === 'source' ? readerPreferences.sourceVoiceURI : readerPreferences.targetVoiceURI;
    const voice = findSpeechVoice(availableSpeechVoices(), voiceURI, locale);
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = voice?.lang ?? locale;
    if (voice) utterance.voice = voice;
    utterance.rate = speechRate;
    window.speechSynthesis.speak(utterance);
  };
  const changeContentMode = (mode: ReaderContentMode) => {
    stopSpeech();
    setContentMode(mode);
    setPageIndex(0);
    if (mode !== 'original' && !chapterTranslation.running && translatedCount < translationParagraphs.length) void translateChapter();
  };
  const movePage = (direction: -1 | 1) => {
    if (readerPreferences.readingMode === 'scroll') return;
    setPageDirection(direction);
    const nextPage = pageIndex + direction;
    if (nextPage < 0) {
      if (chapterIndex > 0) changeChapter(chapterIndex - 1, 'end');
      return;
    }
    if (nextPage >= pageCount) {
      if (chapterIndex < chapters.length - 1) changeChapter(chapterIndex + 1);
      return;
    }
    setPageIndex(nextPage);
    updatePositionProgress(nextPage, pageCount);
  };
  const handleReaderTouchStart = (event: TouchEvent<HTMLElement>) => {
    touchStartX.current = event.touches[0]?.clientX;
    touchStartY.current = event.touches[0]?.clientY;
  };
  const handleReaderTouchEnd = (event: TouchEvent<HTMLElement>) => {
    const startX = touchStartX.current;
    const startY = touchStartY.current;
    touchStartX.current = undefined;
    touchStartY.current = undefined;
    if (startX == null || readerPreferences.readingMode !== 'paged') return;
    const distanceX = (event.changedTouches[0]?.clientX ?? startX) - startX;
    const distanceY = startY == null ? 0 : (event.changedTouches[0]?.clientY ?? startY) - startY;
    if (Math.abs(distanceX) < 44 || Math.abs(distanceX) <= Math.abs(distanceY) * 1.15) return;
    touchHandled.current = true;
    window.setTimeout(() => { touchHandled.current = false; }, 240);
    setChromeVisible(false);
    movePage(distanceX > 0 ? -1 : 1);
  };
  const handleReaderClick = (event: MouseEvent<HTMLElement>) => {
    if (touchHandled.current) return;
    if (window.getSelection()?.toString().trim()) return;
    const target = event.target as HTMLElement;
    if (target.closest('button, input, select, a')) return;
    if (readerPreferences.readingMode !== 'paged') {
      setChromeVisible((visible) => !visible);
      return;
    }
    const bounds = event.currentTarget.getBoundingClientRect();
    const position = (event.clientX - bounds.left) / Math.max(1, bounds.width);
    if (position < 0.28) {
      setChromeVisible(false);
      movePage(-1);
    } else if (position > 0.72) {
      setChromeVisible(false);
      movePage(1);
    } else {
      setChromeVisible((visible) => !visible);
    }
  };
  const renderBlocks = (blocks: ReaderPageBlock[]) => blocks.map((block) => (
    <div className={`reader-paragraph ${speechParagraphId === block.paragraphId ? 'reader-paragraph--speaking' : ''}`} key={block.id} aria-current={speechParagraphId === block.paragraphId ? 'true' : undefined}>
      {contentMode !== 'translation' && <p className="reader-original" data-paragraph-id={block.paragraphId} onMouseUp={handleSelection}>{block.original}</p>}
      {contentMode !== 'original' && (block.translation
        ? <p className="reader-translation" lang={bookTargetLanguage}>{block.translation}</p>
        : <p className="reader-translation reader-translation--pending" role="status">{chapterTranslation.running ? '正在翻译本段…' : '本段暂无译文'}</p>)}
    </div>
  ));
  const modeLabel = contentMode === 'original' ? '原文' : contentMode === 'bilingual' ? '双语' : '译文';
  const pageLabel = readerPreferences.readingMode === 'paged' ? `${pageIndex + 1} / ${pageCount}` : `${Math.round(localProgress * 100)}%`;
  const allBlocks = paragraphs.map((paragraph) => ({ id: paragraph.id, paragraphId: paragraph.id, original: paragraph.original, translation: paragraph.translation }));

  return <section className={`reader-page reader-page--${readerPreferences.readingMode} reader-page--theme-${readerPreferences.theme} reader-page--font-${readerPreferences.fontFamily} reader-page--font-${readerPreferences.fontSize} reader-page--line-${readerPreferences.lineHeight} ${chromeVisible ? 'reader-page--chrome-visible' : ''} ${speechState !== 'idle' ? 'reader-page--speech-active' : ''}`} aria-labelledby="reader-title">
    <ReaderToolbar title={book.title} chapterTitle={chapter?.title || '暂无章节'} chapterIndex={chapterIndex} chapterCount={chapters.length} onBack={onBack} />
    <div className="reader-reading-surface">
      <article className="reader-canvas" aria-label={`${modeLabel}阅读内容`} onClick={handleReaderClick} onTouchStart={handleReaderTouchStart} onTouchEnd={handleReaderTouchEnd}>
        <h2 id="reader-title" className="sr-only">{book.title}</h2>
        {paragraphs.length === 0 && <p className="reader-empty">这一章还没有可读内容。</p>}
        {readerPreferences.readingMode === 'paged'
          ? <div className={`reader-page-content reader-page-content--${pageDirection > 0 ? 'next' : 'previous'}`} key={`${readerIdentity}:${pageIndex}:${contentMode}`}>{renderBlocks(currentPage)}</div>
          : <div className="reader-scroll-content">{renderBlocks(allBlocks)}</div>}
        <span className="reader-page-indicator" aria-hidden="true">{pageLabel}</span>
      </article>
    </div>
    {selectionAction && <SelectionActions source={selectionAction.source} targetLanguage={selectionAction.targetLanguage} globalTargetLanguage={readerPreferences.targetLanguage} targetOverride={selectionTargetOverride} anchor={selectionAction.anchor} translation={selectionAction.translation} loading={selectionAction.loading} error={selectionAction.error} notice={selectionAction.notice} copied={selectionAction.copied} canRead={speechSupported} onTranslate={() => { void translateSelection(); }} onRead={readSelection} onTargetLanguageChange={changeSelectionTargetLanguage} onCopy={() => { void copySelection(); }} onDismiss={dismissSelectionActions} />}
    <div className="reader-dock" aria-label="阅读控制">
      <div className="reader-dock__progress">
        <button type="button" onClick={() => movePage(-1)} disabled={readerPreferences.readingMode !== 'paged' || (chapterIndex === 0 && pageIndex === 0)} aria-label="上一页"><ChevronLeft size={17} /></button>
        <input aria-label="阅读进度" type="range" min="0" max="1" step="0.01" value={localProgress} onChange={(event) => updateProgress(Number(event.target.value))} />
        <span>{pageLabel}</span>
        <button type="button" onClick={() => movePage(1)} disabled={readerPreferences.readingMode !== 'paged' || (chapterIndex === chapters.length - 1 && pageIndex >= pageCount - 1)} aria-label="下一页"><ChevronRight size={17} /></button>
      </div>
      <div className="reader-dock__actions">
        <button type="button" className="reader-dock__action" onClick={() => { setContentsOpen(true); setChromeVisible(true); }} aria-label="打开目录"><List size={18} /><span>目录</span></button>
        <ReaderSpeechControls supported={speechSupported} state={speechState} contentLabel={modeLabel} currentIndex={speechParagraphIndex} totalCount={speechParagraphs.length} rate={speechRate} error={speechError} onStart={() => startSpeech()} onPause={pauseSpeech} onResume={resumeSpeech} onStop={stopSpeech} onRateChange={changeSpeechRate} />
        <button type="button" className="reader-dock__action" onClick={() => { setTranslationOpen(true); setChromeVisible(true); }} aria-label="打开翻译与朗读"><Languages size={18} /><span>{modeLabel}</span></button>
        <button type="button" className="reader-dock__action" onClick={() => { setSettingsOpen(true); setChromeVisible(true); }} aria-label="打开排版与主题"><Settings2 size={18} /><span>排版</span></button>
      </div>
    </div>
    {progressError && <div className="reader-feedback reader-feedback--error reader-progress-error" role="alert">{progressError}</div>}
    {contentsOpen && <ReaderSheet title="目录" onClose={() => setContentsOpen(false)}><nav className="reader-toc" aria-label="章节目录">{chapters.map((item, index) => <button type="button" className={index === chapterIndex ? 'is-active' : ''} key={item.id} onClick={() => { setContentsOpen(false); if (index !== chapterIndex) changeChapter(index); }}><span>{String(index + 1).padStart(2, '0')}</span><strong>{item.title || `第 ${index + 1} 章`}</strong><ChevronRight size={16} /></button>)}</nav></ReaderSheet>}
    {translationOpen && <ReaderSheet title="翻译与朗读" onClose={() => setTranslationOpen(false)}><ReaderTranslationControls translatedCount={translatedCount} totalCount={translationParagraphs.length} running={chapterTranslation.running} failed={chapterTranslation.failed} contentMode={contentMode} targetLanguage={bookTargetLanguage} globalTargetLanguage={readerPreferences.targetLanguage} targetOverride={bookTargetOverride} onModeChange={changeContentMode} onStop={stopChapterTranslation} onTargetLanguageChange={(language) => { void changeBookTargetLanguage(language); }} />{chapterLanguageNotice && <span className="reader-language-note" role="status" aria-label={chapterLanguageNotice}>{chapterLanguageNotice}</span>}<ReaderSpeechPreferences supported={speechSupported} voices={speechVoices} sourceLocale={sourceSpeechLocale} targetLocale={targetSpeechLocale} sourceVoiceURI={readerPreferences.sourceVoiceURI} targetVoiceURI={readerPreferences.targetVoiceURI} rate={speechRate} onVoiceChange={changeSpeechVoice} onRateChange={(rate) => updateReaderPreference('speechRate', rate)} onPreview={previewSpeechVoice} /></ReaderSheet>}
    {settingsOpen && <ReaderSheet title="排版与主题" onClose={() => setSettingsOpen(false)}><div className="reader-settings-form"><section><h3>阅读模式</h3><div className="reader-setting-segment"><button type="button" className={readerPreferences.readingMode === 'paged' ? 'is-active' : ''} onClick={() => updateReaderPreference('readingMode', 'paged')}><PanelBottom size={16} /> 分页</button><button type="button" className={readerPreferences.readingMode === 'scroll' ? 'is-active' : ''} onClick={() => updateReaderPreference('readingMode', 'scroll')}><List size={16} /> 滚动</button></div></section><section><h3>字体</h3><div className="reader-setting-segment"><button type="button" className={readerPreferences.fontFamily === 'serif' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontFamily', 'serif')}>衬线</button><button type="button" className={readerPreferences.fontFamily === 'sans' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontFamily', 'sans')}>无衬线</button></div></section><section><h3>字号</h3><div className="reader-setting-segment reader-setting-segment--four"><button type="button" className={readerPreferences.fontSize === 'small' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'small')}>小</button><button type="button" className={readerPreferences.fontSize === 'medium' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'medium')}>中</button><button type="button" className={readerPreferences.fontSize === 'large' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'large')}>大</button><button type="button" className={readerPreferences.fontSize === 'x-large' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'x-large')}>特大</button></div></section><section><h3>行距</h3><div className="reader-setting-segment reader-setting-segment--three"><button type="button" className={readerPreferences.lineHeight === 'compact' ? 'is-active' : ''} onClick={() => updateReaderPreference('lineHeight', 'compact')}>紧凑</button><button type="button" className={readerPreferences.lineHeight === 'comfortable' ? 'is-active' : ''} onClick={() => updateReaderPreference('lineHeight', 'comfortable')}>舒适</button><button type="button" className={readerPreferences.lineHeight === 'relaxed' ? 'is-active' : ''} onClick={() => updateReaderPreference('lineHeight', 'relaxed')}>宽松</button></div></section><section><h3>页面主题</h3><div className="reader-setting-segment reader-setting-segment--three"><button type="button" className={readerPreferences.theme === 'paper' ? 'is-active' : ''} onClick={() => updateReaderPreference('theme', 'paper')}><Sun size={15} /> 纸张</button><button type="button" className={readerPreferences.theme === 'sepia' ? 'is-active' : ''} onClick={() => updateReaderPreference('theme', 'sepia')}><BookOpen size={15} /> 柔和</button><button type="button" className={readerPreferences.theme === 'night' ? 'is-active' : ''} onClick={() => updateReaderPreference('theme', 'night')}><Moon size={15} /> 夜间</button></div></section></div></ReaderSheet>}
  </section>;
}
