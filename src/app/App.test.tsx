import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import App from '../App';

describe('AirRead learning application shell', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '#today';
  });

  it('renders the daily learning navigation', () => {
    render(<App />);

    expect(screen.getByRole('heading', { name: /AirRead 英语学习/ })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '今日学习' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '学习计划' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '学习设置' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今日复习' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今天需要记住' })).toBeInTheDocument();
  });

  it('automatically creates a local learning pack without calling a network service when no model is configured', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: '今天需要记住' })).toBeInTheDocument());
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(window.localStorage.getItem('airread.learning.v1')).not.toBeNull();
    fetchSpy.mockRestore();
  });

  it('falls back to a local pack when a configured model cannot connect', async () => {
    window.localStorage.setItem('airread.learningModelProfiles.v1', JSON.stringify([{
      id: 'broken-model',
      name: '不可用模型',
      kind: 'openai-compatible',
      enabled: true,
      baseUrl: 'https://models.example/v1',
      model: 'model-a',
      apiKey: 'secret',
    }]));
    window.localStorage.setItem('airread.learningSelectedModel.v1', 'broken-model');
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('network unavailable'));

    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: '今天需要记住' })).toBeInTheDocument());
    expect(screen.getByRole('status')).toHaveTextContent('模型暂时无法连接，已为你准备本地练习包。');
    expect(fetchSpy).toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it('clears pointer focus from controls but preserves keyboard focus', () => {
    render(<App />);
    const action = screen.getByRole('button', { name: '使用系统朗读英文原文' });
    const planLink = screen.getByRole('link', { name: '学习计划' });

    action.focus();
    fireEvent.click(action, { detail: 1 });
    expect(action).not.toHaveFocus();

    planLink.focus();
    fireEvent.click(planLink, { detail: 0 });
    expect(planLink).toHaveFocus();
  });
});
