import type { LearningPack, LearningPlan, LearningPlanDay, LearningReviewCard, LearningState } from './learningTypes';

const STORAGE_KEY = 'airread.learning.v1';
const DEFAULT_MINUTES = 15;
const PLAN_THEMES = [
  ['Small talk at work', '听懂寒暄并自然回应'],
  ['Making plans', '掌握约时间和表达安排'],
  ['Explaining a problem', '清楚描述问题和需求'],
  ['Travel and directions', '在真实场景中获取信息'],
  ['Opinions and reasons', '表达观点并补充理由'],
  ['News in plain English', '从短新闻提取关键信息'],
  ['Weekly consolidation', '综合复习本周高频表达'],
] as const;

const toDateKey = (date: Date): string => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
};

export const todayKey = (): string => toDateKey(new Date());

export const addDays = (dateKey: string, days: number): string => {
  const date = new Date(`${dateKey}T12:00:00`);
  date.setDate(date.getDate() + days);
  return toDateKey(date);
};

export const clampDailyMinutes = (value: number): number => Math.min(180, Math.max(5, Math.round(value)));

export const buildPlan = (dailyMinutes: number, startDate = todayKey()): LearningPlan => ({
  dailyMinutes: clampDailyMinutes(dailyMinutes),
  createdAt: Date.now(),
  days: PLAN_THEMES.map(([theme, focus], index): LearningPlanDay => ({
    date: addDays(startDate, index),
    theme,
    focus,
    minutes: clampDailyMinutes(dailyMinutes),
  })),
});

const isLearningState = (value: unknown): value is LearningState => {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<LearningState>;
  return Boolean(candidate.plan && typeof candidate.plan.dailyMinutes === 'number' && Array.isArray(candidate.completedPackIds));
};

export const createInitialLearningState = (): LearningState => ({
  plan: buildPlan(DEFAULT_MINUTES),
  packs: {},
  completedPackIds: [],
  completedTaskIds: [],
  reviewCards: [],
});

export const loadLearningState = (storage: Storage = window.localStorage): LearningState => {
  const raw = storage.getItem(STORAGE_KEY);
  if (!raw) return createInitialLearningState();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isLearningState(parsed)) return createInitialLearningState();
    return {
      ...createInitialLearningState(),
      ...parsed,
      packs: parsed.packs ?? {},
      completedPackIds: parsed.completedPackIds ?? [],
      completedTaskIds: parsed.completedTaskIds ?? [],
      reviewCards: parsed.reviewCards ?? [],
    };
  } catch {
    return createInitialLearningState();
  }
};

export const saveLearningState = (state: LearningState, storage: Storage = window.localStorage): void => {
  storage.setItem(STORAGE_KEY, JSON.stringify(state));
};

export const updateDailyMinutes = (state: LearningState, dailyMinutes: number): LearningState => ({
  ...state,
  plan: buildPlan(dailyMinutes),
});

export const savePack = (state: LearningState, pack: LearningPack): LearningState => ({
  ...state,
  packs: { ...state.packs, [pack.date]: pack },
});

export const completeTask = (state: LearningState, taskId: string): LearningState => ({
  ...state,
  completedTaskIds: state.completedTaskIds.includes(taskId) ? state.completedTaskIds : [...state.completedTaskIds, taskId],
});

export const completePack = (state: LearningState, pack: LearningPack): LearningState => {
  return {
    ...state,
    reviewCards: mergeReviewCards(state.reviewCards, pack),
    completedPackIds: state.completedPackIds.includes(pack.id) ? state.completedPackIds : [...state.completedPackIds, pack.id],
  };
};

export const reviewCard = (state: LearningState, cardId: string, remembered: boolean): LearningState => {
  const today = todayKey();
  return {
    ...state,
    reviewCards: state.reviewCards.map((card) => {
      if (card.id !== cardId) return card;
      const nextInterval = remembered ? Math.min(60, Math.max(1, card.intervalDays * 2)) : 1;
      return { ...card, intervalDays: nextInterval, repetitions: remembered ? card.repetitions + 1 : 0, dueAt: addDays(today, nextInterval) };
    }),
  };
};

export const dueReviewCards = (state: LearningState, date = todayKey()): LearningReviewCard[] => state.reviewCards.filter((card) => card.dueAt <= date);

const mergeReviewCards = (cards: LearningReviewCard[], pack: LearningPack): LearningReviewCard[] => {
  const next = [...cards];
  pack.vocabulary.forEach((vocabulary) => {
    const existing = next.find((card) => card.id === `${pack.id}:${vocabulary.term}`);
    if (!existing) next.push({ id: `${pack.id}:${vocabulary.term}`, ...vocabulary });
  });
  return next;
};

export const DEFAULT_DAILY_MINUTES = DEFAULT_MINUTES;
