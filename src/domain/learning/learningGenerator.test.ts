import { afterEach, describe, expect, it, vi } from 'vitest';

import { generateLearningPack, isLearningModel } from './learningGenerator';
import type { LearningStoryProfile } from './learningTypes';

const storyProfile: LearningStoryProfile = {
  premise: '一个在上海通勤的产品经理，收到来自未来的英文语音；希望是轻科幻悬疑。',
  chapterWordCount: 180,
  createdAt: 1_754_000_000_000,
};

const firstChapter = {
  title: '来自明天的语音',
  theme: 'A message from tomorrow',
  level: '基础进阶',
  originalText: 'Mia waited at Platform Seven after work. Her phone played an English voice note from tomorrow. The message told her to watch a man with a silver umbrella. She looked across the station and saw him near the exit.',
  translation: '下班后，米娅在七号站台等车。她的手机播放了一段来自明天的英文语音。语音提醒她留意一个拿银色雨伞的男人。她望向车站另一边，看见他站在出口附近。',
  vocabulary: [{ term: 'watch out for', meaning: '留意，警惕', example: 'Watch out for the wet floor.' }],
  story: {
    title: 'The Signal Beyond Platform Seven',
    genre: 'Urban science-fiction mystery',
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

const profile = { id: 'chat', name: 'Chat', kind: 'openai-compatible' as const, enabled: true, baseUrl: 'https://models.example/v1', model: 'model-a', apiKey: 'secret' };

const responseFor = (lesson: unknown) => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(lesson) } }] }), { status: 200 });

afterEach(() => vi.restoreAllMocks());

describe('learning generator', () => {
  it('requires an enabled language model instead of falling back to unrelated public material', async () => {
    await expect(generateLearningPack(undefined, 12, '2026-08-03')).rejects.toThrow('请先在学习设置中配置并启用一个语言模型');
    expect(isLearningModel(undefined)).toBe(false);
  });

  it('generates the first original chapter with compact story memory', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(responseFor(firstChapter));

    const generated = await generateLearningPack(profile, 15, '2026-08-03', undefined, storyProfile);

    expect(generated.pack).toMatchObject({ generatedBy: 'ai', sourceLabel: 'AI 原创连载', audioNote: 'system-tts' });
    expect(generated.pack.story).toMatchObject({ chapterNumber: 1, storyTitle: 'The Signal Beyond Platform Seven', chapterTitle: 'The Silver Umbrella' });
    expect(generated.storyMemory).toMatchObject({ chapterNumber: 1, title: 'The Signal Beyond Platform Seven', openThreads: firstChapter.story.openThreads });
    expect(generated.pack.tasks.find((task) => task.kind === 'listen')?.exercise?.type).toBe('listen-choice');
  });

  it('accepts a model response with a text content array and surrounding prose', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify({ choices: [{ message: { content: [{ type: 'text', text: `Here is the JSON you requested:\n${JSON.stringify(firstChapter)}\n` }] } }] }), { status: 200 }));

    const generated = await generateLearningPack(profile, 15, '2026-08-03', undefined, storyProfile);

    expect(generated.pack.story.chapterNumber).toBe(1);
    expect(generated.pack.originalText).toContain('Platform Seven');
  });

  it('passes only compressed story memory into the next chapter and keeps its identity stable', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(responseFor(firstChapter))
      .mockResolvedValueOnce(responseFor({
        ...firstChapter,
        title: '门后的声音',
        originalText: 'Mia followed the man into the tunnel. He stopped at a blue door and spoke her name. Before she could ask a question, her phone played another message. It said that the door would open only if she trusted the wrong person.',
        translation: '米娅跟着那个男人走进通道。他在一扇蓝门前停下，并叫出了她的名字。她还没来得及提问，手机又播放了一条消息。它说，只有当她相信错的人时，那扇门才会打开。',
        story: {
          ...firstChapter.story,
          characters: [{ name: 'Mia Chen', role: 'Main character', traits: 'Careful but curious', currentState: 'She stands before the blue door with the stranger.' }],
          timeline: ['Chapter 1: Mia receives the first note and sees the man at the station.', 'Chapter 2: Mia follows the man to a blue door.'],
          openThreads: ['Why does the next message tell Mia to trust the wrong person?'],
          chapterTitle: 'The Blue Door',
          chapterSummary: '米娅在蓝门前听到新的警告，必须决定是否相信陌生人。',
          nextHook: '蓝门缓缓打开，里面有人用米娅的声音说话。',
        },
      }));

    const first = await generateLearningPack(profile, 15, '2026-08-03', undefined, storyProfile);
    const second = await generateLearningPack(profile, 15, '2026-08-04', undefined, storyProfile, first.storyMemory);

    const secondRequest = vi.mocked(globalThis.fetch).mock.calls[1][1] as RequestInit;
    expect(secondRequest.body).toContain('故事圣经');
    expect(secondRequest.body).toContain(first.storyMemory.latestSummary);
    expect(second.pack.story).toMatchObject({ storyId: first.storyMemory.storyId, chapterNumber: 2, storyTitle: first.storyMemory.title, chapterTitle: 'The Blue Door' });
    expect(second.storyMemory).toMatchObject({ storyId: first.storyMemory.storyId, chapterNumber: 2, latestSummary: '米娅在蓝门前听到新的警告，必须决定是否相信陌生人。' });
  });

  it('uses each supported model protocol for an original serial chapter', async () => {
    const requests = [
      { profile, response: { choices: [{ message: { content: JSON.stringify(firstChapter) } }] }, endpoint: 'https://models.example/v1/chat/completions' },
      { profile: { ...profile, id: 'responses', kind: 'openai-responses' as const }, response: { output_text: JSON.stringify(firstChapter) }, endpoint: 'https://models.example/v1/responses' },
      { profile: { ...profile, id: 'anthropic', kind: 'anthropic-messages' as const, baseUrl: undefined }, response: { content: [{ type: 'text', text: JSON.stringify(firstChapter) }] }, endpoint: 'https://api.anthropic.com/v1/messages' },
    ];

    for (const request of requests) {
      const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify(request.response), { status: 200 }));
      const generated = await generateLearningPack(request.profile, 15, '2026-08-03', undefined, storyProfile);

      expect(fetchMock).toHaveBeenCalledWith(request.endpoint, expect.objectContaining({ method: 'POST' }));
      expect(generated.pack.story.chapterNumber).toBe(1);
      fetchMock.mockRestore();
    }
  });

  it('does not accept a fake original audio marker for AI-written chapters', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(responseFor({
      ...firstChapter,
      audio: { url: 'https://cdn.example.com/lesson.mp3', label: 'Not a source', language: 'en-US' },
    }));

    const generated = await generateLearningPack(profile, 15, '2026-08-03', undefined, storyProfile);

    expect(generated.pack.audio).toBeUndefined();
    expect(generated.pack.audioNote).toBe('system-tts');
  });

  it('keeps valid model exercises anchored in the generated chapter', async () => {
    const lesson = {
      ...firstChapter,
      tasks: [{
        kind: 'listen',
        title: '听懂开场句',
        instruction: '先听后看，辨认材料中的第一句话。',
        minutes: 4,
        exercise: {
          type: 'listen-choice',
          prompt: '听完后选择材料中的开场句。',
          text: 'Mia waited at Platform Seven after work.',
          choices: ['Mia waited at Platform Seven after work.', 'Mia worked at Platform Seven every day.', 'Mia left the station before work.'],
          answer: 'Mia waited at Platform Seven after work.',
        },
      }],
    };
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(responseFor(lesson));

    const generated = await generateLearningPack(profile, 15, '2026-08-03', undefined, storyProfile);

    expect(generated.pack.tasks[0].exercise).toMatchObject({ type: 'listen-choice', prompt: '听完后选择材料中的开场句。' });
  });

  it('rejects a first chapter that omits the persistent story bible', async () => {
    const incomplete = { ...firstChapter, story: { chapterTitle: 'Missing memory', chapterSummary: '摘要', nextHook: '钩子' } };
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(responseFor(incomplete));

    await expect(generateLearningPack(profile, 15, '2026-08-03', undefined, storyProfile)).rejects.toThrow('模型返回的连载章节记忆不完整');
  });
});
