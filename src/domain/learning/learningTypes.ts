export type LearningTaskKind = 'review' | 'listen' | 'read' | 'speak' | 'recall' | 'write';

export type LearningTaskExercise = {
  type: 'listen-choice' | 'reading-check' | 'cloze' | 'shadowing' | 'word-order' | 'free-write';
  prompt: string;
  answer?: string;
  text?: string;
  referenceText?: string;
  choices?: string[];
  minimumWords?: number;
};

export type LearningVocabulary = {
  term: string;
  meaning: string;
  example: string;
  dueAt: string;
  intervalDays: number;
  repetitions: number;
};

export type LearningTask = {
  id: string;
  kind: LearningTaskKind;
  title: string;
  instruction: string;
  minutes: number;
  exercise?: LearningTaskExercise;
};

export type LearningAudio = {
  url: string;
  label: string;
  language: string;
  accent?: string;
  license?: string;
  sourceUrl?: string;
};

export type LearningStoryProfile = {
  premise: string;
  chapterWordCount: number;
  createdAt: number;
};

export type LearningStoryCharacter = {
  name: string;
  role: string;
  traits: string;
  currentState: string;
};

export type LearningStoryMemory = {
  storyId: string;
  title: string;
  genre: string;
  premise: string;
  worldRules: string[];
  characters: LearningStoryCharacter[];
  timeline: string[];
  openThreads: string[];
  chapterNumber: number;
  latestSummary: string;
  nextHook: string;
  updatedAt: number;
};

export type LearningStoryChapter = {
  storyId: string;
  storyTitle: string;
  chapterNumber: number;
  chapterTitle: string;
  previousSummary: string;
  chapterSummary: string;
  nextHook: string;
};

export type LearningPack = {
  id: string;
  date: string;
  title: string;
  theme: string;
  level: string;
  estimatedMinutes: number;
  originalText: string;
  translation?: string;
  sourceLabel: string;
  sourceUrl?: string;
  license?: string;
  audio?: LearningAudio;
  audioNote: 'original' | 'system-tts';
  vocabulary: LearningVocabulary[];
  tasks: LearningTask[];
  generatedBy: 'ai';
  story: LearningStoryChapter;
  createdAt: number;
};

export type GeneratedLearningPack = {
  pack: LearningPack;
  storyMemory: LearningStoryMemory;
};

export type PrefetchedLearningStory = GeneratedLearningPack & {
  sourcePackId: string;
  preparedAt: number;
};

export type LearningPlanDay = {
  date: string;
  theme: string;
  focus: string;
  practicePattern: string;
  minutes: number;
};

export type LearningPlan = {
  dailyMinutes: number;
  themeSetIndex: number;
  createdAt: number;
  days: LearningPlanDay[];
};

export type LearningReviewCard = {
  id: string;
  term: string;
  meaning: string;
  example: string;
  dueAt: string;
  intervalDays: number;
  repetitions: number;
};

export type LearningState = {
  plan: LearningPlan;
  packs: Record<string, LearningPack>;
  completedPackIds: string[];
  completedTaskIds: string[];
  taskResponses: Record<string, string>;
  reviewCards: LearningReviewCard[];
  selectedModelId?: string;
  storyProfile: LearningStoryProfile;
  storyMemory?: LearningStoryMemory;
  storyMemoryHistory: LearningStoryMemory[];
  prefetchedStory?: PrefetchedLearningStory;
};
