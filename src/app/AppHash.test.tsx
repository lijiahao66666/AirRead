import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const { firstBook, secondBook, mockStore } = vi.hoisted(() => {
  const firstBook = { id: 'a', title: 'Book A', author: '', format: 'txt' as const, bytes: new Uint8Array([1]), text: 'A text', importedAt: 1, readingChapter: 0, readingProgress: 0, generatedBilingual: false };
  const secondBook = { ...firstBook, id: 'b', title: 'Book B', text: 'B text' };
  return { firstBook, secondBook, mockStore: { listBooks: vi.fn(), saveBook: vi.fn(), deleteBook: vi.fn(), updateBook: vi.fn() } };
});

vi.mock('../domain/books/bookStore', () => ({ createBookStore: () => mockStore }));

import App from '../App';

describe('App hash reader identity', () => {
  beforeEach(() => { window.location.hash = ''; mockStore.listBooks.mockResolvedValue([firstBook, secondBook]); });

  it('derives the active book from the current hash when switching A to B', async () => {
    window.location.hash = '#reader/a';
    render(<App />);
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Book A' })).toBeInTheDocument());
    window.location.hash = '#reader/b';
    fireEvent(window, new HashChangeEvent('hashchange'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Book B' })).toBeInTheDocument());
  });

  it('shows a missing-book state for an invalid reader hash', async () => {
    window.location.hash = '#reader/missing';
    render(<App />);
    await waitFor(() => expect(screen.getByText('找不到书籍')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: '返回书架' })).toBeInTheDocument();
    expect(screen.queryByText('本地配置')).not.toBeInTheDocument();
  });
});
