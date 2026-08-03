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
    expect(reading).toMatchObject({ type: 'cloze', answer: 'library' });
    expect(reading?.prompt).toContain('_____');
    expect(recall).toMatchObject({ type: 'word-order', answer: 'The city library opens early on weekdays.' });
    expect(recall?.choices).not.toEqual(['The', 'city', 'library', 'opens', 'early', 'on', 'weekdays']);
    expect(speaking).toMatchObject({ type: 'shadowing', text: 'The city library opens early on weekdays.' });
  });

  it('does not fabricate an exercise answer when a source has no usable sentence', () => {
    expect(buildTaskExercise('read', 'Hi', 'pack-1:read')).toBeUndefined();
  });
});
