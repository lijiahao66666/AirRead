import { strFromU8, unzipSync } from 'fflate';
import { describe, expect, it } from 'vitest';

import { createStoryEpub } from './storyEpub';
import { createStoryMemoryFixture, createStoryPackFixture } from '../../test/learningFixture';

describe('story EPUB archive', () => {
  it('writes the original chapters, summaries, translation, and navigation into a standard EPUB bundle', () => {
    const firstChapter = createStoryPackFixture('2026-08-03');
    const secondChapter = {
      ...createStoryPackFixture('2026-08-04'),
      story: {
        ...createStoryPackFixture('2026-08-04').story,
        chapterNumber: 2,
        chapterTitle: 'The Blue Door',
        previousSummary: firstChapter.story.chapterSummary,
      },
    };
    const story = createStoryMemoryFixture({ chapterNumber: 2 });

    const files = unzipSync(createStoryEpub(story, { [firstChapter.date]: firstChapter, [secondChapter.date]: secondChapter }));

    expect(strFromU8(files.mimetype)).toBe('application/epub+zip');
    expect(strFromU8(files['META-INF/container.xml'])).toContain('OEBPS/content.opf');
    expect(strFromU8(files['OEBPS/content.opf'])).toContain('chapter-0002.xhtml');
    expect(strFromU8(files['OEBPS/nav.xhtml'])).toContain('The Blue Door');
    expect(strFromU8(files['OEBPS/text/chapter-0001.xhtml'])).toContain(firstChapter.originalText);
    expect(strFromU8(files['OEBPS/text/chapter-0001.xhtml'])).toContain(firstChapter.translation!);
  });

  it('does not create an empty archive before the first chapter exists', () => {
    expect(() => createStoryEpub(createStoryMemoryFixture(), {})).toThrow('当前故事还没有可导出的章节');
  });
});
