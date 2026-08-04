import { afterEach, describe, expect, it, vi } from 'vitest';

import { buildPlan, completePack, createInitialLearningState, dueReviewCards, loadLearningState, reviewCard, rotatePlan, savePack, updateDailyMinutes } from './learningStore';
import { createOpenLearningPack } from './learningGenerator';

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
      ...createOpenLearningPack('2026-08-03', 15, {
      title: 'City library',
      text: 'The city library opens early on weekdays. Visitors can borrow books and use computers. Staff members can help people find information.',
      sourceLabel: 'Simple English Wikipedia（开放资料）',
      sourceUrl: 'https://simple.wikipedia.org/wiki/Library',
      license: 'CC BY-SA 4.0',
      }),
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

  it('rotates to a different seven-day topic batch without changing the available time', () => {
    const state = { ...createInitialLearningState(), plan: buildPlan(20, '2026-08-03') };
    const rotated = rotatePlan(state);

    expect(rotated.plan.dailyMinutes).toBe(20);
    expect(rotated.plan.themeSetIndex).toBe(1);
    expect(rotated.plan.days[0].theme).not.toBe(state.plan.days[0].theme);
  });

  it('removes the retired fixed lesson instead of showing it after refresh', () => {
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
});
