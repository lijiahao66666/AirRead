import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { Book } from '../../domain/books/book';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import { ReaderPage } from './ReaderPage';
import { buildMinimalEpub } from '../../domain/books/bookFixtures';

const book: Book = {
  id: 'book-1', title: 'A Quiet Book', author: 'AirRead', format: 'txt',
  bytes: new Uint8Array([1]), text: 'The first paragraph.\n\nThe second paragraph.', importedAt: 100,
  readingChapter: 0, readingProgress: 0, generatedBilingual: false,
};

describe('ReaderPage', () => {
  it('renders paragraphs, translates selected text, retries, and saves progress', async () => {
    const translate = vi.fn<TranslationEngine['translate']>()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce('第二段译文');
    const engine = { cacheIdentity: 'test', translate } satisfies TranslationEngine;
    const onProgress = vi.fn();
    render(<ReaderPage book={book} engine={engine} onProgress={onProgress} onBack={vi.fn()} />);

    expect(screen.getByRole('heading', { name: 'A Quiet Book' })).toBeInTheDocument();
    expect(screen.getByText('The first paragraph.')).toBeInTheDocument();
    const selectionTarget = screen.getByText('The second paragraph.');
    fireEvent.mouseUp(selectionTarget);
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    expect(await screen.findByText('offline')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '重试翻译' }));
    expect((await screen.findAllByText('第二段译文')).length).toBeGreaterThan(0);
    fireEvent.change(screen.getByRole('slider', { name: '阅读进度' }), { target: { value: '0.25' } });
    await waitFor(() => expect(onProgress).toHaveBeenCalled());
  });

  it('supports chapter controls and a narrow reader toolbar', () => {
    render(<ReaderPage book={book} engine={{ cacheIdentity: 'test', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect(screen.getAllByRole('button', { name: '返回书架' }).length).toBeGreaterThan(0);
    expect(screen.getAllByRole('button', { name: '上一章' }).length).toBeGreaterThan(0);
    expect(screen.getAllByRole('button', { name: '下一章' }).length).toBeGreaterThan(0);
  });

  it('uses the keyboard to open selection actions and exposes the error message', async () => {
    const engine = { cacheIdentity: 'keyboard', translate: vi.fn().mockRejectedValue(new Error('provider offline')) } satisfies TranslationEngine;
    render(<ReaderPage book={book} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    const paragraph = screen.getByText('The first paragraph.');
    fireEvent.keyDown(paragraph, { key: 'Enter' });
    expect(screen.getByRole('button', { name: '翻译选中文本' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    expect(await screen.findByText('provider offline')).toBeInTheDocument();
  });

  it('does not let a stale translation resolve into a new chapter', async () => {
    let resolveTranslation!: (value: string) => void;
    const engine = { cacheIdentity: 'stale', translate: vi.fn(() => new Promise<string>((resolve) => { resolveTranslation = resolve; })) } satisfies TranslationEngine;
    const epubBook: Book = { ...book, id: 'epub-book', format: 'epub', bytes: buildMinimalEpub(), text: undefined };
    render(<ReaderPage book={epubBook} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    fireEvent.mouseUp(screen.getByText('The first paragraph begins the AirRead test.'));
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    await waitFor(() => expect(engine.translate).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: '下一章' }));
    resolveTranslation('过期译文');
    await waitFor(() => expect(screen.queryByText('过期译文')).not.toBeInTheDocument());
  });

  it('debounces rapid progress changes and shows persistence errors', async () => {
    vi.useFakeTimers();
    const onProgress = vi.fn().mockRejectedValue(new Error('无法保存阅读进度'));
    render(<ReaderPage book={book} engine={{ cacheIdentity: 'progress', translate: vi.fn() }} onProgress={onProgress} onBack={vi.fn()} />);
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
    const view = render(<ReaderPage book={book} engine={{ cacheIdentity: 'reset', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    view.rerender(<ReaderPage book={secondBook} engine={{ cacheIdentity: 'reset', translate: vi.fn() }} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect(screen.getByRole('heading', { name: 'Another Book' })).toBeInTheDocument();
    expect(screen.getByText('A fresh paragraph.')).toBeInTheDocument();
  });

  it('keeps paragraph translations when the parent updates metadata on the same book id', async () => {
    const engine = { cacheIdentity: 'metadata-rerender', translate: vi.fn().mockResolvedValue('保留译文') } satisfies TranslationEngine;
    const view = render(<ReaderPage book={book} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    fireEvent.mouseUp(screen.getByText('The second paragraph.'));
    fireEvent.click(screen.getByRole('button', { name: '翻译选中文本' }));
    expect((await screen.findAllByText('保留译文')).length).toBeGreaterThan(0);
    view.rerender(<ReaderPage book={{ ...book, readingProgress: 0.6, lastReadAt: 900 }} engine={engine} onProgress={vi.fn()} onBack={vi.fn()} />);
    expect((await screen.findAllByText('保留译文')).length).toBeGreaterThan(0);
  });
});
