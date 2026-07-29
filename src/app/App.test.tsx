import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import App from '../App';

describe('AirRead application shell', () => {
  it('renders the product name, primary navigation, and import action', () => {
    render(<App />);

    expect(screen.getByRole('heading', { name: 'AirRead 灵阅' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '书架' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '书籍工作室' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '翻译设置' })).toBeInTheDocument();
    expect(screen.getByRole('navigation', { name: '主导航' })).not.toHaveTextContent('设置');
    expect(screen.getByRole('button', { name: '导入书籍' })).toBeInTheDocument();
  });

  it('starts locally without auth, points, check-in, or device bootstrap', async () => {
    window.localStorage.clear();
    const fetchSpy = vi.spyOn(globalThis, 'fetch');

    render(<App />);
    await waitFor(() => expect(screen.getByRole('button', { name: '导入书籍' })).toBeInTheDocument());

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(Object.keys(window.localStorage)).toEqual([]);
    fetchSpy.mockRestore();
  });

  it('clears pointer focus from buttons and links but preserves keyboard focus', () => {
    render(<App />);
    const importButton = screen.getByRole('button', { name: '导入书籍' });
    const studioLink = screen.getByRole('link', { name: '书籍工作室' });

    importButton.focus();
    fireEvent.click(importButton, { detail: 1 });
    expect(importButton).not.toHaveFocus();

    importButton.focus();
    fireEvent.click(importButton, { detail: 0 });
    expect(importButton).toHaveFocus();

    studioLink.focus();
    fireEvent.click(studioLink, { detail: 1 });
    expect(studioLink).not.toHaveFocus();

    studioLink.focus();
    fireEvent.click(studioLink, { detail: 0 });
    expect(studioLink).toHaveFocus();
  });
});
