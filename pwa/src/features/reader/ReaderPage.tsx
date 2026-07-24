import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent } from 'react';

import { TranslationCache } from '../../domain/ai/translationCache';
import { createTranslationEngine } from '../../domain/ai/providerRegistry';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import type { Book } from '../../domain/books/book';
import { ReaderToolbar } from './ReaderToolbar';
import { SelectionActions } from './SelectionActions';
import { chaptersForBook, paragraphsForChapter, type ReaderParagraph } from './readerState';
import './reader.css';

type ProgressUpdate = Pick<Book, 'readingChapter' | 'readingProgress' | 'lastReadAt'>;
export type ReaderPageProps = { book: Book; engine?: TranslationEngine; onProgress: (progress: ProgressUpdate) => void | Promise<void>; onBack: () => void };

const errorMessage = (cause: unknown, fallback: string): string => cause instanceof Error && cause.message.trim() ? cause.message : fallback;

export function ReaderPage({ book, engine, onProgress, onBack }: ReaderPageProps) {
  const chapters = useMemo(() => chaptersForBook(book), [book.id, book.format, book.bytes, book.text]);
  const initialChapter = Math.min(book.readingChapter, Math.max(0, chapters.length - 1));
  const [chapterIndex, setChapterIndex] = useState(initialChapter);
  const [paragraphs, setParagraphs] = useState<ReaderParagraph[]>(() => paragraphsForChapter(chapters[initialChapter] ?? { id: 'empty', title: '暂无章节', href: '', content: '' }));
  const [selectedText, setSelectedText] = useState('');
  const [selectedParagraphId, setSelectedParagraphId] = useState<string>();
  const [translation, setTranslation] = useState<string>();
  const [translationError, setTranslationError] = useState<string>();
  const [translating, setTranslating] = useState(false);
  const [localProgress, setLocalProgress] = useState(book.readingProgress);
  const [progressError, setProgressError] = useState<string>();
  const activeEngine = useMemo(() => engine ?? createTranslationEngine(new ProviderProfileStore().selected()), [engine]);
  const cache = useMemo(() => new TranslationCache(), []);
  const requestSequence = useRef(0);
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

  const resetTransientState = () => {
    requestSequence.current += 1;
    setTranslation(undefined);
    setTranslationError(undefined);
    setTranslating(false);
    setSelectedText('');
    setSelectedParagraphId(undefined);
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
    setParagraphs(paragraphsForChapter(chapter ?? { id: 'empty', title: '暂无章节', href: '', content: '' }));
    resetTransientState();
  }, [book.id, book.bytes, book.text, chapterIndex, chapter?.id]);

  useEffect(() => () => {
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    requestSequence.current += 1;
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
    requestSequence.current += 1;
    setChapterIndex(bounded);
    persistProgress({ readingChapter: bounded, readingProgress: localProgress, lastReadAt: Date.now() });
  };

  const selectParagraph = (paragraphId: string | undefined, text: string) => {
    setSelectedText(text.trim());
    setSelectedParagraphId(paragraphId);
  };
  const handleSelection = (event: MouseEvent<HTMLParagraphElement>) => {
    selectParagraph(event.currentTarget.dataset.paragraphId, window.getSelection()?.toString().trim() || event.currentTarget.textContent || '');
  };
  const handleParagraphKeyDown = (event: KeyboardEvent<HTMLParagraphElement>) => {
    if (event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    selectParagraph(event.currentTarget.dataset.paragraphId, event.currentTarget.textContent || '');
  };

  const translateSelection = async () => {
    if (!selectedText) return;
    const requestId = ++requestSequence.current;
    const requestIdentity = readerIdentity;
    const paragraphId = selectedParagraphId;
    setTranslating(true);
    setTranslationError(undefined);
    try {
      const request = { text: selectedText, targetLanguage: 'zh-CN', sourceLanguage: 'auto' };
      const cached = await cache.get(activeEngine.cacheIdentity, request);
      const result = cached ?? await activeEngine.translate(request);
      if (!cached) await cache.set(activeEngine.cacheIdentity, request, result);
      if (requestSequence.current !== requestId || readerIdentityRef.current !== requestIdentity) return;
      setTranslation(result);
      if (paragraphId) setParagraphs((current) => current.map((paragraph) => paragraph.id === paragraphId ? { ...paragraph, translation: result } : paragraph));
    } catch (cause) {
      if (requestSequence.current === requestId && readerIdentityRef.current === requestIdentity) setTranslationError(errorMessage(cause, '翻译失败'));
    } finally {
      if (requestSequence.current === requestId && readerIdentityRef.current === requestIdentity) setTranslating(false);
    }
  };

  return <section className="reader-page" aria-labelledby="reader-title">
    <ReaderToolbar title={book.title} chapterTitle={chapter?.title || '暂无章节'} chapterIndex={chapterIndex} chapterCount={chapters.length} onBack={onBack} onPrevious={() => changeChapter(chapterIndex - 1)} onNext={() => changeChapter(chapterIndex + 1)} />
    <div className="reader-page__meta"><span>{book.author || 'AirRead 灵阅'}</span><span>{Math.round(localProgress * 100)}% 已读</span></div>
    <article className="reader-canvas" aria-label="双语阅读内容">
      <h2 id="reader-title" className="sr-only">{book.title}</h2>
      {paragraphs.length === 0 && <p className="reader-empty">这一章还没有可读内容。</p>}
      {paragraphs.map((paragraph) => <div className="reader-paragraph" key={paragraph.id}><p className="reader-original" data-paragraph-id={paragraph.id} onMouseUp={handleSelection} onKeyDown={handleParagraphKeyDown} tabIndex={0}>{paragraph.original}</p>{paragraph.translation && <p className="reader-translation">{paragraph.translation}</p>}</div>)}
      <SelectionActions visible={Boolean(selectedText)} loading={translating} onTranslate={translateSelection} onDismiss={() => { setSelectedText(''); setSelectedParagraphId(undefined); }} />
      {translationError && <div className="reader-feedback reader-feedback--error" role="alert"><span>{translationError}</span><button type="button" onClick={translateSelection} aria-label="重试翻译">重试翻译</button></div>}
      {translation && <div className="reader-feedback reader-feedback--translation"><span className="reader-feedback__label">选中文本译文</span><p>{translation}</p></div>}
    </article>
    <footer className="reader-footer"><label htmlFor="reading-progress">阅读进度</label><input id="reading-progress" type="range" min="0" max="1" step="0.01" value={localProgress} onChange={(event) => updateProgress(Number(event.target.value))} /><span>{Math.round(localProgress * 100)}%</span></footer>
    {progressError && <div className="reader-feedback reader-feedback--error reader-progress-error" role="alert">{progressError}</div>}
  </section>;
}
