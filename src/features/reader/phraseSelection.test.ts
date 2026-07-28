import { describe, expect, it } from 'vitest';

import { phraseTextSegments, resolvePhraseSelection } from './phraseSelection';

describe('phraseSelection', () => {
  it('makes CJK characters independently selectable while preserving punctuation', () => {
    expect(phraseTextSegments('这是中文。')).toEqual([
      { text: '这', selectable: true },
      { text: '是', selectable: true },
      { text: '中', selectable: true },
      { text: '文', selectable: true },
      { text: '。', selectable: false },
    ]);
  });

  it('resolves a reversed multi-paragraph range in reading order', () => {
    const blocks = [
      { id: 'first', paragraphId: 'paragraph-1', original: 'The first paragraph.' },
      { id: 'second', paragraphId: 'paragraph-2', original: 'The second paragraph.' },
    ];

    expect(resolvePhraseSelection(blocks, {
      start: { blockId: 'second', segmentIndex: 2 },
      end: { blockId: 'first', segmentIndex: 2 },
    })).toMatchObject({ source: 'first paragraph.\n\nThe second' });
  });
});
