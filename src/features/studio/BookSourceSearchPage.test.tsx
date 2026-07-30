import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { BookSourceSearchPage } from './BookSourceSearchPage';

describe('BookSourceSearchPage', () => {
  it('searches importable EPUB works and imports the selected full text', async () => {
    const result = { id: '1342', title: 'Pride and Prejudice', author: 'Jane Austen', downloads: '177064 downloads' };
    const search = vi.fn().mockResolvedValue([result]);
    const download = vi.fn().mockResolvedValue({ id: 'gutenberg:1342', title: result.title, author: result.author, format: 'epub', bytes: new Uint8Array(), importedAt: 1, readingChapter: 0, readingProgress: 0, generatedBilingual: false, source: { provider: 'gutenberg', url: 'https://www.gutenberg.org/ebooks/1342', license: 'Public domain' } });
    const onImportBook = vi.fn();
    render(<BookSourceSearchPage onBack={vi.fn()} onImportBook={onImportBook} search={search} download={download} />);

    fireEvent.change(screen.getByRole('textbox', { name: '搜索开放作品' }), { target: { value: 'pride' } });
    expect(screen.queryByText('没有找到可导入的开放作品，换一个书名、作者或关键词试试。')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '搜索作品' }));

    await waitFor(() => expect(search).toHaveBeenCalledWith('pride'));
    expect(screen.getByRole('heading', { name: '搜索并导入作品' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '导入并阅读' }));
    await waitFor(() => expect(onImportBook).toHaveBeenCalledWith(expect.objectContaining({ id: 'gutenberg:1342', title: result.title })));
    expect(download).toHaveBeenCalledWith(result);
  });
});
