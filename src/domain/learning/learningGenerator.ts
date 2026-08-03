import type { ProviderProfile } from '../ai/providerProfile';
import { assertSuccessfulResponse, fetchWithTimeout, ModelConnectionError, ModelRequestError } from '../ai/modelRequest';
import { addDays, clampDailyMinutes, todayKey } from './learningStore';
import type { OpenLearningMaterial } from './openContent';
import type { LearningPack, LearningPlanDay, LearningTask, LearningTaskKind, LearningVocabulary } from './learningTypes';
import { buildTaskExercise } from './taskExercises';

const LLM_KINDS = ['openai-compatible', 'openai-responses', 'anthropic-messages'] as const;

export const isLearningModel = (profile: ProviderProfile | undefined): profile is ProviderProfile => Boolean(profile && LLM_KINDS.includes(profile.kind as typeof LLM_KINDS[number]) && profile.enabled);

const taskTemplates: LearningTask[] = [
  { id: 'review', kind: 'review', title: '回忆旧表达', instruction: '先在脑中回想昨天学过的表达，再打开答案核对。', minutes: 3 },
  { id: 'listen', kind: 'listen', title: '先听后看', instruction: '先不看文本听一遍，捕捉人物、地点和发生的变化。', minutes: 4 },
  { id: 'read', kind: 'read', title: '精读原文', instruction: '阅读英文原文，注意重点词块在句子中的用法。', minutes: 5 },
  { id: 'speak', kind: 'speak', title: '跟读与替换', instruction: '用系统朗读逐句播放，跟读后把其中一句替换成自己的真实场景。', minutes: 5 },
  { id: 'recall', kind: 'recall', title: '主动输出', instruction: '不用看中文，尝试用英语复述原文的核心信息。', minutes: 3 },
  { id: 'write', kind: 'write', title: '短句改写', instruction: '写下两句自己的英文，使用今天材料中的一个表达。', minutes: 5 },
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

const addExercises = (tasks: LearningTask[], text: string): LearningTask[] => tasks.map((task) => ({ ...task, exercise: buildTaskExercise(task.kind, text, task.id) }));

export const createOpenLearningPack = (date: string, dailyMinutes: number, material: OpenLearningMaterial, planDay?: Pick<LearningPlanDay, 'theme'>): LearningPack => {
  const id = `pack-${date}`;
  const tasks = addExercises(selectTasks(dailyMinutes, id), material.text);
  return {
    id,
    date,
    title: material.title,
    theme: planDay?.theme ?? '开放英语材料',
    level: '可理解输入 · 基础进阶',
    estimatedMinutes: tasks.reduce((sum, task) => sum + task.minutes, 0),
    originalText: material.text,
    sourceLabel: material.sourceLabel,
    sourceUrl: material.sourceUrl,
    license: material.license,
    audioNote: 'system-tts',
    vocabulary: [],
    tasks,
    generatedBy: 'public',
    createdAt: Date.now(),
  };
};

const learningPrompt = (dailyMinutes: number, date: string, planDay?: Pick<LearningPlanDay, 'theme' | 'focus'>): string => `你是面向中国成年英语学习者的课程设计师。学习目标固定为：能与英语母语者自然交流、听懂日常英语、阅读常见英文内容，并逐步适应英语考试。用户每天只有 ${dailyMinutes} 分钟。请设计 ${date} 的一份英语学习包。

本日计划主题是“${planDay?.theme ?? '真实生活英语'}”，训练重点是“${planDay?.focus ?? '听懂并使用自然表达'}”。内容应优先围绕这个主题，不要为了凑时长堆砌无关练习。

必须遵循：可理解输入、主动回忆、间隔重复、词块学习、听读说交错训练。不要把 TTS 当作原版音频；本次内容不提供外部音频 URL。

只返回 JSON，不要 Markdown。JSON 格式：
{
  "title":"中文标题",
  "theme":"英文主题",
  "level":"难度说明",
  "originalText":"120 到 220 词自然英文短文或对话",
  "translation":"自然中文译文",
  "vocabulary":[{"term":"英文词块","meaning":"中文释义","example":"英文例句"}],
  "sourceLabel":"可核验的开放来源名称；AI 自己写的内容请留空",
  "sourceUrl":"可核验的 HTTPS 来源链接；无法确认时留空",
  "license":"来源授权信息；无法确认时留空",
  "audio":{"url":"可核验的 HTTPS 原版录音链接","label":"录音名称","language":"en-US","accent":"口音","license":"录音授权","sourceUrl":"录音来源链接"},
  "tasks":[{"kind":"listen|read|speak|recall|write","title":"中文任务名","instruction":"具体中文操作提示","minutes":数字}]
}
词汇不超过 6 个，任务总时长不超过 ${dailyMinutes} 分钟。不要猜测来源或音频链接；无法确认时省略 source 和 audio。`;

const stripCodeFence = (value: string): string => value.trim().replace(/^```(?:json)?\s*/iu, '').replace(/\s*```$/u, '');

const safeHttpsUrl = (value: unknown): string | undefined => {
  if (typeof value !== 'string' || !value.trim()) return undefined;
  try {
    const url = new URL(value.trim());
    return url.protocol === 'https:' ? url.toString() : undefined;
  } catch {
    return undefined;
  }
};

const normalizeAudio = (value: unknown): LearningPack['audio'] | undefined => {
  if (!value || typeof value !== 'object') return undefined;
  const candidate = value as Partial<NonNullable<LearningPack['audio']>>;
  const url = safeHttpsUrl(candidate.url);
  const sourceUrl = safeHttpsUrl(candidate.sourceUrl);
  if (!url || !sourceUrl || typeof candidate.label !== 'string' || !candidate.label.trim() || typeof candidate.language !== 'string' || !candidate.language.trim() || typeof candidate.license !== 'string' || !candidate.license.trim()) return undefined;
  return {
    url,
    sourceUrl,
    label: candidate.label.trim(),
    language: candidate.language.trim(),
    accent: typeof candidate.accent === 'string' && candidate.accent.trim() ? candidate.accent.trim() : undefined,
    license: candidate.license.trim(),
  };
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
      instruction: '用今天的词块，再用英语复述一个自己的真实经历；尽量不要看中文提示。',
      minutes: remaining,
    });
  }
  return selected;
};

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
  const tasks = addExercises(fitGeneratedTasks(normalizedTasks, dailyMinutes, id), parsed.originalText);
  if (tasks.length === 0) throw new Error('模型没有返回可执行的学习任务');
  const sourceUrl = safeHttpsUrl(parsed.sourceUrl);
  const audio = normalizeAudio(parsed.audio);
  const sourceLabel = sourceUrl && typeof parsed.sourceLabel === 'string' && parsed.sourceLabel.trim() ? parsed.sourceLabel.trim() : 'AI 生成练习内容';
  const license = sourceUrl && typeof parsed.license === 'string' && parsed.license.trim() ? parsed.license.trim() : 'AI 生成内容；未提供可核验的开放授权。';
  return {
    id,
    date,
    title: parsed.title,
    theme: parsed.theme,
    level: parsed.level || '个性化学习包',
    estimatedMinutes: tasks.reduce((sum, task) => sum + task.minutes, 0),
    originalText: parsed.originalText,
    translation: parsed.translation,
    sourceLabel,
    sourceUrl,
    license,
    audio,
    audioNote: audio ? 'original' : 'system-tts',
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

export const generateLearningPack = async (profile: ProviderProfile | undefined, dailyMinutes: number, date = todayKey(), planDay?: Pick<LearningPlanDay, 'theme' | 'focus'>, material?: OpenLearningMaterial): Promise<LearningPack> => {
  const normalizedMinutes = clampDailyMinutes(dailyMinutes);
  if (!isLearningModel(profile)) {
    if (!material) throw new Error('没有可用的开放学习资料');
    return createOpenLearningPack(date, normalizedMinutes, material, planDay);
  }
  const prompt = profile.prompt?.trim() ? `${profile.prompt.trim()}\n\n${learningPrompt(normalizedMinutes, date, planDay)}` : learningPrompt(normalizedMinutes, date, planDay);
  const response = await readModelText(profile, prompt);
  return parsePack(response, date, normalizedMinutes);
};
