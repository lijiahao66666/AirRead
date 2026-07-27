import { describe, expect, it } from 'vitest';

import { splitTextIntoChapters } from './textChapters';

describe('TXT chapter splitting', () => {
  it('recognizes common Chinese and English chapter headings without losing opening text', () => {
    const chapters = splitTextIntoChapters('书名\n作者\n\n第一章 开始\n第一章内容\n\n第2章 继续\n第二章内容\n\nChapter III: End\nFinal chapter', '测试书籍');

    expect(chapters).toEqual([
      { title: '正文', content: '书名\n作者' },
      { title: '第一章 开始', content: '第一章内容' },
      { title: '第2章 继续', content: '第二章内容' },
      { title: 'Chapter III: End', content: 'Final chapter' },
    ]);
  });

  it('keeps unstructured TXT as one readable chapter', () => {
    expect(splitTextIntoChapters('没有章节标题的短文。\n\n第二段。', '短文')).toEqual([
      { title: '短文', content: '没有章节标题的短文。\n\n第二段。' },
    ]);
  });

  it('does not mistake ordinary prose beginning with a chapter word for a heading', () => {
    expect(splitTextIntoChapters('第一章内容只是正文，不应成为目录。\n\n第1章：真正的标题\n章节正文。', '短文')).toEqual([
      { title: '正文', content: '第一章内容只是正文，不应成为目录。' },
      { title: '第1章：真正的标题', content: '章节正文。' },
    ]);
  });

  it('uses Markdown headings for the table of contents', () => {
    expect(splitTextIntoChapters('# 序言\n\n开始阅读。\n\n## 第二部分\n\n继续阅读。', '文档')).toEqual([
      { title: '序言', content: '开始阅读。' },
      { title: '第二部分', content: '继续阅读。' },
    ]);
  });
});
