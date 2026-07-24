import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { Book } from '../../domain/books/book';
import { BookshelfPage } from './BookshelfPage';

const book: Book = {
  id: 'book-1', title: 'The Little Prince', author: 'Antoine de Saint-Exupéry', format: 'txt',
  bytes: new Uint8Array([1]), text: 'Once upon a time.\nA second paragraph.', importedAt: 100,
  readingChapter: 0, readingProgress: 0.35, generatedBilingual: false,
};

describe('BookshelfPage', () => {
  it('searches, opens, deletes, and imports books', async () => {
    const onImport = vi.fn();
    const onOpen = vi.fn();
    const onDelete = vi.fn();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    render(<BookshelfPage books={[book]} onImport={onImport} onOpen={onOpen} onDelete={onDelete} />);

    expect(screen.getByRole('heading', { name: '我的书架' })).toBeInTheDocument();
    expect(screen.getAllByText('继续阅读').length).toBeGreaterThan(0);
    fireEvent.change(screen.getByRole('searchbox', { name: '搜索书架' }), { target: { value: 'prince' } });
    expect(screen.getAllByText('The Little Prince').length).toBeGreaterThan(0);
    fireEvent.click(screen.getByRole('button', { name: '打开 The Little Prince' }));
    expect(onOpen).toHaveBeenCalledWith('book-1');
    fireEvent.click(screen.getByRole('button', { name: '删除 The Little Prince' }));
    expect(onDelete).toHaveBeenCalledWith('book-1');

    const input = screen.getByLabelText('导入 EPUB 或 TXT') as HTMLInputElement;
    const file = new File(['hello'], 'hello.txt', { type: 'text/plain' });
    fireEvent.change(input, { target: { files: [file] } });
    await waitFor(() => expect(onImport).toHaveBeenCalledWith(file));
  });

  it('continues a book with a saved last-read timestamp and honors delete confirmation', () => {
    const onDelete = vi.fn();
    const timestamped = { ...book, readingProgress: 0, lastReadAt: 500 };
    render(<BookshelfPage books={[timestamped]} onImport={vi.fn()} onOpen={vi.fn()} onDelete={onDelete} />);
    expect(screen.getByText('继续阅读')).toBeInTheDocument();
    vi.spyOn(window, 'confirm').mockReturnValue(false);
    fireEvent.click(screen.getByRole('button', { name: '删除 The Little Prince' }));
    expect(onDelete).not.toHaveBeenCalled();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: '删除 The Little Prince' }));
    expect(onDelete).toHaveBeenCalledWith('book-1');
  });

  it('shows empty and error states', () => {
    const { rerender } = render(<BookshelfPage books={[]} onImport={vi.fn()} onOpen={vi.fn()} onDelete={vi.fn()} />);
    expect(screen.getByText('书架还是空的')).toBeInTheDocument();
    rerender(<BookshelfPage books={[]} loading error="读取书架失败" onImport={vi.fn()} onOpen={vi.fn()} onDelete={vi.fn()} />);
    expect(screen.getByText('正在读取书架')).toBeInTheDocument();
    expect(screen.getByText('读取书架失败')).toBeInTheDocument();
  });
});
