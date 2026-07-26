import type { ReaderParagraph } from './readerState';

export type ReaderPageBlock = {
  id: string;
  paragraphId: string;
  original: string;
  translation?: string;
};

export type ReaderPage = ReaderPageBlock[];

const splitAtWordBoundary = (text: string, parts: number): string[] => {
  if (parts <= 1 || text.length === 0) return [text];
  const chunks: string[] = [];
  let remaining = text.trim();
  for (let index = parts; index > 1 && remaining; index -= 1) {
    const target = Math.ceil(remaining.length / index);
    const windowStart = Math.max(1, target - Math.floor(target * 0.2));
    const windowEnd = Math.min(remaining.length - 1, target + Math.floor(target * 0.2));
    const boundary = remaining.slice(windowStart, windowEnd + 1).search(/[\s。！？；.!?;]\s*/u);
    const cut = boundary >= 0 ? windowStart + boundary + 1 : target;
    chunks.push(remaining.slice(0, cut).trim());
    remaining = remaining.slice(cut).trim();
  }
  if (remaining) chunks.push(remaining);
  return chunks.filter(Boolean);
};

const blocksForParagraph = (paragraph: ReaderParagraph, blockCapacity: number, showTranslations: boolean): ReaderPageBlock[] => {
  const translationWeight = showTranslations && paragraph.translation ? paragraph.translation.length * 0.82 : 0;
  const parts = Math.max(1, Math.ceil((paragraph.original.length + translationWeight + 48) / blockCapacity));
  const originalParts = splitAtWordBoundary(paragraph.original, parts);
  const translationParts = paragraph.translation ? splitAtWordBoundary(paragraph.translation, originalParts.length) : [];
  return originalParts.map((original, index) => ({
    id: `${paragraph.id}-${index}`,
    paragraphId: paragraph.id,
    original,
    translation: translationParts[index],
  }));
};

export function paginateReaderParagraphs(paragraphs: ReaderParagraph[], options: { blockCapacity: number; showTranslations: boolean }): ReaderPage[] {
  const pages: ReaderPage[] = [];
  let page: ReaderPage = [];
  let used = 0;
  paragraphs.forEach((paragraph) => {
    blocksForParagraph(paragraph, options.blockCapacity, options.showTranslations).forEach((block) => {
      const weight = block.original.length + (options.showTranslations && block.translation ? block.translation.length * 0.82 : 0) + 48;
      if (page.length > 0 && used + weight > options.blockCapacity) {
        pages.push(page);
        page = [];
        used = 0;
      }
      page.push(block);
      used += weight;
    });
  });
  if (page.length > 0) pages.push(page);
  return pages.length > 0 ? pages : [[]];
}
