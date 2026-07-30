import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { strFromU8, unzipSync } from 'fflate';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { BUILT_IN_FREE_PROFILE } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import type { TranslationEngine } from '../../domain/ai/translationTypes';
import type { Book } from '../../domain/books/book';
import { buildMinimalEpub } from '../../domain/books/bookFixtures';
import { BookStudioPage } from './BookStudioPage';

const epubBook: Book = {
  id: 'studio-book', title: 'AirRead Test Book', author: 'AirRead', format: 'epub',
  bytes: buildMinimalEpub(), importedAt: 1, readingChapter: 0, readingProgress: 0,
  generatedBilingual: false,
};

const openBilingualTool = () => fireEvent.click(screen.getByRole('button', { name: '开始制作双语书' }));

describe('BookStudioPage', () => {
  beforeEach(() => localStorage.clear());

  it('shows all five stages and inspects an existing EPUB before translation settings', () => {
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} onSaveBook={vi.fn()} />);

    expect(screen.getByRole('heading', { name: '书籍工作室' })).toBeInTheDocument();
    expect(screen.getByText('制作自己的双语书，或导入可阅读的公版作品。')).toBeInTheDocument();
    expect(screen.getByText('开放作品导入')).toBeInTheDocument();
    expect(screen.queryByText('TXT 转 EPUB')).not.toBeInTheDocument();
    expect(screen.queryByText('EPUB 格式整理')).not.toBeInTheDocument();
    expect(screen.queryByText('选择书籍')).not.toBeInTheDocument();
    openBilingualTool();
    for (const step of ['选择书籍', '检查内容', '翻译设置', '制作进度', '完成']) {
      expect(screen.getByText(step)).toBeInTheDocument();
    }
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    expect(screen.getByRole('heading', { name: '检查书籍内容' })).toBeInTheDocument();
    expect(screen.getByText('AirRead Test Book')).toBeInTheDocument();
    expect(screen.getByText('AirRead')).toBeInTheDocument();
    expect(screen.getByText('2 个章节')).toBeInTheDocument();
    expect(screen.getByText(/可翻译字符/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    expect(screen.getByLabelText('源语言')).toHaveValue('auto');
    expect(screen.getByLabelText('目标语言')).toHaveValue('zh-CN');
    expect(screen.getByLabelText('翻译服务')).toHaveValue(BUILT_IN_FREE_PROFILE.id);
    expect(screen.getByLabelText('术语表')).toBeInTheDocument();
    expect(screen.getByRole('checkbox', { name: '输出双语对照' })).toBeChecked();
  });

  it('opens the Project Gutenberg import flow instead of a catalog page', () => {
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} onSaveBook={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: '搜索并导入' }));

    expect(screen.getByRole('heading', { name: '搜索并导入作品' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: '搜索开放作品' })).toBeInTheDocument();
    expect(screen.getByText('Project Gutenberg · 英文公版 EPUB')).toBeInTheDocument();
    expect(screen.queryByText('制作进度')).not.toBeInTheDocument();
  });

  it('pauses after the active paragraph and resumes the separate batch queue', async () => {
    let resolveFirst!: (value: string) => void;
    const translate = vi.fn()
      .mockImplementationOnce(() => new Promise<string>((resolve) => { resolveFirst = resolve; }))
      .mockImplementation(async ({ text }: { text: string }) => `译：${text}`);
    const engine: TranslationEngine = { cacheIdentity: 'studio-test', translate };
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} onSaveBook={vi.fn()} />);

    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));
    await waitFor(() => expect(translate).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole('button', { name: '暂停制作' }));
    resolveFirst('译：Chapter One');
    await waitFor(() => expect(screen.getByText('已暂停')).toBeInTheDocument());
    expect(translate).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: '继续制作' }));
    await waitFor(() => expect(screen.getByRole('heading', { name: '双语书制作完成' })).toBeInTheDocument());
    expect(translate).toHaveBeenCalledTimes(4);
  });

  it('retries failed paragraphs, exports the EPUB, and saves a generated bilingual book', async () => {
    const translate = vi.fn()
      .mockResolvedValueOnce('译文 1')
      .mockRejectedValueOnce(new Error('provider-secret-body'))
      .mockResolvedValueOnce('译文 3')
      .mockResolvedValueOnce('译文 4')
      .mockResolvedValueOnce('译文 2');
    const engine: TranslationEngine = { cacheIdentity: 'studio-test', translate };
    const onSaveBook = vi.fn();
    const onDownload = vi.fn();
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} onSaveBook={onSaveBook} onDownload={onDownload} />);

    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.change(screen.getByLabelText('术语表'), { target: { value: 'AirRead=灵阅' } });
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));

    await waitFor(() => expect(screen.getByText('1 段翻译失败')).toBeInTheDocument());
    expect(document.body.textContent).not.toContain('provider-secret-body');
    fireEvent.click(screen.getByRole('button', { name: '重试失败段落' }));
    await waitFor(() => expect(screen.getByRole('heading', { name: '双语书制作完成' })).toBeInTheDocument());
    expect(onSaveBook).toHaveBeenCalledTimes(1);
    const generated = onSaveBook.mock.calls[0][0] as Book;
    expect(generated.generatedBilingual).toBe(true);
    expect(generated.id).not.toBe(epubBook.id);
    const entries = unzipSync(generated.bytes);
    expect(strFromU8(entries['OEBPS/chapter1.xhtml'])).toContain('译文 1');
    expect(strFromU8(entries['OEBPS/chapter1.xhtml'])).toContain('译文 2');
    expect(strFromU8(entries['OEBPS/content.opf'])).not.toContain('provider-secret-body');

    fireEvent.click(screen.getByRole('button', { name: '下载双语 EPUB' }));
    expect(onDownload).toHaveBeenCalledWith(expect.any(Blob), 'AirRead Test Book-双语版.epub');
  });

  it('cancels a running batch without affecting the reader queue', async () => {
    let resolveFirst!: (value: string) => void;
    const engine: TranslationEngine = {
      cacheIdentity: 'studio-test',
      translate: vi.fn(() => new Promise<string>((resolve) => { resolveFirst = resolve; })),
    };
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} onSaveBook={vi.fn()} />);
    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));
    await waitFor(() => expect(engine.translate).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole('button', { name: '取消制作' }));
    resolveFirst('不会导出的译文');
    await waitFor(() => expect(screen.getByText('制作已取消')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: '重新开始' })).toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: '制作进度' })).not.toBeInTheDocument();
  });

  it('does not start a concurrent retry while the original batch is still translating', async () => {
    let resolveSecond!: (value: string) => void;
    const translate = vi.fn()
      .mockRejectedValueOnce(new Error('temporary failure'))
      .mockImplementationOnce(() => new Promise<string>((resolve) => { resolveSecond = resolve; }))
      .mockResolvedValue('later translation');
    const engine: TranslationEngine = { cacheIdentity: 'studio-concurrency', translate };
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} onSaveBook={vi.fn()} />);

    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));
    await waitFor(() => expect(translate).toHaveBeenCalledTimes(2));
    const retry = screen.getByRole('button', { name: '重试失败段落' });
    expect(retry).toBeDisabled();
    fireEvent.click(retry);
    expect(translate).toHaveBeenCalledTimes(2);

    resolveSecond('第二段完成');
    await waitFor(() => expect(screen.getByRole('button', { name: '重试失败段落' })).not.toBeDisabled());
  });

  it('does not save or complete when cancellation arrives during export finalization', async () => {
    let resolveBytes!: (bytes: Uint8Array) => void;
    const engine: TranslationEngine = { cacheIdentity: 'studio-cancel-export', translate: vi.fn().mockResolvedValue('译文') };
    const onSaveBook = vi.fn();
    const readBlob = vi.fn(() => new Promise<Uint8Array>((resolve) => { resolveBytes = resolve; }));
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} readBlob={readBlob} onSaveBook={onSaveBook} />);

    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));
    await waitFor(() => expect(readBlob).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole('button', { name: '取消制作' }));
    resolveBytes(new Uint8Array([1, 2, 3]));
    await waitFor(() => expect(screen.getByText('制作已取消')).toBeInTheDocument());
    expect(onSaveBook).not.toHaveBeenCalled();
    expect(screen.queryByRole('heading', { name: '双语书制作完成' })).not.toBeInTheDocument();
  });

  it('disables cancellation once onSaveBook has started finalizing', async () => {
    let resolveSave!: () => void;
    const engine: TranslationEngine = { cacheIdentity: 'studio-finalizing', translate: vi.fn().mockResolvedValue('译文') };
    const onSaveBook = vi.fn(() => new Promise<void>((resolve) => { resolveSave = resolve; }));
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} onSaveBook={onSaveBook} />);

    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));
    await waitFor(() => expect(onSaveBook).toHaveBeenCalledTimes(1));

    const cancelButton = screen.getByRole('button', { name: '取消制作' });
    expect(cancelButton).toBeDisabled();
    fireEvent.click(cancelButton);
    expect(screen.queryByText('制作已取消')).not.toBeInTheDocument();

    resolveSave();
    await waitFor(() => expect(screen.getByRole('heading', { name: '双语书制作完成' })).toBeInTheDocument());
    expect(onSaveBook).toHaveBeenCalledTimes(1);
  });

  it('retries export without calling the translation engine again after finalization fails', async () => {
    const translate = vi.fn().mockResolvedValue('译文');
    const writeEpub = vi.fn()
      .mockRejectedValueOnce(new Error('local export unavailable'))
      .mockResolvedValueOnce(new Blob([new Uint8Array([1, 2, 3])], { type: 'application/epub+zip' }));
    const readBlob = vi.fn().mockResolvedValue(new Uint8Array([1, 2, 3]));
    const onSaveBook = vi.fn();
    const engine: TranslationEngine = { cacheIdentity: 'studio-export-retry', translate };
    render(<BookStudioPage books={[epubBook]} providerStore={new ProviderProfileStore(localStorage)} engineFactory={() => engine} writeEpub={writeEpub} readBlob={readBlob} onSaveBook={onSaveBook} />);

    openBilingualTool();
    fireEvent.click(screen.getByRole('button', { name: '选择 AirRead Test Book' }));
    fireEvent.click(screen.getByRole('button', { name: '下一步：翻译设置' }));
    fireEvent.click(screen.getByRole('button', { name: '开始制作' }));
    await waitFor(() => expect(screen.getByText('导出双语 EPUB 失败')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: '重试导出' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '重试导出' }));
    await waitFor(() => expect(screen.getByRole('heading', { name: '双语书制作完成' })).toBeInTheDocument());
    expect(translate).toHaveBeenCalledTimes(4);
    expect(writeEpub).toHaveBeenCalledTimes(2);
    expect(onSaveBook).toHaveBeenCalledTimes(1);
  });
});
