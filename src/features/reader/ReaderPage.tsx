import { useEffect, useMemo, useRef, useState, type MouseEvent } from 'react';

import { TranslationCache } from '../../domain/ai/translationCache';
import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import type { Book, BookSelectionPreferences, BookTranslationPreferences } from '../../domain/books/book';
import { ReaderSpeechControls, type SpeechPlaybackState } from './ReaderSpeechControls';
import { ReaderToolbar } from './ReaderToolbar';
import { ReaderTranslationControls } from './ReaderTranslationControls';
import { SelectionActions } from './SelectionActions';
import { chaptersForBook, paragraphsForChapter, type ReaderParagraph } from './readerState';
import { availableSpeechVoices, findSpeechVoice, languageLabel, READER_LANGUAGE_OPTIONS, ReaderPreferencesStore, speechLocaleForText, textMatchesTargetLanguage, type ReaderLanguage, type ReaderPreferences } from './readerPreferences';
import './reader.css';

type ProgressUpdate = Pick<Book, 'readingChapter' | 'readingProgress' | 'lastReadAt'>;
type TargetLanguage = Exclude<ReaderLanguage, 'auto'>;
type SelectionActionState = { paragraphId: string; source: string; targetLanguage: TargetLanguage; anchor: { x: number; y: number }; translation?: string; error?: string; notice?: string; loading: boolean; copied?: boolean };
type ChapterTranslationState = { running: boolean; completed: number; total: number; failed: number };
export type ReaderPageProps = { book: Book; engine?: TranslationEngine; onProgress: (progress: ProgressUpdate) => void | Promise<void>; onTranslationPreferencesChange?: (preferences?: BookTranslationPreferences) => void | Promise<void>; onSelectionPreferencesChange?: (preferences?: BookSelectionPreferences) => void | Promise<void>; onBack: () => void };

const errorMessage = (cause: unknown, fallback: string): string => cause instanceof Error && cause.message.trim() ? cause.message : fallback;
const emptyChapterTranslation = (): ChapterTranslationState => ({ running: false, completed: 0, total: 0, failed: 0 });
const hasTranslatableContent = (text: string): boolean => /[\p{L}\p{N}]/u.test(text);

export function ReaderPage({ book, engine, onProgress, onTranslationPreferencesChange, onSelectionPreferencesChange, onBack }: ReaderPageProps) {
  const chapters = useMemo(() => chaptersForBook(book), [book.id, book.format, book.bytes, book.text]);
  const initialChapter = Math.min(book.readingChapter, Math.max(0, chapters.length - 1));
  const [chapterIndex, setChapterIndex] = useState(initialChapter);
  const [paragraphs, setParagraphs] = useState<ReaderParagraph[]>(() => paragraphsForChapter(chapters[initialChapter] ?? { id: 'empty', title: '暂无章节', href: '', content: '' }));
  const [selectionAction, setSelectionAction] = useState<SelectionActionState>();
  const [chapterTranslation, setChapterTranslation] = useState<ChapterTranslationState>(emptyChapterTranslation);
  const [showTranslations, setShowTranslations] = useState(false);
  const [speechState, setSpeechState] = useState<SpeechPlaybackState>('idle');
  const [speechParagraphId, setSpeechParagraphId] = useState<string>();
  const [speechParagraphIndex, setSpeechParagraphIndex] = useState(0);
  const preferencesStore = useMemo(() => new ReaderPreferencesStore(), []);
  const [readerPreferences, setReaderPreferences] = useState<ReaderPreferences>(() => preferencesStore.get());
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
    setShowTranslations(false);
    setSpeechState('idle');
    setSpeechParagraphId(undefined);
    setSpeechParagraphIndex(0);
    setSpeechError(undefined);
  };

  useEffect(() => {
    const nextChapter = Math.min(book.readingChapter, Math.max(0, chapters.length - 1));
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    setChapterIndex(nextChapter);
    setLocalProgress(book.readingProgress);
    setProgressError(undefined);
    resetTransientState();
  }, [book.id, book.bytes, book.text]);

  useEffect(() => {
    setLocalProgress(book.readingProgress);
  }, [book.id, book.readingProgress]);

  useEffect(() => {
    setBookTranslationPreferences(book.translationPreferences ?? {});
    setSelectionPreferences(book.selectionPreferences ?? {});
  }, [book.id]);

  useEffect(() => {
    const onStorage = (event: StorageEvent) => {
      if (event.key === 'airread.readerPreferences.v1') setReaderPreferences(preferencesStore.get());
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, [preferencesStore]);

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
    progressQueue.current = progressQueue.current
      .then(() => onProgressRef.current(progress))
      .catch((cause) => {
        if (bookIdentityRef.current === targetBookId) setProgressError(errorMessage(cause, '保存阅读进度失败'));
      });
  };

  const updateProgress = (next: number) => {
    const bounded = Math.max(0, Math.min(1, next));
    setLocalProgress(bounded);
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    progressTimer.current = window.setTimeout(() => persistProgress({ readingChapter: chapterIndex, readingProgress: bounded, lastReadAt: Date.now() }), 150);
  };

  const changeChapter = (next: number) => {
    const bounded = Math.max(0, Math.min(chapters.length - 1, next));
    if (bounded === chapterIndex) return;
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    selectionRequestSequence.current += 1;
    chapterRunSequence.current += 1;
    speechRunSequence.current += 1;
    if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel();
    setChapterIndex(bounded);
    persistProgress({ readingChapter: bounded, readingProgress: localProgress, lastReadAt: Date.now() });
  };

  const translateText = async (text: string, targetLanguage = bookTargetLanguage): Promise<string> => {
    const request = {
      text,
      targetLanguage,
      sourceLanguage: bookSourceLanguage === 'auto' ? undefined : bookSourceLanguage,
    };
    const cached = await cache.get(activeEngine.cacheIdentity, request);
    if (cached) return cached;
    const result = await activeEngine.translate(request);
    await cache.set(activeEngine.cacheIdentity, request, result);
    return result;
  };
  const translationIsUnnecessary = (text: string, targetLanguage = bookTargetLanguage): boolean => bookSourceLanguage === targetLanguage
    || (bookSourceLanguage === 'auto' && textMatchesTargetLanguage(text, targetLanguage));

  const translateSelection = async (selection = selectionAction) => {
    if (!selection) return;
    const { source, paragraphId } = selection;
    const requestId = ++selectionRequestSequence.current;
    const requestIdentity = readerIdentity;
    if (translationIsUnnecessary(source, selection.targetLanguage)) {
      setSelectionAction({ ...selection, loading: false, translation: undefined, error: undefined, notice: `原文已经是${languageLabel(selection.targetLanguage)}，无需翻译`, copied: false });
      return;
    }
    setSelectionAction({ ...selection, loading: true, translation: undefined, error: undefined, copied: false });
    try {
      const result = await translateText(source, selection.targetLanguage);
      if (selectionRequestSequence.current !== requestId || readerIdentityRef.current !== requestIdentity) return;
      setSelectionAction({ ...selection, translation: result, loading: false, error: undefined, copied: false });
    } catch (cause) {
      if (selectionRequestSequence.current === requestId && readerIdentityRef.current === requestIdentity) {
        setSelectionAction({ ...selection, error: errorMessage(cause, '翻译失败'), loading: false, translation: undefined, copied: false });
      }
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
    setSelectionAction({
      paragraphId,
      source,
      targetLanguage: selectionTargetLanguage,
      anchor: {
        x: Math.min(viewportWidth - 24, Math.max(24, rect.left + rect.width / 2)),
        y: Math.max(76, rect.top - 10),
      },
      loading: false,
    });
  };
  const dismissSelectionActions = () => {
    selectionRequestSequence.current += 1;
    setSelectionAction(undefined);
    window.getSelection()?.removeAllRanges();
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
    } catch {
      setSelectionAction((current) => current?.source === selectionAction.source ? { ...current, error: '复制失败，请使用系统复制菜单' } : current);
    }
  };

  const persistBookTargetLanguage = async (language: '' | TargetLanguage) => {
    const nextPreferences: BookTranslationPreferences = { ...bookTranslationPreferences };
    if (language) nextPreferences.targetLanguage = language;
    else delete nextPreferences.targetLanguage;
    const persistedPreferences = nextPreferences.sourceLanguage || nextPreferences.targetLanguage ? nextPreferences : undefined;
    setBookTranslationPreferences(nextPreferences);
    try {
      await onTranslationPreferencesChange?.(persistedPreferences);
    } catch {
      setProgressError('保存本书翻译设置失败');
    }
  };
  const persistSelectionPreferences = async (preferences?: BookSelectionPreferences) => {
    try {
      await onSelectionPreferencesChange?.(preferences);
    } catch {
      setProgressError('保存划词翻译设置失败');
    }
  };
  const clearBookTranslations = () => {
    setParagraphs((current) => current.map((paragraph) => ({ ...paragraph, translation: undefined })));
    chapterRunSequence.current += 1;
    resetTransientState();
  };
  const changeBookTargetLanguage = async (language: '' | TargetLanguage) => {
    clearBookTranslations();
    await persistBookTargetLanguage(language);
  };

  const translateChapter = async () => {
    const targets = paragraphs.filter((paragraph) => !paragraph.translation && hasTranslatableContent(paragraph.original) && !translationIsUnnecessary(paragraph.original));
    if (targets.length === 0) {
      setShowTranslations(true);
      return;
    }
    const runId = ++chapterRunSequence.current;
    const requestIdentity = readerIdentity;
    let nextIndex = 0;
    let completed = 0;
    let failed = 0;
    setShowTranslations(true);
    setChapterTranslation({ running: true, completed: 0, total: targets.length, failed: 0 });

    const worker = async () => {
      while (chapterRunSequence.current === runId && readerIdentityRef.current === requestIdentity) {
        const target = targets[nextIndex++];
        if (!target) return;
        try {
          const result = await translateText(target.original);
          if (chapterRunSequence.current !== runId || readerIdentityRef.current !== requestIdentity) return;
          setParagraphs((current) => current.map((paragraph) => paragraph.id === target.id ? { ...paragraph, translation: result } : paragraph));
        } catch {
          failed += 1;
        } finally {
          if (chapterRunSequence.current === runId && readerIdentityRef.current === requestIdentity) {
            completed += 1;
            setChapterTranslation({ running: true, completed, total: targets.length, failed });
          }
        }
      }
    };

    await Promise.all([worker(), worker()]);
    if (chapterRunSequence.current === runId && readerIdentityRef.current === requestIdentity) {
      setChapterTranslation({ running: false, completed, total: targets.length, failed });
    }
  };
  const stopChapterTranslation = () => {
    chapterRunSequence.current += 1;
    setChapterTranslation((current) => ({ ...current, running: false }));
  };

  const translatableParagraphs = paragraphs.filter((paragraph) => hasTranslatableContent(paragraph.original));
  const translationParagraphs = translatableParagraphs.filter((paragraph) => !translationIsUnnecessary(paragraph.original));
  const translatedCount = translationParagraphs.filter((paragraph) => paragraph.translation).length;
  const speechParagraphs = translatableParagraphs;
  const chapterLanguageNotice = translatableParagraphs.length > 0 && translationParagraphs.length === 0
    ? `当前内容已是${languageLabel(bookTargetLanguage)}，无需翻译`
    : undefined;
  const stopSpeech = () => {
    speechRunSequence.current += 1;
    if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel();
    setSpeechState('idle');
    setSpeechParagraphId(undefined);
    setSpeechParagraphIndex(0);
    setSpeechError(undefined);
  };
  const startSpeech = (startIndex = 0, rate = speechRate) => {
    if (!speechSupported || speechParagraphs.length === 0) return;
    const runId = ++speechRunSequence.current;
    const requestIdentity = readerIdentity;
    window.speechSynthesis.cancel();
    setSpeechError(undefined);

    const speakAt = (index: number) => {
      if (speechRunSequence.current !== runId || readerIdentityRef.current !== requestIdentity) return;
      const paragraph = speechParagraphs[index];
      if (!paragraph) {
        setSpeechState('idle');
        setSpeechParagraphId(undefined);
        setSpeechParagraphIndex(0);
        return;
      }
      const utterance = new SpeechSynthesisUtterance(paragraph.original);
      const locale = speechLocaleForText(paragraph.original, bookSourceLanguage);
      const voice = findSpeechVoice(availableSpeechVoices(), readerPreferences.voiceURI, locale);
      utterance.lang = voice?.lang ?? locale;
      if (voice) utterance.voice = voice;
      utterance.rate = rate;
      utterance.onend = () => speakAt(index + 1);
      utterance.onerror = () => {
        if (speechRunSequence.current !== runId || readerIdentityRef.current !== requestIdentity) return;
        setSpeechState('idle');
        setSpeechParagraphId(undefined);
        setSpeechError('朗读中断，请重试');
      };
      setSpeechState('playing');
      setSpeechParagraphId(paragraph.id);
      setSpeechParagraphIndex(index);
      window.speechSynthesis.speak(utterance);
    };

    speakAt(startIndex);
  };
  const pauseSpeech = () => {
    if (!speechSupported || speechState !== 'playing') return;
    window.speechSynthesis.pause();
    setSpeechState('paused');
  };
  const resumeSpeech = () => {
    if (!speechSupported || speechState !== 'paused') return;
    window.speechSynthesis.resume();
    setSpeechState('playing');
  };
  const changeSpeechRate = () => {
    const rates = [0.8, 1, 1.2, 1.5] as const;
    const nextRate = rates[(rates.indexOf(speechRate as typeof rates[number]) + 1) % rates.length];
    setReaderPreferences(preferencesStore.update({ speechRate: nextRate }));
    if (speechState === 'playing') startSpeech(speechParagraphIndex, nextRate);
  };
  const readSelection = () => {
    if (!selectionAction || !speechSupported) return;
    stopSpeech();
    const utterance = new SpeechSynthesisUtterance(selectionAction.source);
    const locale = speechLocaleForText(selectionAction.source, bookSourceLanguage);
    const voice = findSpeechVoice(availableSpeechVoices(), readerPreferences.voiceURI, locale);
    utterance.lang = voice?.lang ?? locale;
    if (voice) utterance.voice = voice;
    utterance.rate = speechRate;
    window.speechSynthesis.speak(utterance);
  };

  return <section className={`reader-page ${speechState !== 'idle' ? 'reader-page--speech-active' : ''}`} aria-labelledby="reader-title">
    <ReaderToolbar title={book.title} chapterTitle={chapter?.title || '暂无章节'} chapterIndex={chapterIndex} chapterCount={chapters.length} onBack={onBack} onPrevious={() => changeChapter(chapterIndex - 1)} onNext={() => changeChapter(chapterIndex + 1)} />
    <div className="reader-page__overview">
      <div className="reader-page__meta"><span>{book.author || 'AirRead 灵阅'}</span><span>{languageLabel(bookSourceLanguage)} → {languageLabel(bookTargetLanguage)} · {Math.round(localProgress * 100)}% 已读</span></div>
      <div className="reader-reading-tools">
        <ReaderTranslationControls translatedCount={translatedCount} totalCount={translationParagraphs.length} running={chapterTranslation.running} failed={chapterTranslation.failed} showTranslations={showTranslations} targetLanguage={bookTargetLanguage} globalTargetLanguage={readerPreferences.targetLanguage} targetOverride={bookTargetOverride} onShowOriginal={() => setShowTranslations(false)} onShowBilingual={() => { setShowTranslations(true); if (!chapterTranslation.running && translatedCount < translationParagraphs.length) void translateChapter(); }} onStop={stopChapterTranslation} onTargetLanguageChange={(language) => { void changeBookTargetLanguage(language); }} />
        {chapterLanguageNotice && <span className="reader-language-note" role="status" aria-label={chapterLanguageNotice}>{chapterLanguageNotice}</span>}
        <ReaderSpeechControls supported={speechSupported} state={speechState} currentIndex={speechParagraphIndex} totalCount={speechParagraphs.length} rate={speechRate} error={speechError} onStart={() => startSpeech()} onPause={pauseSpeech} onResume={resumeSpeech} onStop={stopSpeech} onRateChange={changeSpeechRate} />
      </div>
    </div>
    <article className="reader-canvas" aria-label="双语阅读内容">
      <h2 id="reader-title" className="sr-only">{book.title}</h2>
      {paragraphs.length === 0 && <p className="reader-empty">这一章还没有可读内容。</p>}
      {paragraphs.map((paragraph) => <div className={`reader-paragraph ${speechParagraphId === paragraph.id ? 'reader-paragraph--speaking' : ''}`} key={paragraph.id} aria-current={speechParagraphId === paragraph.id ? 'true' : undefined}><p className="reader-original" data-paragraph-id={paragraph.id} onMouseUp={handleSelection}>{paragraph.original}</p>{showTranslations && paragraph.translation && <p className="reader-translation" lang={bookTargetLanguage}>{paragraph.translation}</p>}</div>)}
    </article>
    {selectionAction && <SelectionActions source={selectionAction.source} targetLanguage={selectionAction.targetLanguage} globalTargetLanguage={readerPreferences.targetLanguage} targetOverride={selectionTargetOverride} anchor={selectionAction.anchor} translation={selectionAction.translation} loading={selectionAction.loading} error={selectionAction.error} notice={selectionAction.notice} copied={selectionAction.copied} canRead={speechSupported} onTranslate={() => { void translateSelection(); }} onRead={readSelection} onTargetLanguageChange={changeSelectionTargetLanguage} onCopy={() => { void copySelection(); }} onDismiss={dismissSelectionActions} />}
    <footer className="reader-footer"><label htmlFor="reading-progress">阅读进度</label><input id="reading-progress" type="range" min="0" max="1" step="0.01" value={localProgress} onChange={(event) => updateProgress(Number(event.target.value))} /><span>{Math.round(localProgress * 100)}%</span></footer>
    {progressError && <div className="reader-feedback reader-feedback--error reader-progress-error" role="alert">{progressError}</div>}
  </section>;
}
