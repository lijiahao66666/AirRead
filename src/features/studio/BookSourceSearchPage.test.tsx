import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { BookSourceSearchPage } from './BookSourceSearchPage';

const page = { title: '论语', text: '子曰：学而时习之。', url: 'https://zh.wikisource.org/wiki/%E8%AB%96%E8%AA%9E' };

describe('BookSourceSearchPage', () => {
  it('searches importable open works and imports the selected full text', async () => {
    const search = vi.fn().mockResolvedValue([{ title: '论语', snippet: '孔子经典', wordCount: 123 }]);
    const loadPage = vi.fn().mockResolvedValue(page);
    const createBook = vi.fn().mockReturnValue({ id: 'wikisource:论语', title: '论语', author: '中文维基文库', format: 'txt', bytes: new Uint8Array(), text: page.text, importedAt: 1, readingChapter: 0, readingProgress: 0, generatedBilingual: false, source: { provider: 'wikisource', url: page.url, license: 'CC BY-SA' } });
    const onImportBook = vi.fn();
    render(<BookSourceSearchPage onBack={vi.fn()} onImportBook={onImportBook} search={search} loadPage={loadPage} createBook={createBook} />);

    fireEvent.change(screen.getByRole('textbox', { name: '搜索开放作品' }), { target: { value: '论语' } });
    expect(screen.queryByText('没有找到可导入的开放作品，换一个书名、作者或关键词试试。')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '搜索作品' }));

    await waitFor(() => expect(search).toHaveBeenCalledWith('论语'));
    expect(screen.getByRole('heading', { name: '搜索并导入作品' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '导入并阅读' }));
    await waitFor(() => expect(onImportBook).toHaveBeenCalledWith(expect.objectContaining({ id: 'wikisource:论语', text: page.text })));
    expect(loadPage).toHaveBeenCalledWith('论语');
    expect(createBook).toHaveBeenCalledWith(page);
  });
});
