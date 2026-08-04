import { buildTaskExercise } from '../domain/learning/taskExercises';
import type { LearningPack, LearningStoryMemory, LearningTask, LearningTaskKind } from '../domain/learning/learningTypes';

export const createStoryMemoryFixture = (overrides: Partial<LearningStoryMemory> = {}): LearningStoryMemory => ({
  storyId: 'story-fixture',
  title: 'The Signal Beyond Platform Seven',
  genre: 'Urban mystery',
  premise: 'A commuter receives English voice notes that arrive one day early.',
  worldRules: ['The future voice notes can only describe one small event each day.'],
  characters: [{ name: 'Mia Chen', role: 'Main character', traits: 'Careful but curious', currentState: 'She has kept the first message secret.' }],
  timeline: ['Chapter 1: Mia receives the first voice note at Platform Seven.'],
  openThreads: ['Who is sending the notes and why do they arrive early?'],
  chapterNumber: 1,
  latestSummary: 'Mia receives a voice note that warns her about a stranger at Platform Seven.',
  nextHook: 'The next message contains the stranger’s name.',
  updatedAt: 1_754_000_000_000,
  ...overrides,
});

const text = 'Mia waited at Platform Seven after work. Her phone played an English voice note from tomorrow. The message told her to watch a man with a silver umbrella. She looked across the station and saw him near the exit. Instead of leaving, Mia followed him into a quiet tunnel.';

export const createStoryPackFixture = (date = '2026-08-03', dailyMinutes = 15): LearningPack => {
  const id = `pack-${date}`;
  const vocabulary = [{ term: 'watch out for', meaning: '留意，警惕', example: 'Watch out for the wet floor.', dueAt: '2026-08-04', intervalDays: 1, repetitions: 0 }];
  const kinds: LearningTaskKind[] = dailyMinutes >= 25 ? ['listen', 'read', 'speak', 'recall', 'write'] : ['listen', 'read', 'speak', 'recall'];
  const tasks: LearningTask[] = kinds.map((kind, index) => {
    const taskId = `${id}:${kind}`;
    return {
      id: taskId,
      kind,
      title: kind === 'listen' ? '先听一遍' : kind === 'read' ? '精读章节' : kind === 'speak' ? '跟读一句' : kind === 'recall' ? '复述线索' : '写下推测',
      instruction: '围绕今天的故事章节完成练习。',
      minutes: Math.max(2, Math.floor(dailyMinutes / kinds.length)),
      exercise: buildTaskExercise(kind, text, taskId, { sentenceIndex: index, vocabulary }),
    };
  });
  return {
    id,
    date,
    title: '站台上的明日语音',
    theme: 'An unexpected message',
    level: '原创连载 · 个性化学习包',
    estimatedMinutes: dailyMinutes,
    originalText: text,
    translation: '下班后，米娅在七号站台等车。她的手机播放了一段来自明天的英文语音，提醒她留意一个拿银色雨伞的男人。她在出口附近看到了他，没有离开，而是跟进了一条安静的通道。',
    sourceLabel: 'AI 原创连载',
    license: 'AI 原创内容，仅供个人英语学习；暂无原版录音。',
    audioNote: 'system-tts',
    vocabulary,
    tasks,
    generatedBy: 'ai',
    story: {
      storyId: 'story-fixture',
      storyTitle: 'The Signal Beyond Platform Seven',
      chapterNumber: 1,
      chapterTitle: 'The Silver Umbrella',
      previousSummary: '这是故事的开端。',
      chapterSummary: '米娅收到了来自明天的语音，并跟随银伞男子走进通道。',
      nextHook: '通道尽头的门后传来和语音里一样的声音。',
    },
    createdAt: 1_754_000_000_000,
  };
};
