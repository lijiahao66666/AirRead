import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { BookSourceSearchPage } from './BookSourceSearchPage';

describe('BookSourceSearchPage', () => {
  it('searches all sources once and keeps source actions as external links', async () => {
    const search = vi.fn().mockResolvedValue({
      unavailableProviders: [],
      results: [
        { id: 'classics:论语', title: '论语', author: '孔子弟子及再传弟子', description: '中文传统典籍', provider: 'classics-index', providerName: '中文典籍索引 · 古文岛', action: 'open', actionLabel: '前往阅读', sourceUrl: 'https://www.guwendao.net/guwen/book_1bd76a1c3d01.aspx' },
        { id: 'gutenberg:1342', title: 'Pride and Prejudice', author: 'Austen, Jane', description: '公共领域书目', provider: 'gutenberg', providerName: 'Project Gutenberg', action: 'open', actionLabel: '查看书目', sourceUrl: 'https://www.gutenberg.org/ebooks/1342' },
      ],
    });
    render(<BookSourceSearchPage onBack={vi.fn()} search={search} />);

    fireEvent.change(screen.getByRole('textbox', { name: '搜索开放书籍' }), { target: { value: '论语' } });
    expect(screen.queryByText('没有找到可用书目，换一个书名、作者或关键词试试。')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '搜索全部书源' }));

    await waitFor(() => expect(search).toHaveBeenCalledWith('论语'));
    expect(screen.getByRole('heading', { name: '搜索书籍' })).toBeInTheDocument();
    expect(screen.getByText('Pride and Prejudice')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '前往阅读' })).toHaveAttribute('href', 'https://www.guwendao.net/guwen/book_1bd76a1c3d01.aspx');
    expect(screen.getByRole('link', { name: '查看书目' })).toHaveAttribute('href', 'https://www.gutenberg.org/ebooks/1342');
  });
});
