import type { ProviderProfile } from '../ai/providerProfile';
import { assertSuccessfulResponse, fetchWithTimeout, ModelConnectionError, ModelRequestError } from '../ai/modelRequest';
import { addDays, todayKey } from './learningStore';
import type { LearningPack, LearningTask, LearningVocabulary } from './learningTypes';

const LLM_KINDS = ['openai-compatible', 'openai-responses', 'anthropic-messages'] as const;

export const isLearningModel = (profile: ProviderProfile | undefined): profile is ProviderProfile => Boolean(profile && LLM_KINDS.includes(profile.kind as typeof LLM_KINDS[number]) && profile.enabled);

const sourceText = `On my way to work, I often stop at a small coffee shop near the station. The barista knows my usual order, so she smiles and asks, “The usual?” I usually say yes, but today I tried something different. It was a small change, but it made the morning feel new.`;

const taskTemplates: LearningTask[] = [
  { id: 'review', kind: 'review', title: '回忆旧表达', instruction: '先在脑中回想昨天学过的表达，再打开答案核对。', minutes: 3 },
  { id: 'listen', kind: 'listen', title: '先听后看', instruction: '先不看文本听一遍，捕捉人物、地点和发生的变化。', minutes: 4 },
  { id: 'read', kind: 'read', title: '精读原文', instruction: '阅读英文原文，注意重点词块在句子中的用法。', minutes: 5 },
  { id: 'speak', kind: 'speak', title: '跟读与替换', instruction: '用系统朗读逐句播放，跟读后把 coffee shop 替换成自己的真实场景。', minutes: 5 },
  { id: 'recall', kind: 'recall', title: '主动输出', instruction: '不用看中文，尝试用英语复述“今天早晨做了什么”。', minutes: 3 },
  { id: 'write', kind: 'write', title: '短句改写', instruction: '写下两句自己的英文：一句描述习惯，一句描述今天尝试的新变化。', minutes: 5 },
];

const topics = [
  { title: '让早晨变得新鲜', theme: 'Small talk at work', translation: '上班路上，我经常会在车站附近的一家小咖啡店停一下。咖啡师知道我平时点什么，所以她笑着问：“还是老样子吗？”我通常会说是，但今天我尝试了点不一样的。这只是一个小小的改变，却让这个早晨有了新鲜感。' },
  { title: '约定一个合适的时间', theme: 'Making plans', translation: '和同事约时间时，清楚地说出你什么时候有空，也给对方一个容易回应的选择。简短、具体的表达通常比反复确认更有效。' },
  { title: '把问题说清楚', theme: 'Explaining a problem', translation: '遇到问题时，先说明发生了什么、影响是什么，再提出你需要的帮助。这样别人更容易迅速理解并给出回应。' },
];

const selectTasks = (dailyMinutes: number, packId: string): LearningTask[] => {
  const selected: LearningTask[] = [];
  let remaining = Math.max(5, dailyMinutes);
  for (const task of taskTemplates) {
    if (selected.length === 0 || remaining >= task.minutes) {
      selected.push({ ...task, id: `${packId}:${task.id}` });
      remaining -= task.minutes;
    }
  }
  return selected;
};

export const createCuratedPack = (date: string, dailyMinutes: number): LearningPack => {
  const topic = topics[Math.abs([...date].reduce((sum, character) => sum + character.charCodeAt(0), 0)) % topics.length];
  const id = `pack-${date}`;
  const vocabulary: LearningVocabulary[] = [
    { term: 'the usual', meaning: '老样子；平时固定点的东西', example: 'Would you like the usual?', dueAt: addDays(date, 1), intervalDays: 1, repetitions: 0 },
    { term: 'try something different', meaning: '尝试一点不一样的东西', example: 'I decided to try something different today.', dueAt: addDays(date, 1), intervalDays: 1, repetitions: 0 },
    { term: 'make ... feel new', meaning: '让……感觉焕然一新', example: 'A short walk can make the morning feel new.', dueAt: addDays(date, 1), intervalDays: 1, repetitions: 0 },
  ];
  const tasks = selectTasks(dailyMinutes, id);
  return {
    id,
    date,
    title: topic.title,
    theme: topic.theme,
    level: '可理解输入 · 基础进阶',
    estimatedMinutes: tasks.reduce((sum, task) => sum + task.minutes, 0),
    originalText: sourceText,
    translation: topic.translation,
    sourceLabel: 'AirRead 练习样例',
    license: '当前为本地练习内容，不含原版录音。',
    audioNote: 'system-tts',
    vocabulary,
    tasks,
    generatedBy: 'curated',
    createdAt: Date.now(),
  };
};

const learningPrompt = (dailyMinutes: number, date: string): string => `你是面向中国成年英语学习者的课程设计师。学习目标固定为：能与英语母语者自然交流、听懂日常英语、阅读常见英文内容，并逐步适应英语考试。用户每天只有 ${dailyMinutes} 分钟。请设计 ${date} 的一份英语学习包。

必须遵循：可理解输入、主动回忆、间隔重复、词块学习、听读说交错训练。不要把 TTS 当作原版音频；本次内容不提供外部音频 URL。

只返回 JSON，不要 Markdown。JSON 格式：
{
  "title":"中文标题",
  "theme":"英文主题",
  "level":"难度说明",
  "originalText":"120 到 220 词自然英文短文或对话",
  "translation":"自然中文译文",
  "vocabulary":[{"term":"英文词块","meaning":"中文释义","example":"英文例句"}],
  "tasks":[{"kind":"listen|read|speak|recall|write","title":"中文任务名","instruction":"具体中文操作提示","minutes":数字}]
}
词汇不超过 6 个，任务总时长不超过 ${dailyMinutes} 分钟。`;

const stripCodeFence = (value: string): string => value.trim().replace(/^```(?:json)?\s*/iu, '').replace(/\s*```$/u, '');

const parsePack = (value: string, date: string, dailyMinutes: number): LearningPack => {
  const parsed = JSON.parse(stripCodeFence(value)) as Partial<LearningPack>;
  if (!parsed.title || !parsed.theme || !parsed.originalText || !parsed.translation || !Array.isArray(parsed.vocabulary) || !Array.isArray(parsed.tasks)) {
    throw new Error('模型返回的学习包不完整');
  }
  const id = `pack-${date}`;
  const vocabulary = parsed.vocabulary.slice(0, 6).map((item, index) => {
    const candidate = item as Partial<LearningVocabulary>;
    if (!candidate.term || !candidate.meaning || !candidate.example) throw new Error(`第 ${index + 1} 个词块不完整`);
    return { term: candidate.term, meaning: candidate.meaning, example: candidate.example, dueAt: addDays(date, 1), intervalDays: 1, repetitions: 0 };
  });
  const normalizedTasks = parsed.tasks.map((item, index) => {
    const candidate = item as Partial<LearningTask>;
    if (!candidate.kind || !candidate.title || !candidate.instruction || typeof candidate.minutes !== 'number') throw new Error(`第 ${index + 1} 个学习任务不完整`);
    if (!['listen', 'read', 'speak', 'recall', 'review', 'write'].includes(candidate.kind)) throw new Error('模型返回了不支持的学习任务');
    return { id: `${id}:ai-${index}`, kind: candidate.kind, title: candidate.title, instruction: candidate.instruction, minutes: Math.max(1, Math.min(dailyMinutes, Math.round(candidate.minutes))) };
  });
  const tasks: LearningTask[] = [];
  let remainingMinutes = Math.max(5, dailyMinutes);
  normalizedTasks.forEach((task) => {
    if (tasks.length === 0 || task.minutes <= remainingMinutes) {
      tasks.push(task);
      remainingMinutes -= task.minutes;
    }
  });
  if (tasks.length === 0) throw new Error('模型没有返回可执行的学习任务');
  return {
    id,
    date,
    title: parsed.title,
    theme: parsed.theme,
    level: parsed.level || '个性化学习包',
    estimatedMinutes: tasks.reduce((sum, task) => sum + task.minutes, 0),
    originalText: parsed.originalText,
    translation: parsed.translation,
    sourceLabel: 'AI 生成练习内容',
    license: '无原版录音，可使用系统朗读辅助学习。',
    audioNote: 'system-tts',
    vocabulary,
    tasks,
    generatedBy: 'ai',
    createdAt: Date.now(),
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
      response = await fetchWithTimeout(endpoint(profile), { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${profile.apiKey}` }, body: JSON.stringify({ model: profile.model, temperature: 0.4, messages: [{ role: 'user', content: prompt }] }) }, 40_000);
    } else if (profile.kind === 'openai-responses') {
      response = await fetchWithTimeout(endpoint(profile), { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${profile.apiKey}` }, body: JSON.stringify({ model: profile.model, temperature: 0.4, input: prompt }) }, 40_000);
    } else {
      response = await fetchWithTimeout(endpoint(profile), { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-api-key': profile.apiKey!, 'anthropic-version': '2023-06-01', 'anthropic-dangerous-direct-browser-access': 'true' }, body: JSON.stringify({ model: profile.model, max_tokens: 2_800, temperature: 0.4, messages: [{ role: 'user', content: prompt }] }) }, 40_000);
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

export const generateLearningPack = async (profile: ProviderProfile | undefined, dailyMinutes: number, date = todayKey()): Promise<LearningPack> => {
  if (!isLearningModel(profile)) return createCuratedPack(date, dailyMinutes);
  const prompt = profile.prompt?.trim() ? `${profile.prompt.trim()}\n\n${learningPrompt(dailyMinutes, date)}` : learningPrompt(dailyMinutes, date);
  const response = await readModelText(profile, prompt);
  return parsePack(response, date, dailyMinutes);
};
