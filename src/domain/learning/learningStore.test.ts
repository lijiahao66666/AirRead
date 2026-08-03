import { describe, expect, it } from 'vitest';

import { buildPlan, completePack, createInitialLearningState, dueReviewCards, reviewCard, savePack, updateDailyMinutes } from './learningStore';
import { createCuratedPack } from './learningGenerator';

describe('learning store', () => {
  it('builds a seven-day plan from the only user-controlled setting', () => {
    const plan = buildPlan(22, '2026-08-03');

    expect(plan.dailyMinutes).toBe(22);
    expect(plan.days).toHaveLength(7);
    expect(plan.days[0]).toMatchObject({ date: '2026-08-03', minutes: 22 });
    expect(plan.days[6].date).toBe('2026-08-09');
  });

  it('clamps daily time and schedules new vocabulary for review', () => {
    const pack = createCuratedPack('2026-08-03', 15);
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
});
