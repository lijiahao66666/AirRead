import { describe, expect, it } from 'vitest';

import { buildTaskExercise } from './taskExercises';

const sourceText = 'The city library opens early on weekdays. Visitors can borrow books and use computers. Staff members can help people find information.';

describe('learning exercises', () => {
  it('derives answerable listening, reading, recall, and speaking practice from the lesson text', () => {
    const listening = buildTaskExercise('listen', sourceText, 'pack-1:listen');
    const reading = buildTaskExercise('read', sourceText, 'pack-1:read');
    const recall = buildTaskExercise('recall', sourceText, 'pack-1:recall');
    const speaking = buildTaskExercise('speak', sourceText, 'pack-1:speak');

    expect(listening).toMatchObject({ type: 'listen-choice', answer: 'The city library opens early on weekdays.' });
    expect(listening?.choices).toContain('The city library opens early on weekdays.');
    expect(reading).toMatchObject({ type: 'reading-check', answer: 'The city library opens early on weekdays.' });
    expect(reading?.choices).toContain('The city library opens early on weekdays.');
    expect(recall).toMatchObject({ type: 'word-order', answer: 'The city library opens early on weekdays.' });
    expect(recall?.choices).not.toEqual(['The', 'city', 'library', 'opens', 'early', 'on', 'weekdays']);
    expect(speaking).toMatchObject({ type: 'shadowing', text: 'The city library opens early on weekdays.' });
  });

  it('does not fabricate an exercise answer when a source has no usable sentence', () => {
    expect(buildTaskExercise('read', 'Hi', 'pack-1:read')).toBeUndefined();
  });

  it('selects a concise practice sentence and keeps listening choices distinct', () => {
    const text = 'A deliberately long introduction contains many more than fourteen carefully chosen words before it finally ends. It is short enough for a phone exercise. Another long sentence makes a useful but different distractor for the learner.';
    const listening = buildTaskExercise('listen', text, 'pack-1:listen');

    expect(listening).toMatchObject({ text: 'It is short enough for a phone exercise.', answer: 'It is short enough for a phone exercise.' });
    expect(new Set(listening?.choices).size).toBe(listening?.choices?.length);
  });

  it('uses the requested sentence and vocabulary context for each task', () => {
    const vocabulary = [{ term: 'borrow books' }];
    const reading = buildTaskExercise('read', sourceText, 'pack-1:read', { sentenceIndex: 1, vocabulary });
    const writing = buildTaskExercise('write', sourceText, 'pack-1:write', { sentenceIndex: 1, vocabulary });

    expect(reading).toMatchObject({ type: 'reading-check', answer: 'Visitors can borrow books and use computers.' });
    expect(reading?.choices).toContain('Visitors can borrow books and use computers.');
    expect(writing?.prompt).toContain('borrow books');
    expect(writing?.referenceText).toBe('Visitors can borrow books and use computers.');
  });
});
