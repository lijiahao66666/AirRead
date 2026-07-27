import type { ReaderParagraph } from './readerState';

export type ReaderPageBlock = {
  id: string;
  paragraphId: string;
  original: string;
  translation?: string;
};

export type ReaderPage = ReaderPageBlock[];
export type ReaderContentMode = 'original' | 'bilingual' | 'translation';

const glyphWeight = (text: string): number => [...text].reduce((total, character) => {
  if (/\s/u.test(character)) return total + 0.28;
  if (/[\u1100-\u11ff\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/u.test(character)) return total + 1;
  if (/[A-Za-z0-9À-ÖØ-öø-ÿ]/u.test(character)) return total + 0.54;
  return total + 0.42;
}, 0);

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

const visibleWeight = (paragraph: Pick<ReaderParagraph, 'original' | 'translation'>, contentMode: ReaderContentMode): number => {
  if (contentMode === 'original') return glyphWeight(paragraph.original);
  if (contentMode === 'translation') return glyphWeight(paragraph.translation ?? paragraph.original) * 0.82;
  return glyphWeight(paragraph.original) + glyphWeight(paragraph.translation ?? '') * 0.82;
};

const blocksForParagraph = (paragraph: ReaderParagraph, blockCapacity: number, blockGapWeight: number, contentMode: ReaderContentMode): ReaderPageBlock[] => {
  const parts = Math.max(1, Math.ceil((visibleWeight(paragraph, contentMode) + blockGapWeight) / blockCapacity));
  const originalParts = splitAtWordBoundary(paragraph.original, parts);
  const translationParts = paragraph.translation ? splitAtWordBoundary(paragraph.translation, originalParts.length) : [];
  return originalParts.map((original, index) => ({
    id: `${paragraph.id}-${index}`,
    paragraphId: paragraph.id,
    original,
    translation: translationParts[index],
  }));
};

const pageWeight = (page: ReaderPageBlock[], contentMode: ReaderContentMode, blockGapWeight: number): number => page.reduce((total, block) => total + visibleWeight(block, contentMode) + blockGapWeight, 0);

const rebalanceTrailingPage = (pages: ReaderPage[], blockCapacity: number, contentMode: ReaderContentMode, blockGapWeight: number): ReaderPage[] => {
  if (pages.length < 2) return pages;
  const trailing = pages[pages.length - 1];
  const previous = pages[pages.length - 2];
  while (trailing.length > 0 && previous.length > 1 && pageWeight(trailing, contentMode, blockGapWeight) < blockCapacity * 0.44) {
    const candidate = previous[previous.length - 1];
    const nextTrailingWeight = pageWeight([candidate, ...trailing], contentMode, blockGapWeight);
    const remainingPreviousWeight = pageWeight(previous.slice(0, -1), contentMode, blockGapWeight);
    if (nextTrailingWeight > blockCapacity * 0.96 || remainingPreviousWeight < blockCapacity * 0.54) break;
    trailing.unshift(previous.pop()!);
  }
  return pages;
};

export function paginateReaderParagraphs(paragraphs: ReaderParagraph[], options: { blockCapacity: number; blockGapWeight?: number; contentMode: ReaderContentMode }): ReaderPage[] {
  const pages: ReaderPage[] = [];
  const blockGapWeight = options.blockGapWeight ?? 48;
  let page: ReaderPage = [];
  let used = 0;
  paragraphs.forEach((paragraph) => {
    blocksForParagraph(paragraph, options.blockCapacity, blockGapWeight, options.contentMode).forEach((block) => {
      const weight = visibleWeight(block, options.contentMode) + blockGapWeight;
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
  return pages.length > 0 ? rebalanceTrailingPage(pages, options.blockCapacity, options.contentMode, blockGapWeight) : [[]];
}
