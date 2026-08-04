import type { GeneratedLearningPack, LearningPack, LearningPlan, LearningPlanDay, LearningReviewCard, LearningState, LearningStoryMemory, PrefetchedLearningStory } from './learningTypes';
import { buildTaskExercise } from './taskExercises';

const STORAGE_KEY = 'airread.learning.v1';
const DEFAULT_MINUTES = 15;
const DEFAULT_CHAPTER_WORD_COUNT = 180;
const PLAN_THEME_SETS = [
  [
    ['Small talk at work', '听懂寒暄并自然回应'],
    ['Making plans', '掌握约时间和表达安排'],
    ['Explaining a problem', '清楚描述问题和需求'],
    ['Travel and directions', '在真实场景中获取信息'],
    ['Opinions and reasons', '表达观点并补充理由'],
    ['News in plain English', '从短新闻提取关键信息'],
    ['Weekly consolidation', '综合复习本周高频表达'],
  ],
  [
    ['Starting conversations', '用自然开场消除陌生感'],
    ['Daily routines', '描述习惯与生活节奏'],
    ['Asking for help', '礼貌地说明需要与限制'],
    ['Food and preferences', '表达偏好并追问细节'],
    ['Sharing an experience', '按顺序讲清一段经历'],
    ['Work updates', '简洁同步进展与下一步'],
    ['Weekly consolidation', '把本周表达放回真实场景'],
  ],
  [
    ['Commuting and the city', '听懂出行与地点相关表达'],
    ['Meeting new people', '介绍自己并延续对话'],
    ['Solving small problems', '描述麻烦并提出可行方案'],
    ['Making recommendations', '给出建议并解释理由'],
    ['Talking about media', '聊一段内容与个人感受'],
    ['Giving an opinion', '表达观点并回应不同看法'],
    ['Weekly consolidation', '复盘高频词块并主动输出'],
  ],
  [
    ['Ordering food', '完成一段简短的真实点单对话'],
    ['A useful phone call', '听懂关键信息并确认细节'],
    ['Learning from a story', '从短文中抓住人物与变化'],
    ['Planning a weekend', '提出邀请并商量安排'],
    ['Explaining a choice', '说清楚自己为什么这样选择'],
    ['A short news update', '提取主旨并复述关键事实'],
    ['Weekly consolidation', '用本周内容完成一次复述'],
  ],
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

export const clampChapterWordCount = (value: number): number => Math.min(2_000, Math.max(80, Math.round(value / 10) * 10));

const normalizeThemeSetIndex = (index: number): number => ((Math.trunc(index) % PLAN_THEME_SETS.length) + PLAN_THEME_SETS.length) % PLAN_THEME_SETS.length;

const practicePatternFor = (dailyMinutes: number): string => {
  if (dailyMinutes <= 7) return '听力输入 · 主动回忆';
  if (dailyMinutes <= 11) return '复习 · 听力 · 跟读';
  if (dailyMinutes <= 17) return '复习 · 听读 · 跟读';
  if (dailyMinutes <= 23) return '复习 · 听读 · 跟读 · 复述';
  return '复习 · 听读 · 跟读 · 复述 · 短写作';
};

export const buildPlan = (dailyMinutes: number, startDate = todayKey(), themeSetIndex = 0): LearningPlan => {
  const normalizedMinutes = clampDailyMinutes(dailyMinutes);
  const normalizedThemeSetIndex = normalizeThemeSetIndex(themeSetIndex);
  return {
    dailyMinutes: normalizedMinutes,
    themeSetIndex: normalizedThemeSetIndex,
    createdAt: Date.now(),
    days: PLAN_THEME_SETS[normalizedThemeSetIndex].map(([theme, focus], index): LearningPlanDay => ({
      date: addDays(startDate, index),
      theme,
      focus,
      practicePattern: practicePatternFor(normalizedMinutes),
      minutes: normalizedMinutes,
    })),
  };
};

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
  taskResponses: {},
  reviewCards: [],
  storyProfile: { premise: '', chapterWordCount: DEFAULT_CHAPTER_WORD_COUNT, createdAt: Date.now() },
  storyMemoryHistory: [],
});

const isRetiredPack = (pack: LearningPack): boolean => {
  const generatedBy = (pack as { generatedBy?: unknown }).generatedBy;
  return generatedBy !== 'ai' || !pack.story || typeof pack.story.storyId !== 'string' || typeof pack.story.chapterNumber !== 'number';
};

const isStoryMemory = (value: unknown): value is LearningStoryMemory => {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<LearningStoryMemory>;
  return typeof candidate.storyId === 'string'
    && typeof candidate.title === 'string'
    && typeof candidate.genre === 'string'
    && typeof candidate.premise === 'string'
    && Array.isArray(candidate.worldRules)
    && Array.isArray(candidate.characters)
    && Array.isArray(candidate.timeline)
    && Array.isArray(candidate.openThreads)
    && typeof candidate.chapterNumber === 'number'
    && typeof candidate.latestSummary === 'string'
    && typeof candidate.nextHook === 'string';
};

const isPrefetchedStory = (value: unknown): value is PrefetchedLearningStory => {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<PrefetchedLearningStory>;
  return typeof candidate.sourcePackId === 'string'
    && typeof candidate.preparedAt === 'number'
    && Boolean(candidate.pack && typeof candidate.pack.id === 'string' && candidate.pack.story)
    && isStoryMemory(candidate.storyMemory);
};

const hydratePackExercises = (pack: LearningPack): LearningPack => ({
  ...pack,
  tasks: pack.tasks.map((task, index) => task.exercise ? task : { ...task, exercise: buildTaskExercise(task.kind, pack.originalText, task.id, { sentenceIndex: index, vocabulary: pack.vocabulary }) }),
});

export const loadLearningState = (storage: Storage = window.localStorage): LearningState => {
  const raw = storage.getItem(STORAGE_KEY);
  if (!raw) return createInitialLearningState();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isLearningState(parsed)) return createInitialLearningState();
    const initial = createInitialLearningState();
    const hasThemeSetIndex = typeof parsed.plan.themeSetIndex === 'number';
    return {
      ...initial,
      ...parsed,
      plan: hasThemeSetIndex
        ? {
          ...initial.plan,
          ...parsed.plan,
          themeSetIndex: normalizeThemeSetIndex(parsed.plan.themeSetIndex),
          days: Array.isArray(parsed.plan.days) && parsed.plan.days.every((day) => typeof day.practicePattern === 'string') ? parsed.plan.days : buildPlan(parsed.plan.dailyMinutes, todayKey(), parsed.plan.themeSetIndex).days,
        }
        : buildPlan(parsed.plan.dailyMinutes),
      packs: Object.fromEntries(Object.entries(parsed.packs ?? {}).filter(([, pack]) => !isRetiredPack(pack)).map(([date, pack]) => [date, hydratePackExercises(pack)])),
      completedPackIds: parsed.completedPackIds ?? [],
      completedTaskIds: parsed.completedTaskIds ?? [],
      taskResponses: parsed.taskResponses ?? {},
      reviewCards: parsed.reviewCards ?? [],
      storyProfile: parsed.storyProfile && typeof parsed.storyProfile.premise === 'string'
        ? { premise: parsed.storyProfile.premise, chapterWordCount: clampChapterWordCount(typeof parsed.storyProfile.chapterWordCount === 'number' ? parsed.storyProfile.chapterWordCount : DEFAULT_CHAPTER_WORD_COUNT), createdAt: typeof parsed.storyProfile.createdAt === 'number' ? parsed.storyProfile.createdAt : Date.now() }
        : initial.storyProfile,
      storyMemory: isStoryMemory(parsed.storyMemory) ? parsed.storyMemory : undefined,
      storyMemoryHistory: Array.isArray(parsed.storyMemoryHistory) ? parsed.storyMemoryHistory.filter(isStoryMemory).slice(-10) : [],
      prefetchedStory: isPrefetchedStory(parsed.prefetchedStory) ? parsed.prefetchedStory : undefined,
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
  plan: buildPlan(dailyMinutes, todayKey(), state.plan.themeSetIndex),
  prefetchedStory: undefined,
});

export const rotatePlan = (state: LearningState): LearningState => ({
  ...state,
  plan: buildPlan(state.plan.dailyMinutes, todayKey(), state.plan.themeSetIndex + 1),
  prefetchedStory: undefined,
});

export const savePack = (state: LearningState, pack: LearningPack): LearningState => ({
  ...state,
  packs: { ...state.packs, [pack.date]: pack },
});

export const packsForDate = (packs: Record<string, LearningPack>, date: string): LearningPack[] => Object.values(packs)
  .filter((pack) => pack.date === date)
  .sort((left, right) => left.story.chapterNumber - right.story.chapterNumber || left.createdAt - right.createdAt);

export const latestPackForDate = (packs: Record<string, LearningPack>, date: string): LearningPack | undefined => packsForDate(packs, date).at(-1);

export const saveGeneratedStory = (state: LearningState, pack: LearningPack, storyMemory: LearningStoryMemory): LearningState => {
  const previous = state.storyMemory;
  const history = previous && previous.storyId === storyMemory.storyId && previous.chapterNumber < storyMemory.chapterNumber
    ? [...state.storyMemoryHistory, previous].slice(-10)
    : state.storyMemoryHistory;
  const packs = Object.fromEntries(Object.entries(state.packs).filter(([key, existing]) => !(key === pack.date && existing.story?.chapterNumber === pack.story.chapterNumber)));
  return {
    ...state,
    packs: { ...packs, [`${pack.date}#${pack.story.chapterNumber}`]: pack },
    storyMemory,
    storyMemoryHistory: history,
    prefetchedStory: undefined,
  };
};

export const savePrefetchedStory = (state: LearningState, sourcePackId: string, generated: GeneratedLearningPack): LearningState => ({
  ...state,
  prefetchedStory: { sourcePackId, ...generated, preparedAt: Date.now() },
});

export const usePrefetchedStory = (state: LearningState, sourcePackId: string): LearningState => {
  const prefetched = state.prefetchedStory;
  if (!prefetched || prefetched.sourcePackId !== sourcePackId) return state;
  return saveGeneratedStory(state, prefetched.pack, prefetched.storyMemory);
};

export const rewindStoryForPack = (state: LearningState, pack?: LearningPack): LearningState => {
  if (!pack?.story || state.storyMemory?.storyId !== pack.story.storyId || state.storyMemory.chapterNumber !== pack.story.chapterNumber) return state;
  const historyIndex = [...state.storyMemoryHistory].map((memory) => memory.storyId).lastIndexOf(pack.story.storyId);
  if (historyIndex < 0) return { ...state, storyMemory: undefined };
  const prior = state.storyMemoryHistory[historyIndex];
  return {
    ...state,
    storyMemory: prior,
    storyMemoryHistory: state.storyMemoryHistory.filter((_, index) => index !== historyIndex),
  };
};

export const updateStoryProfile = (state: LearningState, premise: string): LearningState => ({
  ...state,
  storyProfile: { ...state.storyProfile, premise: premise.trim().slice(0, 1_000), createdAt: Date.now() },
});

export const updateChapterWordCount = (state: LearningState, chapterWordCount: number): LearningState => ({
  ...state,
  storyProfile: { ...state.storyProfile, chapterWordCount: clampChapterWordCount(chapterWordCount) },
  prefetchedStory: undefined,
});

export const startNewStory = (state: LearningState): LearningState => ({
  ...state,
  packs: {},
  completedPackIds: [],
  completedTaskIds: [],
  taskResponses: {},
  storyMemory: undefined,
  storyMemoryHistory: [],
  prefetchedStory: undefined,
});

export const completeTask = (state: LearningState, taskId: string): LearningState => ({
  ...state,
  completedTaskIds: state.completedTaskIds.includes(taskId) ? state.completedTaskIds : [...state.completedTaskIds, taskId],
});

export const saveTaskResponse = (state: LearningState, taskId: string, response: string): LearningState => ({
  ...state,
  taskResponses: { ...state.taskResponses, [taskId]: response },
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
