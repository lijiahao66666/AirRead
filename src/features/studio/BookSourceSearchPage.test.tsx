import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { BookSourceSearchPage } from './BookSourceSearchPage';

describe('BookSourceSearchPage', () => {
  it('searches all sources once and imports Wikisource results from the shared list', async () => {
    const search = vi.fn().mockResolvedValue({
      unavailableProviders: [],
      results: [
        { id: 'wikisource:论语', title: '论语', author: '中文维基文库', description: '开放文本', provider: 'wikisource', providerName: '中文维基文库', action: 'import', sourceTitle: '论语', sourceUrl: 'https://zh.wikisource.org/wiki/%E8%AE%BA%E8%AF%AD' },
        { id: 'archive:pride', title: 'Pride and Prejudice', author: 'Austen, Jane', description: '1813 · 公共领域 EPUB', provider: 'archive-gutenberg', providerName: 'Gutenberg 公共领域书库', action: 'download', downloadUrl: 'https://archive.org/download/pride/pride.epub', sourceUrl: 'https://archive.org/details/pride' },
      ],
    });
    const loadWikisourcePage = vi.fn().mockResolvedValue({ title: '论语', text: '学而时习之', url: 'https://zh.wikisource.org/wiki/%E8%AE%BA%E8%AF%AD' });
    const onSaveBook = vi.fn();
    render(<BookSourceSearchPage onBack={vi.fn()} onSaveBook={onSaveBook} search={search} loadWikisourcePage={loadWikisourcePage} />);

    fireEvent.change(screen.getByRole('textbox', { name: '搜索开放书籍' }), { target: { value: '论语' } });
    expect(screen.queryByText('没有找到可用的开放书籍，换一个书名、作者或英文关键词试试。')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '搜索全部书源' }));

    await waitFor(() => expect(search).toHaveBeenCalledWith('论语'));
    expect(screen.getByRole('heading', { name: '搜索书籍' })).toBeInTheDocument();
    expect(screen.getByText('Pride and Prejudice')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '下载 EPUB' })).toHaveAttribute('href', 'https://archive.org/download/pride/pride.epub');
    fireEvent.click(screen.getByRole('button', { name: '导入' }));
    await waitFor(() => expect(onSaveBook).toHaveBeenCalledTimes(1));
    expect(loadWikisourcePage).toHaveBeenCalledWith('论语');
  });
});
