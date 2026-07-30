import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { BookSourceSearchPage } from './BookSourceSearchPage';

describe('BookSourceSearchPage', () => {
  it('searches all sources once and keeps source actions as external links', async () => {
    const search = vi.fn().mockResolvedValue({
      unavailableProviders: [],
      results: [
        { id: 'catalog:论语', title: '论语', author: '杨伯峻', description: '2018 · 中文书目', provider: 'chinese-catalog', providerName: '中文书目 · 豆瓣读书', action: 'open', actionLabel: '查看书目', sourceUrl: 'https://book.douban.com/subject/30466012/' },
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
    expect(screen.getAllByRole('link', { name: '查看书目' })[0]).toHaveAttribute('href', 'https://book.douban.com/subject/30466012/');
    expect(screen.getAllByRole('link', { name: '查看书目' })[1]).toHaveAttribute('href', 'https://www.gutenberg.org/ebooks/1342');
  });
});
