export type LearningTaskKind = 'review' | 'listen' | 'read' | 'speak' | 'recall' | 'write';

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
  answer?: string;
};

export type LearningAudio = {
  url: string;
  label: string;
  language: string;
  accent?: string;
  license?: string;
  sourceUrl?: string;
};

export type LearningPack = {
  id: string;
  date: string;
  title: string;
  theme: string;
  level: string;
  estimatedMinutes: number;
  originalText: string;
  translation: string;
  sourceLabel: string;
  sourceUrl?: string;
  license?: string;
  audio?: LearningAudio;
  audioNote: 'original' | 'system-tts';
  vocabulary: LearningVocabulary[];
  tasks: LearningTask[];
  generatedBy: 'curated' | 'ai';
  createdAt: number;
};

export type LearningPlanDay = {
  date: string;
  theme: string;
  focus: string;
  minutes: number;
};

export type LearningPlan = {
  dailyMinutes: number;
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
  reviewCards: LearningReviewCard[];
  selectedModelId?: string;
};
