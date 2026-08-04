import { afterEach, describe, expect, it, vi } from 'vitest';

import { buildPlan, completePack, createInitialLearningState, dueReviewCards, latestPackForDate, loadLearningState, packsForDate, reviewCard, rewindStoryForPack, saveGeneratedStory, savePack, savePrefetchedStory, startNewStory, updateDailyMinutes, usePrefetchedStory } from './learningStore';
import { createStoryMemoryFixture, createStoryPackFixture } from '../../test/learningFixture';

describe('learning store', () => {
  afterEach(() => vi.useRealTimers());

  it('builds a seven-day plan from the only user-controlled setting', () => {
    const plan = buildPlan(22, '2026-08-03');

    expect(plan.dailyMinutes).toBe(22);
    expect(plan.days).toHaveLength(7);
    expect(plan.days[0]).toMatchObject({ date: '2026-08-03', minutes: 22 });
    expect(plan.days[6].date).toBe('2026-08-09');
  });

  it('clamps daily time and schedules new vocabulary for review', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-08-03T12:00:00+08:00'));
    const pack = {
      ...createStoryPackFixture('2026-08-03', 15),
      vocabulary: [{ term: 'open early', meaning: '早早开放', example: 'The library opens early.', dueAt: '2026-08-04', intervalDays: 1, repetitions: 0 }],
    };
    const saved = savePack(createInitialLearningState(), pack);
    expect(saved.reviewCards).toHaveLength(0);
    const completed = completePack(saved, pack);
    const firstCard = completed.reviewCards[0];

    expect(updateDailyMinutes(saved, 1).plan.dailyMinutes).toBe(5);
    expect(completed.completedPackIds).toContain(pack.id);
    expect(dueReviewCards(completed, '2026-08-03')).toHaveLength(0);
    const reviewed = reviewCard({ ...completed, reviewCards: [{ ...firstCard, dueAt: '2026-08-03' }] }, firstCard.id, true);
    expect(reviewed.reviewCards[0].intervalDays).toBe(2);
    expect(reviewed.reviewCards[0].dueAt).toBe('2026-08-05');
  });

  it('keeps the selected topic batch while rebuilding the learning structure for a new duration', () => {
    const state = { ...createInitialLearningState(), plan: buildPlan(12, '2026-08-03', 2) };
    const updated = updateDailyMinutes(state, 28);

    expect(updated.plan.themeSetIndex).toBe(2);
    expect(updated.plan.days.map((day) => day.minutes)).toEqual(Array(7).fill(28));
    expect(updated.plan.days[0]).toMatchObject({ theme: state.plan.days[0].theme, practicePattern: '复习 · 听读 · 跟读 · 复述 · 短写作' });
  });

  it('migrates a cached plan without a version to the current learning topics', () => {
    const storage = window.localStorage;
    storage.clear();
    const initial = createInitialLearningState();
    const { version: _legacyVersion, ...legacyPlan } = initial.plan;
    storage.setItem('airread.learning.v1', JSON.stringify({
      ...initial,
      plan: { ...legacyPlan, days: legacyPlan.days.map((day) => ({ ...day, theme: '旧固定课程' })) },
    }));

    const migrated = loadLearningState(storage);

    expect(migrated.plan.version).toBe(initial.plan.version);
    expect(migrated.plan.days[0].theme).not.toBe('旧固定课程');
    storage.clear();
  });

  it('removes pre-serial learning packs instead of mixing them into an original story', () => {
    const storage = window.localStorage;
    storage.clear();
    const legacyPack = {
      id: 'pack-2026-08-03',
      date: '2026-08-03',
      title: '旧练习',
      theme: '旧主题',
      level: '旧难度',
      estimatedMinutes: 15,
      originalText: 'Old fixed lesson.',
      sourceLabel: 'AirRead 练习样例',
      audioNote: 'system-tts',
      vocabulary: [],
      tasks: [],
      generatedBy: 'curated',
      createdAt: Date.now(),
    };
    storage.setItem('airread.learning.v1', JSON.stringify({ ...createInitialLearningState(), packs: { '2026-08-03': legacyPack } }));

    expect(loadLearningState(storage).packs).toEqual({});
    storage.clear();
  });

  it('keeps a short compressed memory history so today can be regenerated without skipping a chapter', () => {
    const firstMemory = createStoryMemoryFixture();
    const firstPack = createStoryPackFixture('2026-08-03');
    const secondMemory = createStoryMemoryFixture({ chapterNumber: 2, latestSummary: '第二章推进。', nextHook: '第三章钩子。' });
    const secondPack = { ...createStoryPackFixture('2026-08-04'), story: { ...createStoryPackFixture('2026-08-04').story, chapterNumber: 2, chapterTitle: 'The Blue Door' } };
    const state = saveGeneratedStory(saveGeneratedStory(createInitialLearningState(), firstPack, firstMemory), secondPack, secondMemory);

    const rewound = rewindStoryForPack(state, secondPack);

    expect(rewound.storyMemory).toMatchObject({ chapterNumber: 1, latestSummary: firstMemory.latestSummary });
    expect(rewound.storyMemoryHistory).toEqual([]);
  });

  it('keeps multiple chapters generated on the same day and selects the latest one', () => {
    const first = createStoryPackFixture('2026-08-03');
    const second = { ...createStoryPackFixture('2026-08-03'), id: 'pack-2026-08-03-chapter-2', story: { ...first.story, chapterNumber: 2, chapterTitle: 'The Blue Door' } };
    const state = saveGeneratedStory(saveGeneratedStory(createInitialLearningState(), first, createStoryMemoryFixture()), second, createStoryMemoryFixture({ chapterNumber: 2 }));

    expect(packsForDate(state.packs, '2026-08-03')).toHaveLength(2);
    expect(latestPackForDate(state.packs, '2026-08-03')?.story.chapterNumber).toBe(2);
  });

  it('keeps a prepared next chapter separate until the learner chooses to enter it', () => {
    const currentPack = createStoryPackFixture('2026-08-03');
    const currentMemory = createStoryMemoryFixture();
    const nextPack = { ...createStoryPackFixture('2026-08-03'), id: 'pack-2026-08-03-chapter-2', story: { ...currentPack.story, chapterNumber: 2, chapterTitle: 'The Blue Door' } };
    const nextMemory = createStoryMemoryFixture({ chapterNumber: 2, latestSummary: '第二章推进。', nextHook: '第三章钩子。' });
    const currentState = saveGeneratedStory(createInitialLearningState(), currentPack, currentMemory);
    const prepared = savePrefetchedStory(currentState, currentPack.id, { pack: nextPack, storyMemory: nextMemory });

    expect(latestPackForDate(prepared.packs, '2026-08-03')?.story.chapterNumber).toBe(1);
    expect(prepared.prefetchedStory?.pack.story.chapterNumber).toBe(2);

    const entered = usePrefetchedStory(prepared, currentPack.id);
    expect(latestPackForDate(entered.packs, '2026-08-03')?.story.chapterNumber).toBe(2);
    expect(entered.prefetchedStory).toBeUndefined();
  });

  it('starts a new story without discarding spaced-repetition cards', () => {
    const pack = createStoryPackFixture();
    const state = {
      ...completePack(savePack(createInitialLearningState(), pack), pack),
      storyMemory: createStoryMemoryFixture(),
      storyMemoryHistory: [createStoryMemoryFixture({ chapterNumber: 0 })],
      completedTaskIds: [pack.tasks[0].id],
      taskResponses: { [pack.tasks[0].id]: 'done' },
    };

    const restarted = startNewStory(state);

    expect(restarted.packs).toEqual({});
    expect(restarted.storyMemory).toBeUndefined();
    expect(restarted.storyMemoryHistory).toEqual([]);
    expect(restarted.reviewCards).toHaveLength(1);
  });
});
