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

const mockSelection = (text: string) => vi.spyOn(window, 'getSelection').mockReturnValue({
  toString: () => text,
  removeAllRanges: vi.fn(),
} as unknown as Selection);
const openTranslationPanel = () => fireEvent.click(screen.getByRole('button', { name: '打开翻译与朗读' }));

describe('ReaderPage', () => {
  afterEach(() => { localStorage.clear(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it('shows selection actions, translates on demand, retries inline, and saves progress', async () => {
    const translate = vi.fn<TranslationEngine['translate']>()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce('第二段译文');
    const engine = { cacheIdentity: 'test', translate } satisfies TranslationEngine;
    const onProgress = vi.fn();
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={onProgress} onBack={vi.fn()} />);

    expect(screen.getByRole('heading', { name: 'A Quiet Book' })).toBeInTheDocument();
    expect(screen.getByText('The first paragraph.')).toBeInTheDocument();
    const selectionTarget = screen.getByText('The second paragraph.');
    mockSelection('The second paragraph.');
    fireEvent.mouseUp(selectionTarget);
    expect(screen.getByRole('button', { name: '翻译选中文本' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    expect(await screen.findByText('offline')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '重试划词翻译' }));
    expect(await screen.findByText('第二段译文')).toBeInTheDocument();
    fireEvent.change(screen.getByRole('slider', { name: '阅读进度' }), { target: { value: '0.25' } });
    await waitFor(() => expect(onProgress).toHaveBeenCalled());
  });

  it('keeps one compact set of reader controls', () => {
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'test', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect(screen.getAllByRole('button', { name: '返回书架' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开目录' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '打开排版与主题' })).toHaveLength(1);
    expect(screen.queryByRole('button', { name: '上一章' })).not.toBeInTheDocument();
  });

  it('does not treat an ordinary paragraph click as translation intent', () => {
    const translate = vi.fn().mockResolvedValue('不应出现');
    const engine = { cacheIdentity: 'ordinary-click', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    mockSelection('');
    const paragraph = screen.getByText('The first paragraph.');
    fireEvent.mouseUp(paragraph);
    expect(translate).not.toHaveBeenCalled();
    expect(screen.queryByRole('complementary', { name: '划词翻译' })).not.toBeInTheDocument();
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

    openTranslationPanel();
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

    expect(screen.getByRole('button', { name: '上一页' })).toBeDisabled();
    fireEvent.touchStart(article, { touches: [{ clientX: 300 }] });
    fireEvent.touchEnd(article, { changedTouches: [{ clientX: 20 }] });

    expect(screen.getByRole('button', { name: '上一页' })).not.toBeDisabled();
    expect(container.querySelector('.reader-page')).not.toHaveClass('reader-page--chrome-visible');
    expect(container.querySelector('.reader-page-content')).toHaveClass('reader-page-content--next');
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

    mockSelection('The first paragraph.');
    fireEvent.mouseUp(screen.getByText('The first paragraph.'));
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    await waitFor(() => expect(translate).toHaveBeenCalledWith({ text: 'The first paragraph.', sourceLanguage: 'ja', targetLanguage: 'en' }));
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
    mockSelection('这是第一段中文。');
    fireEvent.mouseUp(screen.getByText('这是第一段中文。'));
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
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

  it('persists a target language chosen from the selection panel', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.targetLanguage} selection`));
    const onTranslationPreferencesChange = vi.fn().mockResolvedValue(undefined);
    const onSelectionPreferencesChange = vi.fn().mockResolvedValue(undefined);
    const engine = { cacheIdentity: 'selection-target', translate } satisfies TranslationEngine;
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={engine} onProgress={vi.fn()} onTranslationPreferencesChange={onTranslationPreferencesChange} onSelectionPreferencesChange={onSelectionPreferencesChange} onBack={vi.fn()} />);

    mockSelection('The first paragraph.');
    fireEvent.mouseUp(screen.getByText('The first paragraph.'));
    fireEvent.change(screen.getByLabelText('划词翻译目标语言'), { target: { value: 'ja' } });
    expect(onSelectionPreferencesChange).toHaveBeenCalledWith({ targetLanguage: 'ja' });
    expect(onTranslationPreferencesChange).not.toHaveBeenCalled();
    expect(screen.getByLabelText('划词翻译目标语言')).toHaveValue('ja');
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    expect(await screen.findByText('ja selection')).toBeInTheDocument();
    expect(translate).toHaveBeenCalledWith(expect.objectContaining({ targetLanguage: 'ja' }));
  });

  it('keeps the selection target independent from the book target', async () => {
    const translate = vi.fn<TranslationEngine['translate']>((request) => Promise.resolve(`${request.targetLanguage} selection`));
    const bookWithJapaneseTarget: Book = { ...book, id: 'independent-targets', translationPreferences: { targetLanguage: 'ja' } };
    const engine = { cacheIdentity: 'independent-targets', translate } satisfies TranslationEngine;
    render(<ReaderPage book={bookWithJapaneseTarget} chapters={chaptersForBook(bookWithJapaneseTarget)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);

    mockSelection('The first paragraph.');
    fireEvent.mouseUp(screen.getByText('The first paragraph.'));
    expect(screen.getByLabelText('划词翻译目标语言')).toHaveValue('');
    expect(screen.getByLabelText('划词翻译目标语言').textContent).toContain('跟随全局（简体中文）');
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    expect(await screen.findByText('zh-CN selection')).toBeInTheDocument();
    expect(translate).toHaveBeenCalledWith(expect.objectContaining({ targetLanguage: 'zh-CN' }));
  });

  it('does not let a stale translation resolve into a new chapter', async () => {
    let resolveTranslation!: (value: string) => void;
    const engine = { cacheIdentity: 'stale', translate: vi.fn(() => new Promise<string>((resolve) => { resolveTranslation = resolve; })) } satisfies TranslationEngine;
    const epubBook: Book = { ...book, id: 'epub-book', format: 'epub', bytes: buildMinimalEpub(), text: undefined };
    render(<ReaderPage book={epubBook} chapters={chaptersForBook(epubBook)} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    mockSelection('The first paragraph begins the AirRead test.');
    fireEvent.mouseUp(screen.getByText('The first paragraph begins the AirRead test.'));
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    await waitFor(() => expect(engine.translate).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: '打开目录' }));
    fireEvent.click(screen.getByRole('button', { name: /Chapter Two/ }));
    resolveTranslation('过期译文');
    await waitFor(() => expect(screen.queryByText('过期译文')).not.toBeInTheDocument());
  });

  it('debounces rapid progress changes and shows persistence errors', async () => {
    vi.useFakeTimers();
    const onProgress = vi.fn().mockRejectedValue(new Error('无法保存阅读进度'));
    render(<ReaderPage book={book} chapters={chaptersForBook(book)} engine={{ cacheIdentity: 'progress', translate: vi.fn() }} onProgress={onProgress} onBack={vi.fn()} />);
    onProgress.mockClear();
    const slider = screen.getByRole('slider', { name: '阅读进度' });
    fireEvent.change(slider, { target: { value: '0.2' } });
    fireEvent.change(slider, { target: { value: '0.4' } });
    fireEvent.change(slider, { target: { value: '0.6' } });
    vi.advanceTimersByTime(200);
    await vi.runOnlyPendingTimersAsync();
    expect(onProgress).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
    expect(await screen.findByText('无法保存阅读进度')).toBeInTheDocument();
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
