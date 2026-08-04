import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import App from '../App';

const generatedChapter = {
  title: '来自明天的语音',
  theme: 'A message from tomorrow',
  level: '基础进阶',
  originalText: 'Mia waited at Platform Seven after work. Her phone played an English voice note from tomorrow. The message told her to watch a man with a silver umbrella. She looked across the station and saw him near the exit.',
  translation: '下班后，米娅在七号站台等车。她的手机播放了一段来自明天的英文语音。语音提醒她留意一个拿银色雨伞的男人。她望向车站另一边，看见他站在出口附近。',
  vocabulary: [{ term: 'watch out for', meaning: '留意，警惕', example: 'Watch out for the wet floor.' }],
  story: {
    title: 'The Signal Beyond Platform Seven',
    genre: 'Urban mystery',
    premise: 'A commuter receives English voice notes that arrive one day early.',
    worldRules: ['Each note describes one small event that will happen the next day.'],
    characters: [{ name: 'Mia Chen', role: 'Main character', traits: 'Careful but curious', currentState: 'She has found the man with the silver umbrella.' }],
    timeline: ['Chapter 1: Mia receives the first note and sees the man at the station.'],
    openThreads: ['Who sends the notes, and why does the man carry a silver umbrella?'],
    chapterTitle: 'The Silver Umbrella',
    chapterSummary: '米娅在七号站台收到来自明天的英文语音，并找到了银伞男子。',
    nextHook: '男子转身时，米娅听见第二段语音开始播放。',
  },
  tasks: [{ kind: 'listen', title: '先听一遍', instruction: '先听后看，捕捉重点。', minutes: 4 }],
};

const modelProfile = {
  id: 'story-model',
  name: '连载模型',
  kind: 'openai-compatible',
  enabled: true,
  baseUrl: 'https://models.example/v1',
  model: 'model-a',
  apiKey: 'secret',
};

const modelResponse = () => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(generatedChapter) } }] }), { status: 200 });

describe('AirRead learning application shell', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '#today';
    window.localStorage.setItem('airread.learningModelProfiles.v1', JSON.stringify([modelProfile]));
    window.localStorage.setItem('airread.learningSelectedModel.v1', modelProfile.id);
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => Promise.resolve(modelResponse()));
  });

  afterEach(() => vi.restoreAllMocks());

  it('renders the daily original-serial navigation', async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: /第 1 章 · The Silver Umbrella/ })).toBeInTheDocument());
    expect(screen.getByRole('heading', { name: /AirRead 英语学习/ })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '今日学习' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '学习计划' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '学习设置' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '前情回顾' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今天的训练' })).toBeInTheDocument();
  });

  it('requests the configured model and saves a serial chapter with persistent memory', async () => {
    const fetchSpy = globalThis.fetch as ReturnType<typeof vi.fn>;
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: /第 1 章 · The Silver Umbrella/ })).toBeInTheDocument());
    expect(fetchSpy.mock.calls[0][0]).toBe('https://models.example/v1/chat/completions');
    const saved = JSON.parse(window.localStorage.getItem('airread.learning.v1') ?? '{}') as { packs?: Record<string, { generatedBy?: string; story?: { chapterNumber?: number } }>; storyMemory?: { title?: string; chapterNumber?: number } };
    const pack = saved.packs && Object.values(saved.packs)[0];
    expect(pack).toMatchObject({ generatedBy: 'ai', story: { chapterNumber: 1 } });
    expect(saved.storyMemory).toMatchObject({ title: 'The Signal Beyond Platform Seven', chapterNumber: 1 });
  });

  it('prepares the next chapter in the background without replacing the current lesson', async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: /第 1 章 · The Silver Umbrella/ })).toBeInTheDocument());
    await waitFor(() => {
      const saved = JSON.parse(window.localStorage.getItem('airread.learning.v1') ?? '{}') as { packs?: Record<string, { story?: { chapterNumber?: number } }>; prefetchedStory?: { pack?: { story?: { chapterNumber?: number } } } };
      expect(Object.values(saved.packs ?? {})[0]?.story?.chapterNumber).toBe(1);
      expect(saved.prefetchedStory?.pack?.story?.chapterNumber).toBe(2);
    });
  });

  it('does not substitute a fixed lesson when a configured model cannot connect', async () => {
    vi.restoreAllMocks();
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('network unavailable'));

    render(<App />);

    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('模型暂时无法连接或返回内容不完整，请检查模型设置后重试。'));
    expect(screen.queryByRole('heading', { name: /第 1 章/ })).not.toBeInTheDocument();
    expect(window.localStorage.getItem('airread.learning.v1')).toBeNull();
  });

  it('clears pointer focus from controls but preserves keyboard focus', async () => {
    render(<App />);
    await waitFor(() => expect(screen.getByRole('heading', { name: /第 1 章 · The Silver Umbrella/ })).toBeInTheDocument());
    const action = screen.getByRole('button', { name: '使用系统朗读英文原文' });
    const planLink = screen.getByRole('link', { name: '学习计划' });

    action.focus();
    fireEvent.click(action, { detail: 1 });
    expect(action).not.toHaveFocus();

    planLink.focus();
    fireEvent.click(planLink, { detail: 0 });
    expect(planLink).toHaveFocus();
  });

  it('rebuilds today after changing time without advancing the serial chapter', async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByRole('heading', { name: /第 1 章 · The Silver Umbrella/ })).toBeInTheDocument());

    const firstTask = screen.getAllByRole('button').find((button) => button.getAttribute('aria-label')?.startsWith('完成 '));
    if (firstTask) fireEvent.click(firstTask);
    window.location.hash = '#plan';
    fireEvent(window, new HashChangeEvent('hashchange'));

    const minutesInput = screen.getByRole('spinbutton', { name: '每日可用分钟数' });
    fireEvent.change(minutesInput, { target: { value: '30' } });
    fireEvent.blur(minutesInput);

    await waitFor(() => {
      const saved = JSON.parse(window.localStorage.getItem('airread.learning.v1') ?? '{}') as { plan?: { dailyMinutes?: number }; packs?: Record<string, { estimatedMinutes: number; story?: { chapterNumber?: number } }>; completedTaskIds?: string[]; completedPackIds?: string[] };
      const todayPack = saved.packs && Object.values(saved.packs)[0];
      expect(saved.plan?.dailyMinutes).toBe(30);
      expect(todayPack).toMatchObject({ estimatedMinutes: 30, story: { chapterNumber: 1 } });
      expect(saved.completedTaskIds).toEqual([]);
      expect(saved.completedPackIds).toEqual([]);
    });
  });
});
