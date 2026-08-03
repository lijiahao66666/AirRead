import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import App from '../App';

describe('AirRead learning application shell', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '#today';
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => Promise.resolve(new Response(JSON.stringify({
      query: {
        pages: {
          42: {
            title: 'City library',
            extract: 'A city library is a public place where people can borrow books. Visitors can also use computers and ask staff for help. Many libraries offer quiet spaces for reading and studying. The service is useful for people of all ages. Community events sometimes bring local readers together to talk about new ideas.',
            canonicalurl: 'https://simple.wikipedia.org/wiki/Library',
          },
        },
      },
    }), { status: 200 })));
  });

  afterEach(() => vi.restoreAllMocks());

  it('renders the daily learning navigation', async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: 'City library' })).toBeInTheDocument());
    expect(screen.getByRole('heading', { name: /AirRead 英语学习/ })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '今日学习' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '学习计划' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '学习设置' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今日复习' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今天的训练' })).toBeInTheDocument();
  });

  it('requests public material and saves the remote text when no model is configured', async () => {
    const fetchSpy = globalThis.fetch as ReturnType<typeof vi.fn>;
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: 'City library' })).toBeInTheDocument());
    expect(fetchSpy.mock.calls[0][0]).toContain('simple.wikipedia.org/w/api.php');
    const saved = JSON.parse(window.localStorage.getItem('airread.learning.v1') ?? '{}') as { packs?: Record<string, { generatedBy?: string; originalText?: string; sourceUrl?: string }> };
    const pack = saved.packs && Object.values(saved.packs)[0];
    expect(pack).toMatchObject({
      generatedBy: 'public',
      originalText: 'A city library is a public place where people can borrow books. Visitors can also use computers and ask staff for help. Many libraries offer quiet spaces for reading and studying. The service is useful for people of all ages. Community events sometimes bring local readers together to talk about new ideas.',
      sourceUrl: 'https://simple.wikipedia.org/wiki/Library',
    });
  });

  it('does not substitute a fixed lesson when a configured model cannot connect', async () => {
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
    vi.restoreAllMocks();
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('network unavailable'));

    render(<App />);

    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('模型暂时无法连接，请检查模型设置后重试。'));
    expect(screen.queryByRole('heading', { name: 'City library' })).not.toBeInTheDocument();
    expect(window.localStorage.getItem('airread.learning.v1')).toBeNull();
  });

  it('clears pointer focus from controls but preserves keyboard focus', async () => {
    render(<App />);
    await waitFor(() => expect(screen.getByRole('heading', { name: 'City library' })).toBeInTheDocument());
    const action = screen.getByRole('button', { name: '使用系统朗读英文原文' });
    const planLink = screen.getByRole('link', { name: '学习计划' });

    action.focus();
    fireEvent.click(action, { detail: 1 });
    expect(action).not.toHaveFocus();

    planLink.focus();
    fireEvent.click(planLink, { detail: 0 });
    expect(planLink).toHaveFocus();
  });

  it('rebuilds today after changing the available time and clears stale completion state', async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: 'City library' })).toBeInTheDocument());

    const firstTask = screen.getAllByRole('button').find((button) => button.getAttribute('aria-label')?.startsWith('完成 '));
    if (firstTask) fireEvent.click(firstTask);
    window.location.hash = '#plan';
    fireEvent(window, new HashChangeEvent('hashchange'));

    const minutesInput = screen.getByRole('spinbutton', { name: '每日可用分钟数' });
    fireEvent.change(minutesInput, { target: { value: '30' } });
    fireEvent.blur(minutesInput);

    await waitFor(() => {
      const saved = JSON.parse(window.localStorage.getItem('airread.learning.v1') ?? '{}') as { plan?: { dailyMinutes?: number }; packs?: Record<string, { estimatedMinutes: number }>; completedTaskIds?: string[]; completedPackIds?: string[] };
      const todayPack = saved.packs && Object.values(saved.packs)[0];
      expect(saved.plan?.dailyMinutes).toBe(30);
      expect(todayPack?.estimatedMinutes).toBe(30);
      expect(saved.completedTaskIds).toEqual([]);
      expect(saved.completedPackIds).toEqual([]);
    });
  });
});
