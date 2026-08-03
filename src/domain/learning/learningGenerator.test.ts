import { afterEach, describe, expect, it, vi } from 'vitest';

import { createCuratedPack, generateLearningPack, isLearningModel } from './learningGenerator';

const generatedLesson = JSON.stringify({
  title: '用英语描述一天',
  theme: 'Daily routines',
  level: '基础进阶',
  originalText: 'I usually start my day with a short walk before work. It helps me feel calm and ready to focus.',
  translation: '我通常会在上班前散一会儿步。这能让我平静下来，准备专注工作。',
  vocabulary: [{ term: 'be ready to', meaning: '准备好做某事', example: 'I am ready to start.' }],
  tasks: [{ kind: 'listen', title: '先听一遍', instruction: '先听后看，捕捉重点。', minutes: 4 }],
});

afterEach(() => vi.restoreAllMocks());

describe('learning generator', () => {
  it('keeps local content inside the available learning time', () => {
    const pack = createCuratedPack('2026-08-03', 15);

    expect(pack.estimatedMinutes).toBe(15);
    expect(pack.audioNote).toBe('system-tts');
    expect(pack.vocabulary).toHaveLength(3);
  });

  it('keeps very short sessions complete instead of dropping the final minutes', () => {
    expect(createCuratedPack('2026-08-03', 5).estimatedMinutes).toBe(5);
    expect(createCuratedPack('2026-08-03', 6).estimatedMinutes).toBe(6);
    expect(createCuratedPack('2026-08-03', 22).estimatedMinutes).toBe(22);
  });

  it('uses a local pack when no language model is configured', async () => {
    const pack = await generateLearningPack(undefined, 12, '2026-08-03');

    expect(pack.generatedBy).toBe('curated');
    expect(isLearningModel(undefined)).toBe(false);
  });

  it('keeps locally generated content aligned with the current plan theme', () => {
    const pack = createCuratedPack('2026-08-03', 15, { theme: 'Starting conversations', focus: '用自然开场消除陌生感' });

    expect(pack.theme).toBe('Starting conversations');
    expect(pack.title).toBe('用自然开场消除陌生感');
  });

  it('generates a learning pack through each supported model protocol', async () => {
    const requests = [
      {
        profile: { id: 'chat', name: 'Chat', kind: 'openai-compatible' as const, enabled: true, baseUrl: 'https://models.example/v1', model: 'model-a', apiKey: 'secret' },
        response: { choices: [{ message: { content: generatedLesson } }] },
        endpoint: 'https://models.example/v1/chat/completions',
      },
      {
        profile: { id: 'responses', name: 'Responses', kind: 'openai-responses' as const, enabled: true, baseUrl: 'https://models.example/v1', model: 'model-b', apiKey: 'secret' },
        response: { output_text: generatedLesson },
        endpoint: 'https://models.example/v1/responses',
      },
      {
        profile: { id: 'anthropic', name: 'Anthropic', kind: 'anthropic-messages' as const, enabled: true, model: 'model-c', apiKey: 'secret' },
        response: { content: [{ type: 'text', text: generatedLesson }] },
        endpoint: 'https://api.anthropic.com/v1/messages',
      },
    ];

    for (const request of requests) {
      const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify(request.response), { status: 200 }));
      const pack = await generateLearningPack(request.profile, 15, '2026-08-03');

      expect(fetchMock).toHaveBeenCalledWith(request.endpoint, expect.objectContaining({ method: 'POST' }));
      expect(pack).toMatchObject({ generatedBy: 'ai', title: '用英语描述一天', audioNote: 'system-tts' });
      fetchMock.mockRestore();
    }
  });

  it('only marks an AI audio result as original when its source and license are complete', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify({
      choices: [{ message: { content: JSON.stringify({
        ...JSON.parse(generatedLesson),
        sourceLabel: '开放英语材料',
        sourceUrl: 'https://example.com/lesson',
        license: 'CC BY 4.0',
        audio: {
          url: 'https://cdn.example.com/lesson.mp3',
          label: '原版录音',
          language: 'en-US',
          accent: 'US',
          license: 'CC BY 4.0',
          sourceUrl: 'https://example.com/audio',
        },
      }) } }],
    }), { status: 200 }));

    const pack = await generateLearningPack({ id: 'chat', name: 'Chat', kind: 'openai-compatible', enabled: true, baseUrl: 'https://models.example/v1', model: 'model-a', apiKey: 'secret' }, 15, '2026-08-03');

    expect(pack).toMatchObject({ audioNote: 'original', sourceLabel: '开放英语材料', sourceUrl: 'https://example.com/lesson' });
    expect(pack.audio?.sourceUrl).toBe('https://example.com/audio');
    fetchMock.mockRestore();
  });

  it('falls back to system read-aloud for incomplete audio metadata', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify({
      choices: [{ message: { content: JSON.stringify({ ...JSON.parse(generatedLesson), audio: { url: 'https://cdn.example.com/lesson.mp3', label: '未授权录音', language: 'en-US' } }) } }],
    }), { status: 200 }));

    const pack = await generateLearningPack({ id: 'chat', name: 'Chat', kind: 'openai-compatible', enabled: true, baseUrl: 'https://models.example/v1', model: 'model-a', apiKey: 'secret' }, 15, '2026-08-03');

    expect(pack.audio).toBeUndefined();
    expect(pack.audioNote).toBe('system-tts');
    fetchMock.mockRestore();
  });
});
