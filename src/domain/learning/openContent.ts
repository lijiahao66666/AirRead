import { fetchWithTimeout } from '../ai/modelRequest';

import type { LearningPlanDay } from './learningTypes';

export type OpenLearningMaterial = {
  title: string;
  text: string;
  sourceLabel: string;
  sourceUrl: string;
  license: string;
};

type WikiPage = {
  title?: unknown;
  extract?: unknown;
  canonicalurl?: unknown;
  fullurl?: unknown;
};

const WIKI_API = 'https://simple.wikipedia.org/w/api.php';
const WIKI_LICENSE = 'Simple English Wikipedia 文本，CC BY-SA 4.0；请保留来源链接与署名。';

type OpenTopic = {
  searchTerm: string;
  preferredTitles: string[];
};

const topicFor = (planDay?: Pick<LearningPlanDay, 'theme' | 'focus'>): OpenTopic => {
  const value = `${planDay?.theme ?? ''} ${planDay?.focus ?? ''}`.toLowerCase();
  if (value.includes('coffee') || value.includes('food')) return { searchTerm: 'Food', preferredTitles: ['Food', 'Coffee'] };
  if (value.includes('travel') || value.includes('commut') || value.includes('city') || value.includes('direction')) return { searchTerm: 'Public transport', preferredTitles: ['Public transport', 'Transport', 'Travel'] };
  if (value.includes('work') || value.includes('problem')) return { searchTerm: 'Office', preferredTitles: ['Office', 'Workplace', 'Work'] };
  if (value.includes('opinion') || value.includes('reason') || value.includes('media')) return { searchTerm: 'Conversation', preferredTitles: ['Conversation', 'Communication'] };
  if (value.includes('story') || value.includes('experience')) return { searchTerm: 'Story', preferredTitles: ['Story', 'Narrative'] };
  if (value.includes('phone') || value.includes('help')) return { searchTerm: 'Telephone', preferredTitles: ['Telephone', 'Communication'] };
  return { searchTerm: 'Daily life', preferredTitles: ['Daily life', 'Lifestyle', 'Routine'] };
};

const normalizedTitle = (value: string): string => value.trim().toLocaleLowerCase();

const usableText = (value: unknown): string | undefined => {
  if (typeof value !== 'string') return undefined;
  const sentences = value.replace(/\s+/gu, ' ').trim().match(/[^.!?]+[.!?]+/gu) ?? [];
  const selected: string[] = [];
  let words = 0;
  for (const sentence of sentences) {
    const sentenceWords = sentence.trim().split(/\s+/u).filter(Boolean).length;
    if (selected.length > 0 && words + sentenceWords > 220) break;
    selected.push(sentence.trim());
    words += sentenceWords;
    if (words >= 70) break;
  }
  if (words < 45) return undefined;
  return selected.join(' ');
};

export const fetchOpenLearningMaterial = async (date: string, planDay?: Pick<LearningPlanDay, 'theme' | 'focus'>): Promise<OpenLearningMaterial> => {
  const topic = topicFor(planDay);
  const params = new URLSearchParams({
    action: 'query',
    generator: 'search',
    gsrsearch: topic.searchTerm,
    gsrnamespace: '0',
    gsrlimit: '8',
    prop: 'extracts|info',
    explaintext: '1',
    exintro: '1',
    inprop: 'url',
    format: 'json',
    origin: '*',
  });
  const response = await fetchWithTimeout(`${WIKI_API}?${params.toString()}`, { headers: { Accept: 'application/json' } }, 12_000);
  if (!response.ok) throw new Error(`开放资料请求失败（${response.status}）`);
  const payload = await response.json() as { query?: { pages?: Record<string, WikiPage> } };
  const pages = Object.values(payload.query?.pages ?? []).map((page) => ({
    title: typeof page.title === 'string' ? page.title : undefined,
    text: usableText(page.extract),
    sourceUrl: typeof page.canonicalurl === 'string' ? page.canonicalurl : typeof page.fullurl === 'string' ? page.fullurl : undefined,
  })).filter((page): page is { title: string; text: string; sourceUrl: string } => Boolean(page.title && page.text && page.sourceUrl?.startsWith('https://')));
  if (pages.length === 0) throw new Error('开放资料没有返回适合学习的英文条目');
  const page = pages.find((candidate) => topic.preferredTitles.some((title) => normalizedTitle(title) === normalizedTitle(candidate.title))) ?? pages[0];
  return { title: page.title, text: page.text, sourceLabel: 'Simple English Wikipedia（开放资料）', sourceUrl: page.sourceUrl, license: WIKI_LICENSE };
};
