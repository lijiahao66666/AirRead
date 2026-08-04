import type { ProviderProfile } from '../ai/providerProfile';
import { assertSuccessfulResponse, fetchWithTimeout, ModelConnectionError, ModelRequestError } from '../ai/modelRequest';
import { addDays, clampDailyMinutes, todayKey } from './learningStore';
import type { GeneratedLearningPack, LearningPack, LearningPlanDay, LearningStoryCharacter, LearningStoryMemory, LearningStoryProfile, LearningTask, LearningTaskExercise, LearningTaskKind, LearningVocabulary } from './learningTypes';
import { buildTaskExercise } from './taskExercises';

const LLM_KINDS = ['openai-compatible', 'openai-responses', 'anthropic-messages'] as const;
const MAX_MEMORY_ITEMS = 10;
const MAX_MEMORY_TEXT = 420;

export const isLearningModel = (profile: ProviderProfile | undefined): profile is ProviderProfile => Boolean(profile && LLM_KINDS.includes(profile.kind as typeof LLM_KINDS[number]) && profile.enabled);

const taskTemplates: LearningTask[] = [
  { id: 'review', kind: 'review', title: '回忆旧表达', instruction: '先在脑中回想昨天学过的表达，再打开答案核对。', minutes: 3 },
  { id: 'listen', kind: 'listen', title: '先听后看', instruction: '先不看文本听一遍，捕捉人物、地点和发生的变化。', minutes: 4 },
  { id: 'read', kind: 'read', title: '精读原文', instruction: '阅读英文原文，注意重点词块在句子中的用法。', minutes: 5 },
  { id: 'speak', kind: 'speak', title: '跟读与替换', instruction: '用系统朗读逐句播放，跟读后把其中一句替换成自己的真实场景。', minutes: 5 },
  { id: 'recall', kind: 'recall', title: '主动输出', instruction: '不用看中文，尝试用英语复述本章发生的变化。', minutes: 3 },
  { id: 'write', kind: 'write', title: '短句改写', instruction: '写下两句自己的英文，使用今天章节中的一个表达。', minutes: 5 },
];

const sessionPhases = (dailyMinutes: number): LearningTaskKind[] => {
  if (dailyMinutes <= 7) return ['listen', 'recall'];
  if (dailyMinutes <= 11) return ['review', 'listen', 'speak'];
  if (dailyMinutes <= 17) return ['review', 'listen', 'read', 'speak'];
  if (dailyMinutes <= 23) return ['review', 'listen', 'read', 'speak', 'recall'];
  return ['review', 'listen', 'read', 'speak', 'recall', 'write'];
};

const allocateSessionMinutes = (dailyMinutes: number, phaseCount: number): number[] => {
  const target = Math.max(5, Math.round(dailyMinutes));
  const minutes = Array.from({ length: phaseCount }, () => 2);
  let remaining = target - minutes.reduce((sum, value) => sum + value, 0);
  let cursor = 0;
  while (remaining > 0) {
    minutes[cursor % minutes.length] += 1;
    cursor += 1;
    remaining -= 1;
  }
  return minutes;
};

const selectTasks = (dailyMinutes: number, packId: string): LearningTask[] => {
  const target = Math.max(5, Math.round(dailyMinutes));
  const phases = sessionPhases(target);
  const minutes = allocateSessionMinutes(target, phases.length);
  return phases.map((kind, index) => {
    const template = taskTemplates.find((task) => task.kind === kind)!;
    return { ...template, id: `${packId}:${template.id}`, minutes: minutes[index] };
  });
};

const addExercises = (tasks: LearningTask[], text: string, vocabulary: Pick<LearningVocabulary, 'term'>[] = []): LearningTask[] => tasks.map((task, index) => ({
  ...task,
  exercise: task.exercise ?? buildTaskExercise(task.kind, text, task.id, { sentenceIndex: index, vocabulary }),
}));

const chapterWordRange = (dailyMinutes: number): string => {
  if (dailyMinutes <= 7) return '80 到 110 词';
  if (dailyMinutes <= 11) return '100 到 145 词';
  if (dailyMinutes <= 17) return '145 到 210 词';
  if (dailyMinutes <= 23) return '210 到 290 词';
  if (dailyMinutes <= 35) return '290 到 390 词';
  return `${Math.min(620, 390 + Math.round((dailyMinutes - 35) * 3))} 到 ${Math.min(760, 470 + Math.round((dailyMinutes - 35) * 4))} 词`;
};

const compactText = (value: unknown, fallback = '', maxLength = MAX_MEMORY_TEXT): string => {
  if (typeof value !== 'string') return fallback;
  const normalized = value.replace(/\s+/gu, ' ').trim();
  return normalized ? normalized.slice(0, maxLength) : fallback;
};

const compactList = (value: unknown, fallback: string[] = [], limit = MAX_MEMORY_ITEMS): string[] => {
  if (!Array.isArray(value)) return fallback.slice(-limit);
  const items = value.map((item) => compactText(item, '')).filter(Boolean);
  return [...new Set(items)].slice(-limit);
};

const normalizeCharacters = (value: unknown, fallback: LearningStoryCharacter[] = []): LearningStoryCharacter[] => {
  if (!Array.isArray(value)) return fallback.slice(0, MAX_MEMORY_ITEMS);
  const characters = value.flatMap((item) => {
    if (!item || typeof item !== 'object') return [];
    const candidate = item as Partial<LearningStoryCharacter>;
    const name = compactText(candidate.name, '', 80);
    if (!name) return [];
    return [{
      name,
      role: compactText(candidate.role, '重要人物', 140),
      traits: compactText(candidate.traits, '待后续展开', 200),
      currentState: compactText(candidate.currentState, '待后续展开', 260),
    }];
  });
  return characters.slice(0, MAX_MEMORY_ITEMS);
};

const storyContext = (profile: LearningStoryProfile, storyMemory?: LearningStoryMemory): string => {
  if (!storyMemory) {
    return `这是第一章。用户可选设定：${profile.premise || '未提供；请自行选择一个有悬念、有人物成长空间、适合长期连载的原创题材。'}\n请在本章建立清晰主角、目标、冲突和可延续的谜团。`;
  }
  const characters = storyMemory.characters.map((character) => `- ${character.name}｜${character.role}｜特征：${character.traits}｜当前：${character.currentState}`).join('\n') || '暂无人物卡，请在不矛盾的前提下补齐。';
  const timeline = storyMemory.timeline.map((item) => `- ${item}`).join('\n') || '暂无时间线。';
  const openThreads = storyMemory.openThreads.map((item) => `- ${item}`).join('\n') || '暂无未解线索。';
  return `这是第 ${storyMemory.chapterNumber + 1} 章。不要重写、推翻或遗忘下列既定事实。\n\n故事圣经\n- 书名：${storyMemory.title}\n- 类型：${storyMemory.genre}\n- 核心设定：${storyMemory.premise}\n- 世界规则：${storyMemory.worldRules.map((item) => `「${item}」`).join('；')}\n\n人物卡\n${characters}\n\n压缩时间线\n${timeline}\n\n未解线索\n${openThreads}\n\n上一章回顾\n${storyMemory.latestSummary}\n\n上一章结尾钩子\n${storyMemory.nextHook}\n\n本章必须承接上述钩子，推进至少一个既有线索；若新增人物、规则或事件，必须写入本章后的记忆更新。`;
};

const learningPrompt = (dailyMinutes: number, date: string, storyProfile: LearningStoryProfile, storyMemory?: LearningStoryMemory, planDay?: Pick<LearningPlanDay, 'theme' | 'focus'>): string => `你是面向中国成年英语学习者的原创英文连载作者和课程设计师。学习目标固定为：能与英语母语者自然交流、听懂日常英语、阅读常见英文内容，并逐步适应英语考试。用户每天只有 ${dailyMinutes} 分钟。请生成 ${date} 的下一章原创英文连载及其配套训练。

本日训练重点是“${planDay?.focus ?? '理解情节并使用自然表达'}”。章节英文正文应为 ${chapterWordRange(dailyMinutes)}，难度自然、可理解、故事性强，避免教材腔。人物、故事、场景和情节必须原创；不得模仿、翻译、续写或借用任何现有小说、影视、游戏或作者的受保护角色与情节。

长篇连载规则：完整正文不会提供给下一章；你只能依赖下面的压缩长期记忆。因此每章结束后必须更新故事圣经、人物卡、时间线和未解线索。只保留稳定、可验证的事实，禁止编造与正文不一致的记忆。时间线不超过 10 条，人物卡不超过 10 人，世界规则不超过 8 条，未解线索不超过 10 条。不要把系统 TTS 写成原版音频，也不要提供来源或音频链接。

${storyContext(storyProfile, storyMemory)}

只返回 JSON，不要 Markdown。JSON 格式：
{
  "title":"学习包中文标题",
  "theme":"本章英文主题",
  "level":"难度说明",
  "originalText":"本章自然英文正文",
  "translation":"本章完整自然中文译文",
  "vocabulary":[{"term":"英文词块","meaning":"中文释义","example":"英文例句"}],
  "story":{
    "title":"原创连载书名",
    "genre":"题材",
    "premise":"一句话核心设定",
    "worldRules":["稳定世界规则"],
    "characters":[{"name":"人物姓名","role":"身份或作用","traits":"稳定性格/关系","currentState":"本章结束时状态"}],
    "timeline":["截至本章的关键剧情节点"],
    "openThreads":["尚未解开的冲突或线索"],
    "chapterTitle":"本章英文标题",
    "chapterSummary":"中文前情回顾/本章概要，准确说明发生的推进",
    "nextHook":"中文下一章钩子"
  },
  "tasks":[{"kind":"listen|read|speak|recall|write","title":"中文任务名","instruction":"具体中文操作提示","minutes":数字,"exercise":{"type":"listen-choice|reading-check|cloze|shadowing|word-order|free-write","prompt":"直接围绕本章原文的操作提示","text":"原文中的完整句子（仅 listen/speak）","referenceText":"写作必须引用的原文句子","choices":["至少 3 个选项（listen/read 使用）"],"answer":"原文中的答案","minimumWords":10}}]
}
词块不超过 6 个，任务总时长不超过 ${dailyMinutes} 分钟。每个任务必须围绕 originalText 的不同句子或 vocabulary 中的词块；不要把多个任务写成泛泛的“完成练习”。exercise 必须可直接在手机上完成：listen-choice 提供 3 个不同选项，reading-check 提供一个关于本章具体事件的理解问题和 3 个选项，cloze 的答案来自原文或词块，shadowing 的 text 必须是原文句子，word-order 的 choices 必须能还原原文句子，free-write 必须提供 referenceText 原文锚点句，并要求使用今日词块或复述本章事件。`;

const stripCodeFence = (value: string): string => value.trim().replace(/^```(?:json)?\s*/iu, '').replace(/\s*```$/u, '');

const exerciseTypes = new Set<LearningTaskExercise['type']>(['listen-choice', 'reading-check', 'cloze', 'shadowing', 'word-order', 'free-write']);

const normalizedWords = (value: string): string[] => value.toLowerCase().match(/[a-z]+(?:'[a-z]+)?/gu) ?? [];

const hasTextOverlap = (candidate: string, source: string): boolean => {
  const sourceWords = new Set(normalizedWords(source));
  const candidateWords = normalizedWords(candidate);
  if (candidateWords.length === 0) return false;
  const overlap = candidateWords.filter((word) => sourceWords.has(word)).length;
  return overlap >= Math.min(3, candidateWords.length);
};

const normalizeGeneratedExercise = (value: unknown, kind: LearningTaskKind, source: string, vocabulary: Pick<LearningVocabulary, 'term'>[]): LearningTaskExercise | undefined => {
  if (!value || typeof value !== 'object') return undefined;
  const candidate = value as Partial<LearningTaskExercise>;
  if (typeof candidate.type !== 'string' || !exerciseTypes.has(candidate.type as LearningTaskExercise['type']) || typeof candidate.prompt !== 'string' || !candidate.prompt.trim()) return undefined;
  const prompt = candidate.prompt.trim();
  const expectedType: Partial<Record<LearningTaskKind, LearningTaskExercise['type']>> = {
    listen: 'listen-choice', read: 'reading-check', speak: 'shadowing', recall: 'word-order', write: 'free-write',
  };
  if (expectedType[kind] !== candidate.type) return undefined;
  if (candidate.type === 'listen-choice') {
    if (typeof candidate.text !== 'string' || !hasTextOverlap(candidate.text, source) || typeof candidate.answer !== 'string') return undefined;
    const choices = Array.isArray(candidate.choices) ? candidate.choices.filter((item): item is string => typeof item === 'string' && Boolean(item.trim())).map((item) => item.trim()) : [];
    if (choices.length < 3 || new Set(choices).size !== choices.length || !choices.includes(candidate.answer)) return undefined;
    return { type: candidate.type, prompt, text: candidate.text.trim(), choices, answer: candidate.answer };
  }
  if (candidate.type === 'reading-check') {
    if (typeof candidate.answer !== 'string' || !hasTextOverlap(candidate.answer, source)) return undefined;
    const choices = Array.isArray(candidate.choices) ? candidate.choices.filter((item): item is string => typeof item === 'string' && Boolean(item.trim())).map((item) => item.trim()) : [];
    if (choices.length < 3 || new Set(choices).size !== choices.length || !choices.includes(candidate.answer)) return undefined;
    return { type: candidate.type, prompt, choices, answer: candidate.answer };
  }
  if (candidate.type === 'cloze') {
    if (typeof candidate.answer !== 'string' || !candidate.answer.trim()) return undefined;
    const answer = candidate.answer.trim();
    if (!hasTextOverlap(answer, source) && !vocabulary.some((item) => item.term.trim().toLowerCase() === answer.toLowerCase())) return undefined;
    return { type: candidate.type, prompt, answer };
  }
  if (candidate.type === 'shadowing') {
    if (typeof candidate.text !== 'string' || !hasTextOverlap(candidate.text, source)) return undefined;
    return { type: candidate.type, prompt, text: candidate.text.trim() };
  }
  if (candidate.type === 'word-order') {
    if (typeof candidate.answer !== 'string' || !hasTextOverlap(candidate.answer, source)) return undefined;
    const choices = Array.isArray(candidate.choices) ? candidate.choices.filter((item): item is string => typeof item === 'string' && Boolean(item.trim())).map((item) => item.trim()) : [];
    if (choices.length < 4 || new Set(choices).size !== choices.length) return undefined;
    return { type: candidate.type, prompt, choices, answer: candidate.answer.trim() };
  }
  const minimumWords = typeof candidate.minimumWords === 'number' && Number.isFinite(candidate.minimumWords) ? Math.max(5, Math.min(80, Math.round(candidate.minimumWords))) : 10;
  const promptMentionsMaterial = /今日|材料|原文|词块|表达|本章|故事/iu.test(prompt) || vocabulary.some((item) => Boolean(item.term) && prompt.toLowerCase().includes(item.term.toLowerCase()));
  if (!promptMentionsMaterial || typeof candidate.referenceText !== 'string' || !hasTextOverlap(candidate.referenceText, source)) return undefined;
  return { type: candidate.type, prompt, referenceText: candidate.referenceText.trim(), minimumWords };
};

const fitGeneratedTasks = (tasks: LearningTask[], dailyMinutes: number, packId: string): LearningTask[] => {
  const target = Math.max(5, Math.round(dailyMinutes));
  const selected: LearningTask[] = [];
  let remaining = target;
  for (const task of tasks) {
    if (remaining <= 0) break;
    const minutes = Math.min(Math.max(1, Math.round(task.minutes)), remaining);
    selected.push({ ...task, minutes });
    remaining -= minutes;
  }
  if (selected.length === 0) return [];
  if (remaining > 0) {
    selected.push({
      id: `${packId}:ai-extension`,
      kind: 'recall',
      title: '延伸复述',
      instruction: '用今天的词块，再用英语复述本章发生的变化；尽量不要看中文提示。',
      minutes: remaining,
    });
  }
  return selected;
};

const createStoryId = (date: string): string => {
  const suffix = typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function' ? crypto.randomUUID().slice(0, 8) : `${Date.now()}`;
  return `story-${date}-${suffix}`;
};

const normalizeStoryMemory = (value: unknown, existing: LearningStoryMemory | undefined, profile: LearningStoryProfile, date: string): { memory: LearningStoryMemory; chapter: LearningPack['story'] } => {
  if (!value || typeof value !== 'object') throw new Error('模型没有返回连载记忆');
  const candidate = value as Record<string, unknown>;
  const expectedChapterNumber = (existing?.chapterNumber ?? 0) + 1;
  const title = compactText(candidate.title, existing?.title ?? '', 100);
  const genre = compactText(candidate.genre, existing?.genre ?? '', 100);
  const premise = compactText(candidate.premise, existing?.premise || profile.premise || '一部面向英语学习的原创连载故事', 300);
  const chapterTitle = compactText(candidate.chapterTitle, '', 140);
  const chapterSummary = compactText(candidate.chapterSummary, '', 600);
  const nextHook = compactText(candidate.nextHook, '', 420);
  if (!title || !genre || !chapterTitle || !chapterSummary || !nextHook) throw new Error('模型返回的连载章节记忆不完整');
  const worldRules = compactList(candidate.worldRules, existing?.worldRules ?? [], 8);
  const characters = normalizeCharacters(candidate.characters, existing?.characters ?? []);
  if (!existing && (worldRules.length === 0 || characters.length === 0)) throw new Error('模型没有建立完整的故事设定');
  const timeline = compactList(candidate.timeline, existing?.timeline ?? [], MAX_MEMORY_ITEMS);
  const mergedTimeline = timeline.length ? timeline : [...(existing?.timeline ?? []), `第 ${expectedChapterNumber} 章：${chapterSummary}`].slice(-MAX_MEMORY_ITEMS);
  const openThreads = compactList(candidate.openThreads, existing?.openThreads ?? [], MAX_MEMORY_ITEMS);
  const mergedThreads = openThreads.length ? openThreads : [nextHook];
  const memory: LearningStoryMemory = {
    storyId: existing?.storyId ?? createStoryId(date),
    title,
    genre,
    premise,
    worldRules: worldRules.length ? worldRules : ['人物行为与世界规则必须前后一致。'],
    characters,
    timeline: mergedTimeline,
    openThreads: mergedThreads,
    chapterNumber: expectedChapterNumber,
    latestSummary: chapterSummary,
    nextHook,
    updatedAt: Date.now(),
  };
  return {
    memory,
    chapter: {
      storyId: memory.storyId,
      storyTitle: memory.title,
      chapterNumber: expectedChapterNumber,
      chapterTitle,
      previousSummary: existing?.latestSummary ?? '这是故事的开端。',
      chapterSummary,
      nextHook,
    },
  };
};

const parsePack = (value: string, date: string, dailyMinutes: number, storyProfile: LearningStoryProfile, storyMemory?: LearningStoryMemory): GeneratedLearningPack => {
  const parsed = JSON.parse(stripCodeFence(value)) as Partial<LearningPack> & { story?: unknown };
  if (!parsed.title || !parsed.theme || !parsed.originalText || !parsed.translation || !Array.isArray(parsed.vocabulary) || !Array.isArray(parsed.tasks)) {
    throw new Error('模型返回的学习包不完整');
  }
  const { memory, chapter } = normalizeStoryMemory(parsed.story, storyMemory, storyProfile, date);
  const id = `pack-${date}`;
  const originalText = parsed.originalText;
  const vocabulary = parsed.vocabulary.slice(0, 6).map((item, index) => {
    const candidate = item as Partial<LearningVocabulary>;
    if (!candidate.term || !candidate.meaning || !candidate.example) throw new Error(`第 ${index + 1} 个词块不完整`);
    return { term: candidate.term, meaning: candidate.meaning, example: candidate.example, dueAt: addDays(date, 1), intervalDays: 1, repetitions: 0 };
  });
  const normalizedTasks = parsed.tasks.map((item, index) => {
    const candidate = item as Partial<LearningTask>;
    if (!candidate.kind || !candidate.title || !candidate.instruction || typeof candidate.minutes !== 'number') throw new Error(`第 ${index + 1} 个学习任务不完整`);
    if (!['listen', 'read', 'speak', 'recall', 'review', 'write'].includes(candidate.kind)) throw new Error('模型返回了不支持的学习任务');
    const taskId = `${id}:ai-${index}`;
    const kind = candidate.kind as LearningTaskKind;
    const exercise = normalizeGeneratedExercise(candidate.exercise, kind, originalText, vocabulary);
    return { id: taskId, kind, title: candidate.title, instruction: candidate.instruction, minutes: Math.max(1, Math.min(dailyMinutes, Math.round(candidate.minutes))), ...(exercise ? { exercise } : {}) };
  });
  const tasks = addExercises(fitGeneratedTasks(normalizedTasks.length ? normalizedTasks : selectTasks(dailyMinutes, id), dailyMinutes, id), originalText, vocabulary);
  if (tasks.length === 0) throw new Error('模型没有返回可执行的学习任务');
  return {
    pack: {
      id,
      date,
      title: parsed.title,
      theme: parsed.theme,
      level: parsed.level || '原创连载 · 个性化学习包',
      estimatedMinutes: tasks.reduce((sum, task) => sum + task.minutes, 0),
      originalText,
      translation: parsed.translation,
      sourceLabel: 'AI 原创连载',
      license: 'AI 原创内容，仅供个人英语学习；暂无原版录音。',
      audioNote: 'system-tts',
      vocabulary,
      tasks,
      generatedBy: 'ai',
      story: chapter,
      createdAt: Date.now(),
    },
    storyMemory: memory,
  };
};

const endpoint = (profile: ProviderProfile): string => {
  const baseUrl = profile.baseUrl?.replace(/\/+$/u, '');
  if (profile.kind === 'anthropic-messages') return baseUrl?.endsWith('/v1/messages') ? baseUrl : `${baseUrl || 'https://api.anthropic.com'}/v1/messages`;
  if (!baseUrl) throw new Error('请先填写模型服务的 Base URL');
  if (profile.kind === 'openai-responses') return baseUrl.endsWith('/responses') ? baseUrl : `${baseUrl}/responses`;
  return baseUrl.endsWith('/chat/completions') ? baseUrl : `${baseUrl}/chat/completions`;
};

const readModelText = async (profile: ProviderProfile, prompt: string): Promise<string> => {
  let response: Response;
  try {
    if (profile.kind === 'openai-compatible') {
      response = await fetchWithTimeout(endpoint(profile), { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${profile.apiKey}` }, body: JSON.stringify({ model: profile.model, temperature: 0.45, messages: [{ role: 'user', content: prompt }] }) }, 40_000);
    } else if (profile.kind === 'openai-responses') {
      response = await fetchWithTimeout(endpoint(profile), { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${profile.apiKey}` }, body: JSON.stringify({ model: profile.model, temperature: 0.45, input: prompt }) }, 40_000);
    } else {
      response = await fetchWithTimeout(endpoint(profile), { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-api-key': profile.apiKey!, 'anthropic-version': '2023-06-01', 'anthropic-dangerous-direct-browser-access': 'true' }, body: JSON.stringify({ model: profile.model, max_tokens: 3_600, temperature: 0.45, messages: [{ role: 'user', content: prompt }] }) }, 40_000);
    }
  } catch {
    throw new ModelConnectionError(profile.name);
  }
  assertSuccessfulResponse(response, profile.name);
  const payload: unknown = await response.json();
  const output = profile.kind === 'openai-compatible'
    ? (payload as { choices?: Array<{ message?: { content?: unknown } }> }).choices?.[0]?.message?.content
    : profile.kind === 'openai-responses'
      ? (() => {
        const responsePayload = payload as { output_text?: unknown; output?: Array<{ content?: Array<{ type?: unknown; text?: unknown }> }> };
        return responsePayload.output_text ?? responsePayload.output?.flatMap((item) => item.content ?? []).find((content) => content.type === 'output_text')?.text;
      })()
      : (payload as { content?: Array<{ type?: unknown; text?: unknown }> }).content?.find((content) => content.type === 'text')?.text;
  if (typeof output === 'string' && output.trim()) return output.trim();
  throw new ModelRequestError(profile.name);
};

export const generateLearningPack = async (profile: ProviderProfile | undefined, dailyMinutes: number, date = todayKey(), planDay?: Pick<LearningPlanDay, 'theme' | 'focus'>, storyProfile: LearningStoryProfile = { premise: '', createdAt: Date.now() }, storyMemory?: LearningStoryMemory): Promise<GeneratedLearningPack> => {
  const normalizedMinutes = clampDailyMinutes(dailyMinutes);
  if (!isLearningModel(profile)) throw new Error('请先在学习设置中配置并启用一个语言模型，才能生成原创连载。');
  const prompt = profile.prompt?.trim()
    ? `${profile.prompt.trim()}\n\n${learningPrompt(normalizedMinutes, date, storyProfile, storyMemory, planDay)}`
    : learningPrompt(normalizedMinutes, date, storyProfile, storyMemory, planDay);
  const response = await readModelText(profile, prompt);
  return parsePack(response, date, normalizedMinutes, storyProfile, storyMemory);
};
