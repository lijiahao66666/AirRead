import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent, type PointerEvent as ReactPointerEvent, type ReactNode, type TouchEvent } from 'react';
import { BookOpen, ChevronRight, Languages, List, Moon, PanelBottom, Settings2, Sun, Volume2, X } from 'lucide-react';

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
import { availableSpeechVoices, findSpeechVoice, languageLabel, READER_LANGUAGE_OPTIONS, ReaderPreferencesStore, speechLocaleForLanguage, speechLocaleForText, speechPreviewText, textMatchesTargetLanguage, type ReaderLanguage, type ReaderPreferences } from './readerPreferences';
import { paginateReaderParagraphs, type ReaderContentMode, type ReaderPageBlock } from './readerPagination';
import './reader.css';

type ProgressUpdate = Pick<Book, 'readingChapter' | 'readingProgress' | 'lastReadAt'>;
type TargetLanguage = Exclude<ReaderLanguage, 'auto'>;
type SelectionActionState = { paragraphId: string; source: string; targetLanguage: TargetLanguage; anchor: { x: number; y: number }; placement: 'above' | 'below'; translation?: string; error?: string; notice?: string; loading: boolean; copied?: boolean };
type ChapterTranslationState = { running: boolean; completed: number; total: number; failed: number };
type SpeechQueueItem = { paragraphId: string; text: string; language: 'source' | 'target' };
type MobileSelectionPress = { paragraph: HTMLParagraphElement; x: number; y: number };
type MobileSelection = { paragraphId: string; startParagraph: HTMLParagraphElement; start: Range; ranges: Range[]; source: string; anchor: { x: number; y: number }; placement: 'above' | 'below' };
type SelectionHighlight = { left: number; top: number; width: number; height: number };
type RangeLayout = { left: number; top: number; right: number; bottom: number; width: number; height: number };
type PointCaretDocument = Document & {
  caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null;
  caretRangeFromPoint?: (x: number, y: number) => Range | null;
};
export type ReaderPageProps = { book: Book; chapters: Chapter[]; engine?: TranslationEngine; onProgress: (progress: ProgressUpdate) => void | Promise<void>; onTranslationPreferencesChange?: (preferences?: BookTranslationPreferences) => void | Promise<void>; onSelectionPreferencesChange?: (preferences?: BookSelectionPreferences) => void | Promise<void>; onBack: () => void };

const errorMessage = (cause: unknown, fallback: string): string => cause instanceof Error && cause.message.trim() ? cause.message : fallback;
const emptyChapterTranslation = (): ChapterTranslationState => ({ running: false, completed: 0, total: 0, failed: 0 });
const hasTranslatableContent = (text: string): boolean => /[\p{L}\p{N}]/u.test(text);
type PaginationViewport = { contentWidth: number; contentHeight: number };
const isMobileViewport = (): boolean => window.matchMedia?.('(max-width: 42rem)').matches ?? false;
const isCjkCharacter = (character: string): boolean => /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(character);
const sentenceAt = (text: string, index: number): string => {
  const before = text.slice(0, index);
  const after = text.slice(index);
  const start = Math.max(before.lastIndexOf('。'), before.lastIndexOf('！'), before.lastIndexOf('？'), before.lastIndexOf('!'), before.lastIndexOf('?')) + 1;
  const endOffset = after.search(/[。！？!?]/u);
  const end = endOffset < 0 ? text.length : index + endOffset + 1;
  return text.slice(start, end).trim();
};
const sentenceBoundsAt = (text: string, index: number): { start: number; end: number } => {
  const before = text.slice(0, index);
  const after = text.slice(index);
  const start = Math.max(before.lastIndexOf('。'), before.lastIndexOf('！'), before.lastIndexOf('？'), before.lastIndexOf('!'), before.lastIndexOf('?')) + 1;
  const endOffset = after.search(/[。！？!?]/u);
  return { start, end: endOffset < 0 ? text.length : index + endOffset + 1 };
};
const segmentAt = (text: string, index: number): string => {
  const boundedIndex = Math.max(0, Math.min(Math.max(0, text.length - 1), index));
  if (isCjkCharacter(text[boundedIndex] ?? '')) return sentenceAt(text, boundedIndex);
  for (const match of text.matchAll(/[\p{L}\p{N}][\p{L}\p{N}'’\-]*/gu)) {
    const start = match.index ?? 0;
    if (boundedIndex >= start && boundedIndex < start + match[0].length) return match[0];
  }
  return sentenceAt(text, boundedIndex);
};
const segmentBoundsAt = (text: string, index: number): { start: number; end: number } => {
  const boundedIndex = Math.max(0, Math.min(Math.max(0, text.length - 1), index));
  if (isCjkCharacter(text[boundedIndex] ?? '')) return sentenceBoundsAt(text, boundedIndex);
  for (const match of text.matchAll(/[\p{L}\p{N}][\p{L}\p{N}'’\-]*/gu)) {
    const start = match.index ?? 0;
    if (boundedIndex >= start && boundedIndex < start + match[0].length) return { start, end: start + match[0].length };
  }
  return sentenceBoundsAt(text, boundedIndex);
};
const textOffsetInParagraph = (paragraph: HTMLElement, node: Node, offset: number): number | undefined => {
  const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
  let textNode: Node | null;
  let textOffset = 0;
  while ((textNode = walker.nextNode())) {
    const length = textNode.textContent?.length ?? 0;
    if (textNode === node) return textOffset + Math.max(0, Math.min(offset, length));
    textOffset += length;
  }
  return undefined;
};
const rangeAtPoint = (x: number, y: number): Range | undefined => {
  const pointDocument = document as PointCaretDocument;
  const range = pointDocument.caretRangeFromPoint?.(x, y);
  if (range) return range;
  const caretPosition = pointDocument.caretPositionFromPoint?.(x, y);
  if (!caretPosition) return undefined;
  const caretRange = document.createRange();
  caretRange.setStart(caretPosition.offsetNode, caretPosition.offset);
  caretRange.collapse(true);
  return caretRange;
};
const rangeForTextOffsets = (paragraph: HTMLParagraphElement, start: number, end: number): Range | undefined => {
  const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
  let node: Node | null;
  let offset = 0;
  let startPoint: { node: Node; offset: number } | undefined;
  let endPoint: { node: Node; offset: number } | undefined;
  while ((node = walker.nextNode())) {
    const length = node.textContent?.length ?? 0;
    if (!startPoint && start >= offset && start <= offset + length) startPoint = { node, offset: start - offset };
    if (!endPoint && end >= offset && end <= offset + length) endPoint = { node, offset: end - offset };
    if (startPoint && endPoint) break;
    offset += length;
  }
  if (!startPoint || !endPoint) return undefined;
  const range = document.createRange();
  range.setStart(startPoint.node, startPoint.offset);
  range.setEnd(endPoint.node, endPoint.offset);
  return range;
};
const rangeForPointSelection = (paragraph: HTMLParagraphElement, point: Range): Range | undefined => {
  const text = paragraph.textContent ?? '';
  const offset = textOffsetInParagraph(paragraph, point.startContainer, point.startOffset);
  if (offset == null || !text) return undefined;
  const bounds = segmentBoundsAt(text, offset);
  return rangeForTextOffsets(paragraph, bounds.start, bounds.end);
};
const orderedRange = (first: Range, second: Range): Range => {
  const range = document.createRange();
  const firstComesFirst = first.compareBoundaryPoints(Range.START_TO_START, second) <= 0;
  const start = firstComesFirst ? first : second;
  const end = firstComesFirst ? second : first;
  range.setStart(start.startContainer, start.startOffset);
  range.setEnd(end.endContainer, end.endOffset);
  return range;
};
const originalParagraphForRange = (range: Range): HTMLParagraphElement | undefined => {
  const node = range.startContainer;
  const element = node instanceof Element ? node : node.parentElement;
  return element?.closest<HTMLParagraphElement>('p.reader-original[data-paragraph-id]') ?? undefined;
};
const rangeFromStartToParagraphEnd = (start: Range, paragraph: HTMLParagraphElement): Range => {
  const range = document.createRange();
  range.selectNodeContents(paragraph);
  range.setStart(start.startContainer, start.startOffset);
  return range;
};
const rangeFromParagraphStartToEnd = (paragraph: HTMLParagraphElement, end: Range): Range => {
  const range = document.createRange();
  range.selectNodeContents(paragraph);
  range.setEnd(end.endContainer, end.endOffset);
  return range;
};
const fullParagraphRange = (paragraph: HTMLParagraphElement): Range => {
  const range = document.createRange();
  range.selectNodeContents(paragraph);
  return range;
};
const sourceFromRanges = (ranges: Range[]): string => ranges.map((range) => range.toString().trim()).filter(Boolean).join('\n\n');
const mobileSelectionRanges = (canvas: HTMLElement, startParagraph: HTMLParagraphElement, start: Range, endParagraph: HTMLParagraphElement, end: Range): Range[] => {
  const paragraphs = Array.from(canvas.querySelectorAll<HTMLParagraphElement>('p.reader-original[data-paragraph-id]'));
  const startIndex = paragraphs.indexOf(startParagraph);
  const endIndex = paragraphs.indexOf(endParagraph);
  if (startIndex < 0 || endIndex < 0) return [];
  if (startIndex === endIndex) return [orderedRange(start, end)];
  const forward = startIndex < endIndex;
  const ranges: Range[] = [forward ? rangeFromStartToParagraphEnd(start, startParagraph) : rangeFromStartToParagraphEnd(end, endParagraph)];
  const firstIntermediateIndex = forward ? startIndex + 1 : endIndex + 1;
  const lastIntermediateIndex = forward ? endIndex - 1 : startIndex - 1;
  for (let index = firstIntermediateIndex; index <= lastIntermediateIndex; index += 1) ranges.push(fullParagraphRange(paragraphs[index]));
  ranges.push(forward ? rangeFromParagraphStartToEnd(endParagraph, end) : rangeFromParagraphStartToEnd(startParagraph, start));
  return ranges.filter((range) => range.toString().trim());
};
const rangeBoundingRect = (range: Range): RangeLayout => {
  const layoutRange = range as Range & { getBoundingClientRect?: () => RangeLayout };
  return layoutRange.getBoundingClientRect?.() ?? { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
};
const rangeHighlights = (range: Range): SelectionHighlight[] => {
  const layoutRange = range as Range & { getClientRects?: () => ArrayLike<RangeLayout> };
  return Array.from(layoutRange.getClientRects?.() ?? [])
  .filter((rect) => rect.width > 0 && rect.height > 0)
  .map((rect) => ({ left: rect.left, top: rect.top, width: rect.width, height: rect.height }));
};
const selectionAnchor = (range: Range): { anchor: { x: number; y: number }; placement: 'above' | 'below' } => {
  const rect = rangeBoundingRect(range);
  const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 390;
  const panelHalfWidth = Math.min(160, Math.max(0, (viewportWidth - 16) / 2));
  const x = Math.min(viewportWidth - panelHalfWidth, Math.max(panelHalfWidth, rect.left + rect.width / 2));
  const placement = rect.top < window.innerHeight * .36 ? 'below' : 'above';
  return { anchor: { x, y: placement === 'below' ? rect.bottom : rect.top }, placement };
};

const fontSizeInPixels = (fontSize: ReaderPreferences['fontSize']): number => ({ small: 15.68, medium: 17.28, large: 19.2, 'x-large': 21.12 })[fontSize];
const lineHeightMultiplier = (lineHeight: ReaderPreferences['lineHeight']): number => ({ compact: 1.62, comfortable: 1.82, relaxed: 2.04 })[lineHeight];
const fallbackPaginationViewport = (): PaginationViewport => ({ contentWidth: 350, contentHeight: 600 });
const pageForReadingProgress = (readingProgress: number, chapterIndex: number, chapterCount: number, pageCount: number): number => {
  if (pageCount <= 1 || chapterCount <= 0) return 0;
  const chapterProgress = Math.max(0, Math.min(0.999_999, readingProgress * chapterCount - chapterIndex));
  return Math.min(pageCount - 1, Math.floor(chapterProgress * pageCount));
};

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
  const [speechOpen, setSpeechOpen] = useState(false);
  const [translationOpen, setTranslationOpen] = useState(false);
  const [chromeVisible, setChromeVisible] = useState(false);
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
  const readerCanvasRef = useRef<HTMLElement>(null);
  const readerPageContentRef = useRef<HTMLDivElement>(null);
  const selectionFrame = useRef<number | undefined>(undefined);
  const selectionPointerDown = useRef(false);
  const mobileSelectionPress = useRef<MobileSelectionPress | undefined>(undefined);
  const mobileSelection = useRef<MobileSelection | undefined>(undefined);
  const mobileSelectionTimer = useRef<number | undefined>(undefined);
  const [selectionHighlights, setSelectionHighlights] = useState<SelectionHighlight[]>([]);
  const touchStartX = useRef<number | undefined>(undefined);
  const touchStartY = useRef<number | undefined>(undefined);
  const touchHandled = useRef(false);
  const chapterEntry = useRef<'start' | 'end'>('start');
  const shouldRestorePagePosition = useRef(true);
  const progressQueue = useRef(Promise.resolve());
  const [paginationViewport, setPaginationViewport] = useState<PaginationViewport>(fallbackPaginationViewport);
  const [paginationSafety, setPaginationSafety] = useState(0.96);
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
    setSelectionHighlights([]);
    setPageIndex(0);
    setSpeechOpen(false);
    setTranslationOpen(false);
  };

  useEffect(() => {
    const nextChapter = Math.min(book.readingChapter, Math.max(0, chapters.length - 1));
    if (progressTimer.current) window.clearTimeout(progressTimer.current);
    shouldRestorePagePosition.current = true;
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
    if (selectionFrame.current) window.cancelAnimationFrame(selectionFrame.current);
    if (mobileSelectionTimer.current) window.clearTimeout(mobileSelectionTimer.current);
    selectionRequestSequence.current += 1;
    chapterRunSequence.current += 1;
    speechRunSequence.current += 1;
    if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel();
  }, []);

  useLayoutEffect(() => {
    const syncPaginationViewport = () => {
      const canvas = readerCanvasRef.current;
      if (!canvas || canvas.clientWidth === 0 || canvas.clientHeight === 0) return;
      const style = window.getComputedStyle(canvas);
      const horizontalPadding = Number.parseFloat(style.paddingLeft) + Number.parseFloat(style.paddingRight);
      const verticalPadding = Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
      if (!Number.isFinite(horizontalPadding) || !Number.isFinite(verticalPadding)) return;
      const next = {
        contentWidth: Math.max(160, Math.floor(canvas.clientWidth - horizontalPadding)),
        contentHeight: Math.max(220, Math.floor(canvas.clientHeight - verticalPadding)),
      };
      setPaginationViewport((current) => current.contentWidth === next.contentWidth && current.contentHeight === next.contentHeight ? current : next);
    };
    syncPaginationViewport();
    const frame = window.requestAnimationFrame(syncPaginationViewport);
    window.addEventListener('resize', syncPaginationViewport);
    const observer = typeof ResizeObserver === 'undefined' ? undefined : new ResizeObserver(syncPaginationViewport);
    if (readerCanvasRef.current) observer?.observe(readerCanvasRef.current);
    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener('resize', syncPaginationViewport);
      observer?.disconnect();
    };
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
    shouldRestorePagePosition.current = false;
    chapterEntry.current = entry;
    setChromeVisible(false);
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

  const showSelectionActions = (paragraph: HTMLParagraphElement, selection = window.getSelection()) => {
    const source = selection?.toString().trim() || '';
    const paragraphId = paragraph.dataset.paragraphId;
    if (!source || !paragraphId) return;
    const fallbackRect = paragraph.getBoundingClientRect();
    const range = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : undefined;
    const rangeRect = range ? rangeBoundingRect(range) : undefined;
    const rect = rangeRect && (rangeRect.width > 0 || rangeRect.height > 0) ? rangeRect : fallbackRect;
    const positioned = range ? selectionAnchor(range) : { anchor: { x: Math.min((window.innerWidth || 390) - 76, Math.max(76, rect.left + rect.width / 2)), y: rect.top }, placement: rect.top < window.innerHeight * .36 ? 'below' as const : 'above' as const };
    selectionRequestSequence.current += 1;
    setSelectionHighlights([]);
    setSelectionAction({ paragraphId, source, targetLanguage: selectionTargetLanguage, ...positioned, loading: false });
  };
  const paragraphForSelection = (selection: Selection | null): HTMLParagraphElement | undefined => {
    const selectionNode = selection?.focusNode ?? selection?.anchorNode;
    const element = selectionNode instanceof Element ? selectionNode : selectionNode?.parentElement;
    const paragraph = element?.closest<HTMLParagraphElement>('p.reader-original[data-paragraph-id]');
    return paragraph && readerCanvasRef.current?.contains(paragraph) ? paragraph : undefined;
  };
  const scheduleSelectionActions = (paragraph?: HTMLParagraphElement) => {
    if (selectionFrame.current) window.cancelAnimationFrame(selectionFrame.current);
    selectionFrame.current = window.requestAnimationFrame(() => {
      selectionFrame.current = undefined;
      const selection = window.getSelection();
      const target = paragraph ?? paragraphForSelection(selection);
      if (target) showSelectionActions(target, selection);
    });
  };
  const handleSelection = (event: ReactPointerEvent<HTMLParagraphElement>) => showSelectionActions(event.currentTarget);
  const handleSelectionContextMenu = (event: MouseEvent<HTMLParagraphElement>) => {
    if (isMobileViewport()) event.preventDefault();
  };
  useEffect(() => {
    const handleSelectionChange = () => {
      if (!selectionPointerDown.current) scheduleSelectionActions();
    };
    document.addEventListener('selectionchange', handleSelectionChange);
    return () => document.removeEventListener('selectionchange', handleSelectionChange);
  }, [selectionTargetLanguage]);
  const dismissSelectionActions = () => { selectionRequestSequence.current += 1; setSelectionHighlights([]); setSelectionAction(undefined); window.getSelection()?.removeAllRanges(); };
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
  const paginationOptions = useMemo(() => {
    const fontSize = fontSizeInPixels(readerPreferences.fontSize);
    const lineHeight = lineHeightMultiplier(readerPreferences.lineHeight);
    const glyphsPerLine = Math.max(9, paginationViewport.contentWidth / fontSize);
    const lineCount = Math.max(7, paginationViewport.contentHeight / (fontSize * lineHeight));
    return {
      blockCapacity: Math.max(120, Math.floor(glyphsPerLine * lineCount * paginationSafety)),
      blockGapWeight: Math.max(9, Math.ceil(glyphsPerLine * (contentMode === 'bilingual' ? 1.08 : 0.75))),
      contentMode,
    };
  }, [contentMode, paginationSafety, paginationViewport, readerPreferences.fontSize, readerPreferences.lineHeight]);
  const pages = useMemo(() => paginateReaderParagraphs(paragraphs, paginationOptions), [paragraphs, paginationOptions]);
  const pageCount = pages.length;
  const currentPage = pages[Math.min(pageIndex, pageCount - 1)] ?? [];
  useEffect(() => {
    setPaginationSafety(0.96);
  }, [readerIdentity, contentMode, paginationViewport.contentHeight, paginationViewport.contentWidth, readerPreferences.fontSize, readerPreferences.lineHeight]);
  useEffect(() => {
    if (chapterEntry.current === 'end') {
      setPageIndex(Math.max(0, pageCount - 1));
      chapterEntry.current = 'start';
      return;
    }
    setPageIndex((current) => Math.min(current, Math.max(0, pageCount - 1)));
  }, [pageCount]);
  useEffect(() => {
    if (!shouldRestorePagePosition.current || chapterIndex !== initialChapter) return;
    setPageIndex(pageForReadingProgress(book.readingProgress, chapterIndex, chapters.length, pageCount));
  }, [book.readingProgress, chapterIndex, chapters.length, initialChapter, pageCount]);

  useLayoutEffect(() => {
    if (readerPreferences.readingMode !== 'paged') return;
    const pageContent = readerPageContentRef.current;
    if (!pageContent || pageContent.scrollHeight <= pageContent.clientHeight + 1) return;
    setPaginationSafety((current) => current <= 0.78 ? current : Number(Math.max(0.78, current * 0.96).toFixed(3)));
  }, [currentPage, pageIndex, paginationSafety, readerPreferences.readingMode]);

  const stopSpeech = () => { speechRunSequence.current += 1; if (typeof window.speechSynthesis !== 'undefined') window.speechSynthesis.cancel(); setSpeechState('idle'); setSpeechParagraphId(undefined); setSpeechParagraphIndex(0); setSpeechError(undefined); };
  const startSpeech = (startIndex = 0, rate = speechRate) => {
    if (!speechSupported || speechParagraphs.length === 0) return;
    const runId = ++speechRunSequence.current;
    const requestIdentity = readerIdentity;
    shouldRestorePagePosition.current = false;
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
    shouldRestorePagePosition.current = false;
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
    shouldRestorePagePosition.current = false;
    setContentMode(mode);
    setPageIndex(0);
    if (mode !== 'original' && !chapterTranslation.running && translatedCount < translationParagraphs.length) void translateChapter();
  };
  const movePage = (direction: -1 | 1) => {
    if (readerPreferences.readingMode === 'scroll') return;
    shouldRestorePagePosition.current = false;
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
    if (!isMobileViewport()) return;
    const target = event.target as Element;
    const paragraph = target.closest<HTMLParagraphElement>('p.reader-original[data-paragraph-id]');
    const touch = event.touches[0];
    if (!paragraph || !touch) return;
    const press: MobileSelectionPress = { paragraph, x: touch.clientX, y: touch.clientY };
    mobileSelectionPress.current = press;
    if (mobileSelectionTimer.current) window.clearTimeout(mobileSelectionTimer.current);
    mobileSelectionTimer.current = window.setTimeout(() => {
      if (mobileSelectionPress.current !== press || !press.paragraph.isConnected) return;
      const start = rangeAtPoint(press.x, press.y);
      if (!start || !press.paragraph.contains(start.startContainer)) return;
      const paragraphId = press.paragraph.dataset.paragraphId;
      if (!paragraphId) return;
      const range = rangeForPointSelection(press.paragraph, start);
      const source = range?.toString().trim() || '';
      if (!range || !source) return;
      const positioned = selectionAnchor(range);
      mobileSelection.current = { paragraphId, startParagraph: press.paragraph, start: range, ranges: [range], source, ...positioned };
      setSelectionHighlights(rangeHighlights(range));
      setChromeVisible(false);
    }, 420);
  };
  const handleReaderTouchMove = (event: TouchEvent<HTMLElement>) => {
    const activeSelection = mobileSelection.current;
    const touch = event.touches[0];
    if (activeSelection && touch) {
      event.preventDefault();
      const endpoint = rangeAtPoint(touch.clientX, touch.clientY);
      const endpointParagraph = endpoint ? originalParagraphForRange(endpoint) : undefined;
      if (!endpoint || !endpointParagraph || !readerCanvasRef.current?.contains(endpointParagraph)) return;
      const endpointRange = rangeForPointSelection(endpointParagraph, endpoint);
      if (!endpointRange) return;
      const ranges = mobileSelectionRanges(readerCanvasRef.current, activeSelection.startParagraph, activeSelection.start, endpointParagraph, endpointRange);
      const source = sourceFromRanges(ranges);
      if (!source) return;
      const positioned = selectionAnchor(endpointRange);
      mobileSelection.current = { ...activeSelection, ranges, source, ...positioned };
      setSelectionHighlights(ranges.flatMap(rangeHighlights));
      return;
    }
    const press = mobileSelectionPress.current;
    if (!press || !touch || Math.hypot(touch.clientX - press.x, touch.clientY - press.y) < 12) return;
    if (mobileSelectionTimer.current) window.clearTimeout(mobileSelectionTimer.current);
    mobileSelectionTimer.current = undefined;
    mobileSelectionPress.current = undefined;
  };
  const handleReaderTouchEnd = (event: TouchEvent<HTMLElement>) => {
    const startX = touchStartX.current;
    const startY = touchStartY.current;
    const activeSelection = mobileSelection.current;
    if (mobileSelectionTimer.current) window.clearTimeout(mobileSelectionTimer.current);
    mobileSelectionTimer.current = undefined;
    mobileSelectionPress.current = undefined;
    mobileSelection.current = undefined;
    touchStartX.current = undefined;
    touchStartY.current = undefined;
    if (activeSelection) {
      touchHandled.current = true;
      window.setTimeout(() => { touchHandled.current = false; }, 240);
      selectionRequestSequence.current += 1;
      setSelectionAction({ paragraphId: activeSelection.paragraphId, source: activeSelection.source, targetLanguage: selectionTargetLanguage, anchor: activeSelection.anchor, placement: activeSelection.placement, loading: false });
      event.preventDefault();
      return;
    }
    if (startX == null || readerPreferences.readingMode !== 'paged') return;
    const distanceX = (event.changedTouches[0]?.clientX ?? startX) - startX;
    const distanceY = startY == null ? 0 : (event.changedTouches[0]?.clientY ?? startY) - startY;
    if (Math.abs(distanceX) < 44 || Math.abs(distanceX) <= Math.abs(distanceY) * 1.15) return;
    touchHandled.current = true;
    window.setTimeout(() => { touchHandled.current = false; }, 240);
    setChromeVisible(false);
    movePage(distanceX > 0 ? -1 : 1);
  };
  const handleReaderTouchCancel = () => {
    if (mobileSelectionTimer.current) window.clearTimeout(mobileSelectionTimer.current);
    mobileSelectionTimer.current = undefined;
    mobileSelectionPress.current = undefined;
    mobileSelection.current = undefined;
    touchStartX.current = undefined;
    touchStartY.current = undefined;
    setSelectionHighlights([]);
  };
  const handleReaderPointerDown = () => { selectionPointerDown.current = true; };
  const handleReaderPointerEnd = () => {
    selectionPointerDown.current = false;
    scheduleSelectionActions();
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
  const handleReaderKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (readerPreferences.readingMode !== 'paged' || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      setChromeVisible(false);
      movePage(-1);
    } else if (event.key === 'ArrowRight' || event.key === ' ') {
      event.preventDefault();
      setChromeVisible(false);
      movePage(1);
    } else if (event.key === 'Escape') {
      setChromeVisible(false);
    }
  };
  const renderBlocks = (blocks: ReaderPageBlock[]) => blocks.map((block) => (
    <div className={`reader-paragraph ${speechParagraphId === block.paragraphId ? 'reader-paragraph--speaking' : ''}`} key={block.id} aria-current={speechParagraphId === block.paragraphId ? 'true' : undefined}>
      {contentMode !== 'translation' && <p className="reader-original" data-paragraph-id={block.paragraphId} onPointerUp={handleSelection} onContextMenu={handleSelectionContextMenu}>{block.original}</p>}
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
      <article className="reader-canvas" ref={readerCanvasRef} aria-label={`${modeLabel}阅读内容`} onClick={handleReaderClick} onKeyDown={handleReaderKeyDown} onPointerDown={handleReaderPointerDown} onPointerUp={handleReaderPointerEnd} onPointerCancel={handleReaderPointerEnd} onTouchStart={handleReaderTouchStart} onTouchMove={handleReaderTouchMove} onTouchEnd={handleReaderTouchEnd} onTouchCancel={handleReaderTouchCancel} tabIndex={0}>
        <h2 id="reader-title" className="sr-only">{book.title}</h2>
        {paragraphs.length === 0 && <p className="reader-empty">这一章还没有可读内容。</p>}
        {readerPreferences.readingMode === 'paged'
          ? <div className={`reader-page-content reader-page-content--${pageDirection > 0 ? 'next' : 'previous'}`} ref={readerPageContentRef} key={`${readerIdentity}:${pageIndex}:${contentMode}`}>{renderBlocks(currentPage)}</div>
          : <div className="reader-scroll-content">{renderBlocks(allBlocks)}</div>}
        <span className="reader-page-indicator" aria-hidden="true">{pageLabel}</span>
      </article>
      {selectionHighlights.length > 0 && <div className="reader-selection-highlights" aria-hidden="true">{selectionHighlights.map((highlight, index) => <span className="reader-selection-highlight" key={`${highlight.left}:${highlight.top}:${index}`} style={{ left: highlight.left, top: highlight.top, width: highlight.width, height: highlight.height }} />)}</div>}
    </div>
    {selectionAction && <SelectionActions source={selectionAction.source} targetLanguage={selectionAction.targetLanguage} globalTargetLanguage={readerPreferences.targetLanguage} targetOverride={selectionTargetOverride} anchor={selectionAction.anchor} placement={selectionAction.placement} translation={selectionAction.translation} loading={selectionAction.loading} error={selectionAction.error} notice={selectionAction.notice} copied={selectionAction.copied} canRead={speechSupported} onTranslate={() => { void translateSelection(); }} onRead={readSelection} onTargetLanguageChange={changeSelectionTargetLanguage} onCopy={() => { void copySelection(); }} onDismiss={dismissSelectionActions} />}
    <div className="reader-dock" aria-label="阅读控制">
      <div className="reader-dock__actions">
        <button type="button" className="reader-dock__action" onClick={() => { setContentsOpen(true); setChromeVisible(true); }} aria-label="打开目录"><List size={19} /></button>
        <button type="button" className="reader-dock__action" onClick={() => { setSpeechOpen(true); setChromeVisible(true); }} aria-label="打开朗读"><Volume2 size={19} /></button>
        <button type="button" className="reader-dock__action" onClick={() => { setTranslationOpen(true); setChromeVisible(true); }} aria-label="打开翻译显示设置"><Languages size={19} /></button>
        <button type="button" className="reader-dock__action" onClick={() => { setSettingsOpen(true); setChromeVisible(true); }} aria-label="打开阅读设置"><Settings2 size={19} /></button>
      </div>
    </div>
    {progressError && <div className="reader-feedback reader-feedback--error reader-progress-error" role="alert">{progressError}</div>}
    {contentsOpen && <ReaderSheet title="目录" onClose={() => setContentsOpen(false)}><nav className="reader-toc" aria-label="章节目录">{chapters.map((item, index) => <button type="button" className={index === chapterIndex ? 'is-active' : ''} key={item.id} onClick={() => { setContentsOpen(false); if (index !== chapterIndex) changeChapter(index); }}><span>{String(index + 1).padStart(2, '0')}</span><strong>{item.title || `第 ${index + 1} 章`}</strong><ChevronRight size={16} /></button>)}</nav></ReaderSheet>}
    {translationOpen && <ReaderSheet title="翻译显示" onClose={() => setTranslationOpen(false)}><ReaderTranslationControls translatedCount={translatedCount} totalCount={translationParagraphs.length} running={chapterTranslation.running} failed={chapterTranslation.failed} contentMode={contentMode} targetLanguage={bookTargetLanguage} globalTargetLanguage={readerPreferences.targetLanguage} targetOverride={bookTargetOverride} onModeChange={changeContentMode} onStop={stopChapterTranslation} onTargetLanguageChange={(language) => { void changeBookTargetLanguage(language); }} />{chapterLanguageNotice && <span className="reader-language-note" role="status" aria-label={chapterLanguageNotice}>{chapterLanguageNotice}</span>}</ReaderSheet>}
    {speechOpen && <ReaderSheet title="朗读" onClose={() => setSpeechOpen(false)}><ReaderSpeechControls supported={speechSupported} state={speechState} contentLabel={modeLabel} currentIndex={speechParagraphIndex} totalCount={speechParagraphs.length} error={speechError} onStart={() => startSpeech()} onPause={pauseSpeech} onResume={resumeSpeech} onStop={stopSpeech} /><ReaderSpeechPreferences supported={speechSupported} voices={speechVoices} sourceLocale={sourceSpeechLocale} targetLocale={targetSpeechLocale} sourceVoiceURI={readerPreferences.sourceVoiceURI} targetVoiceURI={readerPreferences.targetVoiceURI} rate={speechRate} onVoiceChange={changeSpeechVoice} onRateChange={(rate) => updateReaderPreference('speechRate', rate)} onPreview={previewSpeechVoice} /></ReaderSheet>}
    {settingsOpen && <ReaderSheet title="阅读设置" onClose={() => setSettingsOpen(false)}><div className="reader-settings-form"><section><h3>阅读模式</h3><div className="reader-setting-segment"><button type="button" className={readerPreferences.readingMode === 'paged' ? 'is-active' : ''} onClick={() => updateReaderPreference('readingMode', 'paged')}><PanelBottom size={16} /> 分页</button><button type="button" className={readerPreferences.readingMode === 'scroll' ? 'is-active' : ''} onClick={() => updateReaderPreference('readingMode', 'scroll')}><List size={16} /> 滚动</button></div></section><section><h3>字体</h3><div className="reader-setting-segment"><button type="button" className={readerPreferences.fontFamily === 'serif' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontFamily', 'serif')}>衬线</button><button type="button" className={readerPreferences.fontFamily === 'sans' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontFamily', 'sans')}>无衬线</button></div></section><section><h3>字号</h3><div className="reader-setting-segment reader-setting-segment--four"><button type="button" className={readerPreferences.fontSize === 'small' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'small')}>小</button><button type="button" className={readerPreferences.fontSize === 'medium' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'medium')}>中</button><button type="button" className={readerPreferences.fontSize === 'large' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'large')}>大</button><button type="button" className={readerPreferences.fontSize === 'x-large' ? 'is-active' : ''} onClick={() => updateReaderPreference('fontSize', 'x-large')}>特大</button></div></section><section><h3>行距</h3><div className="reader-setting-segment reader-setting-segment--three"><button type="button" className={readerPreferences.lineHeight === 'compact' ? 'is-active' : ''} onClick={() => updateReaderPreference('lineHeight', 'compact')}>紧凑</button><button type="button" className={readerPreferences.lineHeight === 'comfortable' ? 'is-active' : ''} onClick={() => updateReaderPreference('lineHeight', 'comfortable')}>舒适</button><button type="button" className={readerPreferences.lineHeight === 'relaxed' ? 'is-active' : ''} onClick={() => updateReaderPreference('lineHeight', 'relaxed')}>宽松</button></div></section><section><h3>页面主题</h3><div className="reader-setting-segment reader-setting-segment--three"><button type="button" className={readerPreferences.theme === 'paper' ? 'is-active' : ''} onClick={() => updateReaderPreference('theme', 'paper')}><Sun size={15} /> 纸张</button><button type="button" className={readerPreferences.theme === 'sepia' ? 'is-active' : ''} onClick={() => updateReaderPreference('theme', 'sepia')}><BookOpen size={15} /> 柔和</button><button type="button" className={readerPreferences.theme === 'night' ? 'is-active' : ''} onClick={() => updateReaderPreference('theme', 'night')}><Moon size={15} /> 夜间</button></div></section></div></ReaderSheet>}
  </section>;
}
