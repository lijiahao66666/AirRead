import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { Book } from '../../domain/books/book';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import { ReaderPage } from './ReaderPage';
import { buildMinimalEpub } from '../../domain/books/bookFixtures';
import { ReaderPreferencesStore } from './readerPreferences';
import { chaptersForBook } from './readerState';

const book: Book = {
  id: 'book-1', title: 'A Quiet Book', author: 'AirRead', format: 'txt',
  bytes: new Uint8Array([1]), text: 'The first paragraph.\n\nThe second paragraph.', importedAt: 100,
  readingChapter: 0, readingProgress: 0, generatedBilingual: false,
};

const selectNativeText = (startNode: Node, startOffset: number, endNode: Node, endOffset: number) => {
  const selection = window.getSelection();
  const range = document.createRange();
  range.setStart(startNode, startOffset);
  range.setEnd(endNode, endOffset);
  selection?.removeAllRanges();
  selection?.addRange(range);
  fireEvent(document, new Event('selectionchange'));
};
const openTranslationPanel = () => fireEvent.click(screen.getByRole('button', { name: '打开翻译与显示设置' }));
const openReadingSettings = () => fireEvent.click(screen.getByRole('button', { name: '打开阅读设置' }));
const openSpeechPanel = () => fireEvent.click(screen.getByRole('button', { name: '打开朗读' }));
const phraseToken = (text: string, occurrence = 0) => {
  const tokens = screen.getAllByRole('button', { name: `选择词语 ${text}` });
  if (!tokens[occurrence]) throw new Error(`未找到第 ${occurrence + 1} 个词语：${text}`);
  return tokens[occurrence];
};
const startPhraseSelection = () => fireEvent.click(screen.getByRole('button', { name: '开启短语取词' }));
const selectPhrase = (start: string, end: string, startOccurrence = 0, endOccurrence = 0) => {
  fireEvent.click(phraseToken(start, startOccurrence));
  fireEvent.click(phraseToken(end, endOccurrence));
};

describe('ReaderPage', () => {
  afterEach(() => { vi.useRealTimers(); localStorage.clear(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it('translates a phrase selected by its first and last word and supports inline retry', async () => {
    const translate = vi.fn<TranslationEngine['translate']>()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce('第二段译文');
    const engine = { cacheIdentity: 'test', translate } satisfies TranslationEngine;
    const onProgress = vi.fn();
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={onProgress} onBack={vi.fn()} />);

    expect(screen.getByRole('heading', { name: 'A Quiet Book' })).toBeInTheDocument();
    expect(screen.getByText('The first paragraph.')).toBeInTheDocument();
    startPhraseSelection();
    selectPhrase('first', 'paragraph');
    expect(await screen.findByText('offline')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '重试划词翻译' }));
    expect(await screen.findByText('第二段译文')).toBeInTheDocument();
    expect(onProgress).not.toHaveBeenCalled();
  });

  it('keeps one compact set of reader controls', () => {
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'test', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect(screen.getAllByRole('button', { name: '返回书架' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开目录' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开朗读' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开翻译显示设置' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '开启短语取词' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开翻译与显示设置' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开阅读设置' })).toHaveLength(1);
    expect(screen.getByLabelText('阅读控制').querySelectorAll('.reader-dock__action span')).toHaveLength(0);
    expect(screen.queryByRole('slider', { name: '阅读进度' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '上一章' })).not.toBeInTheDocument();
    expect(screen.queryByText('阅读进度')).not.toBeInTheDocument();
  });

  it('keeps chapter translation controls behind the dock translation button', () => {
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'dock-translation', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: '打开翻译显示设置' }));

    expect(screen.getByRole('dialog', { name: '翻译显示' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '生成本章双语' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '生成本章纯译文' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '开始短语取词' })).toBeInTheDocument();
    expect(screen.queryByText('短语取词已开启')).not.toBeInTheDocument();
  });

  it('starts phrase selection from its visible dock action without opening translation controls', () => {
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'translation-shortcut', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: '开启短语取词' }));

    expect(screen.getByText('短语取词已开启')).toBeInTheDocument();
    expect(screen.queryByRole('dialog', { name: '翻译显示' })).not.toBeInTheDocument();
  });

  it('keeps speech voice choices in the dedicated speech panel', () => {
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'voice-location', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    openReadingSettings();
    expect(screen.queryByRole('heading', { name: '朗读声音' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '关闭阅读设置' }));
    openSpeechPanel();
    expect(screen.getByRole('heading', { name: '朗读声音' })).toBeInTheDocument();
  });

  it('does not treat an ordinary paragraph click as translation intent', () => {
    const translate = vi.fn().mockResolvedValue('不应出现');
    const engine = { cacheIdentity: 'ordinary-click', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    const paragraph = screen.getByText('The first paragraph.');
    fireEvent.pointerUp(paragraph, { pointerType: 'mouse' });
    expect(translate).not.toHaveBeenCalled();
    expect(screen.queryByRole('complementary', { name: '选中文本操作' })).not.toBeInTheDocument();
  });

  it('does not use a native mobile selection as a translation trigger', () => {
    vi.useFakeTimers();
    vi.stubGlobal('matchMedia', vi.fn().mockReturnValue({ matches: true }));
    const translate = vi.fn();
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'mobile-context-menu', translate }} onProgress={vi.fn()} onBack={vi.fn()} />);

    const paragraph = screen.getByText('The first paragraph.');
    selectNativeText(paragraph.firstChild!, 4, paragraph.firstChild!, 15);
    act(() => { vi.advanceTimersByTime(800); });
    expect(translate).not.toHaveBeenCalled();
    expect(screen.queryByRole('complementary', { name: '选中文本操作' })).not.toBeInTheDocument();
  });

  it('selects a phrase across visible paragraphs without relying on native selection', async () => {
    const translate = vi.fn().mockResolvedValue('第一段');
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'mobile-drag-selection', translate }} onProgress={vi.fn()} onBack={vi.fn()} />);

    startPhraseSelection();
    selectPhrase('first', 'paragraph', 0, 1);
    await waitFor(() => expect(translate).toHaveBeenCalledWith(expect.objectContaining({ text: 'first paragraph.\n\nThe second paragraph' })));
  });

  it('blocks page turns while the selection panel is open and closes on outside tap', () => {
    const longBook = { ...book, id: 'selection-backdrop-book', text: 'A long reading sentence with enough words. '.repeat(80) };
    const { container } = render(<ReaderPage book={longBook} chapters={chaptersForBook(longBook)} engine={{ cacheIdentity: 'selection-backdrop', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    startPhraseSelection();
    selectPhrase('A', 'long');

    const backdrop = container.querySelector<HTMLElement>('.selection-actions-backdrop');
    expect(backdrop).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '关闭选中文本操作' })).not.toBeInTheDocument();
    fireEvent.click(backdrop!);

    expect(container.querySelector('.selection-actions-backdrop')).not.toBeInTheDocument();
    expect(container.querySelector('.reader-page-content')).toHaveClass('reader-page-content--next');
  });

  it('does not treat a phrase endpoint tap as a page turn', async () => {
    vi.useFakeTimers();
    const longBook = { ...book, id: 'selection-mouse-up-book', text: 'A long reading sentence with enough words. '.repeat(80) };
    const onProgress = vi.fn();
    render(<ReaderPage book={longBook} chapters={chaptersForBook(longBook)} engine={{ cacheIdentity: 'selection-mouse-up', translate: vi.fn() }} onProgress={onProgress} onBack={vi.fn()} />);

    const article = screen.getByRole('article', { name: '原文阅读内容' });
    startPhraseSelection();
    selectPhrase('A', 'long');
    fireEvent.click(article, { clientX: 900 });
    act(() => { vi.advanceTimersByTime(200); });

    expect(onProgress).not.toHaveBeenCalled();
  });

  it('blocks both taps and horizontal swipes from turning pages while phrase selection is active', () => {
    vi.useFakeTimers();
    const longBook = { ...book, id: 'selection-page-lock-book', text: 'A long reading sentence with enough words. '.repeat(80) };
    const onProgress = vi.fn();
    const { container } = render(<ReaderPage book={longBook} chapters={chaptersForBook(longBook)} engine={{ cacheIdentity: 'selection-page-lock', translate: vi.fn() }} onProgress={onProgress} onBack={vi.fn()} />);
    const article = screen.getByRole('article', { name: '原文阅读内容' });

    startPhraseSelection();
    fireEvent.touchStart(article, { touches: [{ clientX: 300, clientY: 200 }] });
    fireEvent.touchEnd(article, { changedTouches: [{ clientX: 20, clientY: 200 }] });
    act(() => { vi.advanceTimersByTime(300); });

    expect(screen.getByText('短语取词已开启')).toBeInTheDocument();
    expect(container.querySelector('.reader-page-content')).toHaveClass('reader-page-content--next');
    expect(onProgress).not.toHaveBeenCalled();
  });

  it('shows the bottom translation card as soon as the phrase endpoint is chosen', () => {
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'native-selection', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    startPhraseSelection();
    fireEvent.click(phraseToken('The'));
    expect(screen.getByText('已选起点')).toBeInTheDocument();
    expect(screen.queryByRole('complementary', { name: '选中文本操作' })).not.toBeInTheDocument();
    fireEvent.click(phraseToken('first'));
    expect(screen.getByRole('complementary', { name: '选中文本操作' })).toBeInTheDocument();
    expect(fireEvent.contextMenu(phraseToken('paragraph'))).toBe(false);
  });

  it('translates the current chapter and lets readers hide or show bilingual text', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.text} · 译文`));
    const engine = { cacheIdentity: 'chapter-mode', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章双语' }));
    expect(await screen.findByText('The first paragraph. · 译文')).toBeInTheDocument();
    expect(await screen.findByText('The second paragraph. · 译文')).toBeInTheDocument();
    expect(translate).toHaveBeenCalledTimes(2);

    fireEvent.click(screen.getByRole('button', { name: '显示本章纯译文' }));
    expect(screen.queryByText('The first paragraph.')).not.toBeInTheDocument();
    expect(screen.getByText('The first paragraph. · 译文')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '切换到原文' }));
    expect(screen.queryByText('The first paragraph. · 译文')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '显示本章双语' }));
    expect(screen.getByText('The first paragraph. · 译文')).toBeInTheDocument();
  });

  it('returns to source text when starting phrase selection from translation-only mode', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.text} · 译文`));
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'phrase-from-translation', translate }} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章纯译文' }));
    expect(await screen.findByText('The first paragraph. · 译文')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '关闭翻译显示' }));
    startPhraseSelection();

    expect(screen.getByRole('button', { name: '选择词语 first' })).toBeInTheDocument();
  });

  it('stops chapter translation without applying late results', async () => {
    const resolvers: Array<(value: string) => void> = [];
    const translate = vi.fn<TranslationEngine['translate']>(() => new Promise<string>((resolve) => { resolvers.push(resolve); }));
    const engine = { cacheIdentity: 'stop-chapter', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章双语' }));
    await waitFor(() => expect(translate).toHaveBeenCalledTimes(2));
    fireEvent.click(screen.getByRole('button', { name: '停止本章翻译' }));
    await act(async () => { resolvers.forEach((resolve) => resolve('不应写入')); });

    expect(screen.queryByText('不应写入')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: '生成本章双语' })).toBeInTheDocument();
  });

  it('makes a fully failed chapter translation retryable', async () => {
    const engine = { cacheIdentity: 'failed-chapter', translate: vi.fn().mockRejectedValue(new Error('offline')) } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章双语' }));
    expect(await screen.findByText('2 段未完成')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '重试未完成段落' })).toBeInTheDocument();
  });

  it('reads the chapter with device speech and supports pause, resume, and stop', async () => {
    class MockSpeechUtterance {
      text: string;
      lang = '';
      rate = 1;
      onend: SpeechSynthesisUtterance['onend'] = null;
      onerror: SpeechSynthesisUtterance['onerror'] = null;

      constructor(text: string) { this.text = text; }
    }
    const speak = vi.fn();
    const pause = vi.fn();
    const resume = vi.fn();
    const cancel = vi.fn();
    vi.stubGlobal('SpeechSynthesisUtterance', MockSpeechUtterance);
    vi.stubGlobal('speechSynthesis', { speak, pause, resume, cancel });
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'speech', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    openSpeechPanel();
    fireEvent.click(screen.getByRole('button', { name: '朗读本章' }));
    expect(speak).toHaveBeenCalledTimes(1);
    expect((speak.mock.calls[0][0] as MockSpeechUtterance).text).toBe('The first paragraph.');
    expect(screen.getByText('正在朗读 · 原文 1/2')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '暂停朗读' }));
    expect(pause).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole('button', { name: '继续朗读' }));
    expect(resume).toHaveBeenCalledTimes(1);

    const firstUtterance = speak.mock.calls[0][0] as MockSpeechUtterance;
    act(() => { firstUtterance.onend?.call(firstUtterance as unknown as SpeechSynthesisUtterance, new Event('end') as SpeechSynthesisEvent); });
    expect(speak).toHaveBeenCalledTimes(2);
    expect(screen.getByText('正在朗读 · 原文 2/2')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '停止朗读' }));
    expect(cancel).toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '朗读本章' })).toBeInTheDocument();
  });

  it('reads translated text while pure translation mode is active', async () => {
    class MockSpeechUtterance {
      text: string;
      lang = '';
      rate = 1;
      onend: SpeechSynthesisUtterance['onend'] = null;
      onerror: SpeechSynthesisUtterance['onerror'] = null;

      constructor(text: string) { this.text = text; }
    }
    const speak = vi.fn();
    vi.stubGlobal('SpeechSynthesisUtterance', MockSpeechUtterance);
    vi.stubGlobal('speechSynthesis', { speak, pause: vi.fn(), resume: vi.fn(), cancel: vi.fn() });
    const engine = { cacheIdentity: 'translated-speech', translate: vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`译文：${request.text}`)) } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章纯译文' }));
    expect(await screen.findByText('译文：The first paragraph.')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '关闭翻译显示' }));
    openSpeechPanel();
    fireEvent.click(screen.getByRole('button', { name: '朗读本章译文' }));

    expect((speak.mock.calls[0][0] as MockSpeechUtterance).text).toBe('译文：The first paragraph.');
  });

  it('alternates source and translated text while bilingual mode is active', async () => {
    class MockSpeechUtterance {
      text: string;
      lang = '';
      rate = 1;
      onend: SpeechSynthesisUtterance['onend'] = null;
      onerror: SpeechSynthesisUtterance['onerror'] = null;

      constructor(text: string) { this.text = text; }
    }
    const speak = vi.fn();
    vi.stubGlobal('SpeechSynthesisUtterance', MockSpeechUtterance);
    vi.stubGlobal('speechSynthesis', { speak, pause: vi.fn(), resume: vi.fn(), cancel: vi.fn() });
    const engine = { cacheIdentity: 'bilingual-speech', translate: vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`译文：${request.text}`)) } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章双语' }));
    expect(await screen.findByText('译文：The first paragraph.')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '关闭翻译显示' }));
    openSpeechPanel();
    fireEvent.click(screen.getByRole('button', { name: '朗读本章双语' }));
    const firstUtterance = speak.mock.calls[0][0] as MockSpeechUtterance;
    expect(firstUtterance.text).toBe('The first paragraph.');

    act(() => { firstUtterance.onend?.call(firstUtterance as unknown as SpeechSynthesisUtterance, new Event('end') as SpeechSynthesisEvent); });
    expect((speak.mock.calls[1][0] as MockSpeechUtterance).text).toBe('译文：The first paragraph.');
  });

  it('uses a target-language voice for translated speech', async () => {
    localStorage.setItem('airread.readerPreferences.v1', JSON.stringify({ sourceLanguage: 'en', targetLanguage: 'zh-CN', sourceVoiceURI: 'english-voice', targetVoiceURI: 'chinese-voice', speechRate: 1 }));
    class MockSpeechUtterance {
      text: string;
      lang = '';
      rate = 1;
      voice: SpeechSynthesisVoice | null = null;
      onend: SpeechSynthesisUtterance['onend'] = null;
      onerror: SpeechSynthesisUtterance['onerror'] = null;

      constructor(text: string) { this.text = text; }
    }
    const speak = vi.fn();
    const englishVoice = { name: 'English', lang: 'en-US', voiceURI: 'english-voice', default: true, localService: true } as SpeechSynthesisVoice;
    const chineseVoice = { name: '中文', lang: 'zh-CN', voiceURI: 'chinese-voice', default: true, localService: true } as SpeechSynthesisVoice;
    vi.stubGlobal('SpeechSynthesisUtterance', MockSpeechUtterance);
    vi.stubGlobal('speechSynthesis', { speak, pause: vi.fn(), resume: vi.fn(), cancel: vi.fn(), getVoices: () => [englishVoice, chineseVoice] });
    const engine = { cacheIdentity: 'translated-voice', translate: vi.fn().mockResolvedValue('第一段译文。') } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章纯译文' }));
    expect(await screen.findAllByText('第一段译文。')).toHaveLength(2);
    fireEvent.click(screen.getByRole('button', { name: '关闭翻译显示' }));
    openSpeechPanel();
    fireEvent.click(screen.getByRole('button', { name: '朗读本章译文' }));

    expect((speak.mock.calls[0][0] as MockSpeechUtterance).voice).toBe(chineseVoice);
    expect((speak.mock.calls[0][0] as MockSpeechUtterance).lang).toBe('zh-CN');
  });

  it('lets readers choose and persist separate source and target voices', () => {
    class MockSpeechUtterance {
      text: string;
      lang = '';
      rate = 1;
      voice: SpeechSynthesisVoice | null = null;

      constructor(text: string) { this.text = text; }
    }
    const englishVoice = { name: 'English Natural', lang: 'en-US', voiceURI: 'english-natural', default: true, localService: true } as SpeechSynthesisVoice;
    const chineseVoice = { name: '中文自然声', lang: 'zh-CN', voiceURI: 'chinese-natural', default: true, localService: true } as SpeechSynthesisVoice;
    const japaneseVoice = { name: '日本語', lang: 'ja-JP', voiceURI: 'japanese', default: true, localService: true } as SpeechSynthesisVoice;
    vi.stubGlobal('SpeechSynthesisUtterance', MockSpeechUtterance);
    vi.stubGlobal('speechSynthesis', { speak: vi.fn(), pause: vi.fn(), resume: vi.fn(), cancel: vi.fn(), getVoices: () => [englishVoice, chineseVoice, japaneseVoice] });
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'voice-settings', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    openSpeechPanel();
    expect(screen.getByLabelText('原文音色')).toHaveTextContent('English Natural');
    expect(screen.getByLabelText('原文音色')).not.toHaveTextContent('日本語');
    expect(screen.getByLabelText('译文音色')).toHaveTextContent('中文自然声');
    fireEvent.change(screen.getByLabelText('原文音色'), { target: { value: 'english-natural' } });
    fireEvent.change(screen.getByLabelText('译文音色'), { target: { value: 'chinese-natural' } });

    expect(new ReaderPreferencesStore(localStorage).get()).toMatchObject({ sourceVoiceURI: 'english-natural', targetVoiceURI: 'chinese-natural' });
  });

  it('turns paged content with a horizontal swipe and hides reading chrome', () => {
    const longBook = { ...book, id: 'swipe-book', text: 'A long reading sentence with enough words. '.repeat(80) };
    const { container } = render(<ReaderPage book={longBook} chapters={chaptersForBook(longBook)} engine={{ cacheIdentity: 'swipe', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    const article = screen.getByRole('article', { name: '原文阅读内容' });

    fireEvent.touchStart(article, { touches: [{ clientX: 300 }] });
    fireEvent.touchEnd(article, { changedTouches: [{ clientX: 20 }] });

    expect(container.querySelector('.reader-page')).not.toHaveClass('reader-page--chrome-visible');
    expect(container.querySelector('.reader-page-content')).toHaveClass('reader-page-content--next');
  });

  it('keeps reader controls hidden when a page turn enters the next chapter', () => {
    const chapterBook = {
      ...book,
      id: 'chapter-turn-book',
      text: '第一章 开始\nFirst chapter text.\n\n第二章 继续\nSecond chapter text.',
    };
    const { container } = render(<ReaderPage book={chapterBook} chapters={chaptersForBook(chapterBook)} engine={{ cacheIdentity: 'chapter-turn', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    const article = screen.getByRole('article', { name: '原文阅读内容' });
    vi.spyOn(article, 'getBoundingClientRect').mockReturnValue({ left: 0, width: 100 } as DOMRect);

    fireEvent.click(article, { clientX: 50 });
    expect(container.querySelector('.reader-page')).toHaveClass('reader-page--chrome-visible');
    fireEvent.click(article, { clientX: 90 });

    expect(screen.getByText('Second chapter text.')).toBeInTheDocument();
    expect(container.querySelector('.reader-page')).not.toHaveClass('reader-page--chrome-visible');
  });

  it('uses the saved translation direction and selected speech voice', async () => {
    localStorage.setItem('airread.readerPreferences.v1', JSON.stringify({ sourceLanguage: 'ja', targetLanguage: 'en', sourceVoiceURI: 'ja-enhanced', speechRate: 1 }));
    const translate = vi.fn().mockResolvedValue('English translation');
    const speak = vi.fn();
    const voice = { name: 'Japanese Enhanced', lang: 'ja-JP', voiceURI: 'ja-enhanced', default: false, localService: true } as SpeechSynthesisVoice;
    class MockSpeechUtterance {
      text: string;
      lang = '';
      rate = 1;
      voice: SpeechSynthesisVoice | null = null;
      onend: SpeechSynthesisUtterance['onend'] = null;
      onerror: SpeechSynthesisUtterance['onerror'] = null;

      constructor(text: string) { this.text = text; }
    }
    vi.stubGlobal('SpeechSynthesisUtterance', MockSpeechUtterance);
    vi.stubGlobal('speechSynthesis', { speak, pause: vi.fn(), resume: vi.fn(), cancel: vi.fn(), getVoices: () => [voice] });
    const engine = { cacheIdentity: 'preferences', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    startPhraseSelection();
    selectPhrase('The', 'paragraph');
    await waitFor(() => expect(translate).toHaveBeenCalledWith({ text: 'The first paragraph', sourceLanguage: 'ja', targetLanguage: 'en' }));
    openSpeechPanel();
    fireEvent.click(screen.getByRole('button', { name: '朗读本章' }));
    expect((speak.mock.calls[0][0] as MockSpeechUtterance).voice).toBe(voice);
    expect((speak.mock.calls[0][0] as MockSpeechUtterance).lang).toBe('ja-JP');
  });

  it('does not request translation when the chapter already matches the target language', async () => {
    const chineseBook: Book = { ...book, id: 'chinese-book', title: '中文书', text: '这是第一段中文。\n\n这是第二段中文。' };
    const translate = vi.fn().mockResolvedValue('不应请求');
    const engine = { cacheIdentity: 'same-language', translate } satisfies TranslationEngine;
    render(<ReaderPage book={chineseBook} chapters={chaptersForBook(chineseBook)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    openTranslationPanel();
    expect(screen.getByRole('status', { name: '当前内容已是简体中文，无需翻译' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '生成本章双语' })).toBeDisabled();
    startPhraseSelection();
    selectPhrase('这', '中');
    expect(await screen.findByText('原文已经是简体中文，无需翻译')).toBeInTheDocument();
    expect(translate).not.toHaveBeenCalled();
  });

  it('lets the reader override the target language for this book and persists it', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.targetLanguage} translation`));
    const onTranslationPreferencesChange = vi.fn().mockResolvedValue(undefined);
    const engine = { cacheIdentity: 'book-target', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onTranslationPreferencesChange={onTranslationPreferencesChange} onBack={vi.fn()} />);

    openTranslationPanel();
    const targetSelect = screen.getByLabelText('本书翻译目标语言');
    expect(targetSelect).toHaveValue('');
    fireEvent.change(targetSelect, { target: { value: 'ja' } });
    expect(targetSelect).toHaveValue('ja');
    expect(onTranslationPreferencesChange).toHaveBeenCalledWith({ targetLanguage: 'ja' });

    fireEvent.click(screen.getByRole('button', { name: '生成本章双语' }));
    await waitFor(() => expect(screen.getAllByText('ja translation')).toHaveLength(2));
    expect(translate).toHaveBeenCalledWith(expect.objectContaining({ targetLanguage: 'ja' }));
  });

  it('persists a target language chosen from the selection language list', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.targetLanguage} selection`));
    const onTranslationPreferencesChange = vi.fn().mockResolvedValue(undefined);
    const onSelectionPreferencesChange = vi.fn().mockResolvedValue(undefined);
    const engine = { cacheIdentity: 'selection-target', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onTranslationPreferencesChange={onTranslationPreferencesChange} onSelectionPreferencesChange={onSelectionPreferencesChange} onBack={vi.fn()} />);

    startPhraseSelection();
    selectPhrase('The', 'paragraph');
    fireEvent.click(screen.getByRole('button', { name: '选择短语翻译目标语言，当前简体中文' }));
    expect(screen.getByRole('dialog', { name: '短语翻译目标语言' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('option', { name: '日语' }));
    expect(onSelectionPreferencesChange).toHaveBeenCalledWith({ targetLanguage: 'ja' });
    expect(onTranslationPreferencesChange).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '选择短语翻译目标语言，当前日语' })).toBeInTheDocument();
    expect(await screen.findByText('ja selection')).toBeInTheDocument();
    expect(translate).toHaveBeenLastCalledWith(expect.objectContaining({ targetLanguage: 'ja' }));
  });

  it('keeps the selection target independent from the book target', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.targetLanguage} selection`));
    const bookWithJapaneseTarget: Book = { ...book, id: 'independent-targets', translationPreferences: { targetLanguage: 'ja' } };
    const engine = { cacheIdentity: 'independent-targets', translate } satisfies TranslationEngine;
    render(<ReaderPage book={bookWithJapaneseTarget} chapters={chaptersForBook(bookWithJapaneseTarget)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    startPhraseSelection();
    selectPhrase('The', 'paragraph');
    expect(screen.getByRole('button', { name: '选择短语翻译目标语言，当前简体中文' })).toBeInTheDocument();
    expect(await screen.findByText('zh-CN selection')).toBeInTheDocument();
    expect(translate).toHaveBeenCalledWith(expect.objectContaining({ targetLanguage: 'zh-CN' }));
  });

  it('does not let a stale translation resolve into a new chapter', async () => {
    let resolveTranslation!: (value: string) => void;
    const engine = { cacheIdentity: 'stale', translate: vi.fn(() => new Promise<string>((resolve) => { resolveTranslation = resolve; })) } satisfies TranslationEngine;
    const epubBook: Book = { ...book, id: 'epub-book', format: 'epub', bytes: buildMinimalEpub(), text: undefined };
    render(<ReaderPage book={epubBook} chapters={chaptersForBook(epubBook)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    startPhraseSelection();
    selectPhrase('The', 'test');
    await waitFor(() => expect(engine.translate).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: '打开目录' }));
    fireEvent.click(screen.getByRole('button', { name: /Chapter Two/ }));
    resolveTranslation('过期译文');
    await waitFor(() => expect(screen.queryByText('过期译文')).not.toBeInTheDocument());
  });

  it('persists page-turn progress and shows persistence errors', async () => {
    vi.useFakeTimers();
    const onProgress = vi.fn().mockRejectedValue(new Error('无法保存阅读进度'));
    const longBook = { ...book, id: 'progress-book', text: 'A long reading sentence with enough words. '.repeat(80) };
    render(<ReaderPage book={longBook} chapters={chaptersForBook(longBook)} engine={{ cacheIdentity: 'progress', translate: vi.fn() }} onProgress={onProgress} onBack={vi.fn()} />);
    onProgress.mockClear();
    const article = screen.getByRole('article', { name: '原文阅读内容' });
    vi.spyOn(article, 'getBoundingClientRect').mockReturnValue({ left: 0, width: 100 } as DOMRect);
    fireEvent.click(article, { clientX: 90 });
    vi.advanceTimersByTime(200);
    await vi.runOnlyPendingTimersAsync();
    expect(onProgress).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
    expect(await screen.findByText('无法保存阅读进度')).toBeInTheDocument();
  });

  it('restores the saved page within the current chapter', async () => {
    const resumedBook = {
      ...book,
      id: 'resume-page',
      text: Array.from({ length: 70 }, (_, index) => `Paragraph ${index + 1}. ${'A quiet sentence for pagination. '.repeat(5)}`).join('\n\n'),
      readingProgress: 0.5,
    };
    const { container } = render(<ReaderPage book={resumedBook} chapters={chaptersForBook(resumedBook)} engine={{ cacheIdentity: 'resume-page', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);

    await waitFor(() => {
      const indicator = container.querySelector('.reader-page-indicator');
      const currentPage = Number(indicator?.textContent?.split('/')[0].trim());
      expect(currentPage).toBeGreaterThan(1);
    });
  });

  it('resets chapter state when the book identity changes', () => {
    const secondBook = { ...book, id: 'book-2', title: 'Another Book', text: 'A fresh paragraph.' };
    const view = render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'reset', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    view.rerender(<ReaderPage book={secondBook} chapters={chaptersForBook(secondBook)} engine={{ cacheIdentity: 'reset', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect(screen.getByRole('heading', { name: 'Another Book' })).toBeInTheDocument();
    expect(screen.getByText('A fresh paragraph.')).toBeInTheDocument();
  });

  it('keeps paragraph translations when the parent updates metadata on the same book id', async () => {
    const engine = { cacheIdentity: 'metadata-rerender', translate: vi.fn().mockResolvedValue('保留译文') } satisfies TranslationEngine;
    const view = render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    openTranslationPanel();
    fireEvent.click(screen.getByRole('button', { name: '生成本章双语' }));
    await waitFor(() => expect(screen.getAllByText('保留译文')).toHaveLength(2));
    view.rerender(<ReaderPage book={{ ...book, readingProgress: 0.6, lastReadAt: 900 }} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect(screen.getAllByText('保留译文')).toHaveLength(2);
  });
});
