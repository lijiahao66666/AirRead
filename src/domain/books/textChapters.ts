export type TextChapter = {
  title: string;
  content: string;
};

const numberedHeading = /^(?:第\s*[0-9零一二三四五六七八九十百千万两〇]+\s*(?:章|节|回|卷|部|篇|集)|(?:卷|部|篇)\s*[0-9零一二三四五六七八九十百千万两〇]+)(?:(?:\s+|\s*[:：、.．—-]\s*).+)?$/iu;
const latinHeading = /^(?:chapter|part)\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)(?:(?:\s+|\s*[:：.．—-]\s*).+)?$/iu;
const standaloneHeading = /^(?:序章|楔子|前言|引子|后记|尾声|番外|附录)(?:\s*[:：、.．—-]?\s*.*)?$/u;

const normalizedLines = (text: string): string[] => text
  .replace(/^\uFEFF/u, '')
  .replace(/\r\n?/gu, '\n')
  .split('\n');

const isHeading = (line: string): boolean => {
  const value = line.trim();
  return value.length > 0 && value.length <= 72 && (numberedHeading.test(value) || latinHeading.test(value) || standaloneHeading.test(value));
};

const chapterContent = (lines: string[]): string => lines.join('\n').replace(/^\n+|\n+$/gu, '').trim();

export function splitTextIntoChapters(text: string, fallbackTitle: string): TextChapter[] {
  const lines = normalizedLines(text);
  const headings = lines.flatMap((line, index) => isHeading(line) ? [{ index, title: line.trim().replace(/\s+/gu, ' ') }] : []);
  if (headings.length === 0) return [{ title: fallbackTitle, content: chapterContent(lines) }];

  const chapters: TextChapter[] = [];
  const opening = chapterContent(lines.slice(0, headings[0].index));
  if (opening) chapters.push({ title: '正文', content: opening });
  headings.forEach((heading, index) => {
    const nextHeading = headings[index + 1];
    const content = chapterContent(lines.slice(heading.index + 1, nextHeading?.index));
    if (content) chapters.push({ title: heading.title, content });
  });
  return chapters.length > 0 ? chapters : [{ title: fallbackTitle, content: chapterContent(lines) }];
}
