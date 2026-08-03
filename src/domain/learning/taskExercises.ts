import type { LearningTaskExercise, LearningTaskKind } from './learningTypes';

const splitSentences = (text: string): string[] => text.match(/[^.!?]+[.!?]+/gu)?.map((sentence) => sentence.trim()).filter((sentence) => sentence.split(/\s+/u).length >= 4) ?? [];

const wordsFrom = (sentence: string): string[] => sentence.match(/[A-Za-z]+(?:'[A-Za-z]+)?/gu) ?? [];

const hashText = (value: string): number => [...value].reduce((hash, character) => (hash * 31 + character.charCodeAt(0)) >>> 0, 7);

const shuffled = <Value>(values: Value[], seed: string): Value[] => {
  const result = [...values];
  let state = hashText(seed);
  for (let index = result.length - 1; index > 0; index -= 1) {
    state = (state * 1664525 + 1013904223) >>> 0;
    const target = state % (index + 1);
    [result[index], result[target]] = [result[target], result[index]];
  }
  if (result.every((value, index) => value === values[index]) && result.length > 1) [result[0], result[1]] = [result[1], result[0]];
  return result;
};

const practiceSentence = (text: string): string | undefined => {
  const sentences = splitSentences(text);
  return sentences.find((candidate) => {
    const length = wordsFrom(candidate).length;
    return length >= 5 && length <= 14;
  }) ?? sentences.sort((left, right) => wordsFrom(left).length - wordsFrom(right).length)[0];
};

export const buildTaskExercise = (kind: LearningTaskKind, text: string, taskId: string): LearningTaskExercise | undefined => {
  const sentences = splitSentences(text);
  const sentence = practiceSentence(text);
  if (!sentence) return undefined;

  if (kind === 'listen') {
    const distractors = sentences.filter((candidate) => candidate !== sentence).slice(0, 2);
    return {
      type: 'listen-choice',
      prompt: '先播放句子，不看原文，选择你听到的内容。',
      text: sentence,
      choices: shuffled([sentence, ...distractors], taskId),
      answer: sentence,
    };
  }

  if (kind === 'read') {
    const word = wordsFrom(sentence).find((candidate) => candidate.length >= 5);
    if (!word) return undefined;
    return {
      type: 'cloze',
      prompt: `根据原文填入缺失单词：${sentence.replace(new RegExp(`\\b${word}\\b`, 'u'), '_____')}`,
      answer: word.toLowerCase(),
    };
  }

  if (kind === 'speak') {
    return {
      type: 'shadowing',
      prompt: '播放后跟读这句话，再录下自己的声音回听。',
      text: sentence,
    };
  }

  if (kind === 'recall') {
    const words = wordsFrom(sentence);
    if (words.length < 4) return undefined;
    return {
      type: 'word-order',
      prompt: '不看原文，把词块按正确顺序排成句子。',
      choices: shuffled(words, taskId),
      answer: sentence,
    };
  }

  if (kind === 'write') {
    return {
      type: 'free-write',
      prompt: '用英文写 1-2 句：复述材料中的一个信息，再联系你自己的经历。',
      minimumWords: 10,
    };
  }

  return undefined;
};

export const normalizeExerciseAnswer = (value: string): string => value.toLowerCase().replace(/[^a-z0-9' ]/gu, '').replace(/\s+/gu, ' ').trim();
