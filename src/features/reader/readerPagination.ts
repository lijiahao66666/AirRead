import type { ReaderParagraph } from './readerState';

export type ReaderPageBlock = {
  id: string;
  paragraphId: string;
  original: string;
  translation?: string;
  sourceStart: number;
  sourceEnd: number;
  isFinalFragment: boolean;
};

export type ReaderPage = ReaderPageBlock[];
export type ReaderContentMode = 'original' | 'bilingual' | 'translation';
export type ReaderBlockMetric = { id: string; height: number; gapAfter: number };

const glyphWeight = (text: string): number => [...text].reduce((total, character) => {
  if (/\s/u.test(character)) return total + 0.28;
  if (/[\u1100-\u11ff\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/u.test(character)) return total + 1;
  if (/[A-Za-z0-9À-ÖØ-öø-ÿ]/u.test(character)) return total + 0.54;
  return total + 0.42;
}, 0);

type TextFragment = { text: string; start: number; end: number };

const splitAtWordBoundary = (text: string, parts: number): TextFragment[] => {
  if (parts <= 1 || text.length === 0) return [{ text, start: 0, end: text.length }];
  const chunks: TextFragment[] = [];
  let start = 0;
  for (let partsRemaining = parts; partsRemaining > 1 && start < text.length; partsRemaining -= 1) {
    const remainingLength = text.length - start;
    const target = start + Math.ceil(remainingLength / partsRemaining);
    const windowStart = Math.max(start + 1, target - Math.floor(remainingLength / partsRemaining * 0.22));
    const windowEnd = Math.min(text.length - 1, target + Math.floor(remainingLength / partsRemaining * 0.22));
    const candidates = text.slice(windowStart, windowEnd + 1);
    const matches = [...candidates.matchAll(/[\s。！？；.!?;]+/gu)];
    const boundary = matches[matches.length - 1];
    const end = boundary ? windowStart + boundary.index! + boundary[0].length : target;
    if (end <= start || end >= text.length) break;
    chunks.push({ text: text.slice(start, end), start, end });
    start = end;
  }
  chunks.push({ text: text.slice(start), start, end: text.length });
  return chunks.filter((chunk) => chunk.text.length > 0);
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
    original: original.text,
    translation: translationParts[index]?.text,
    sourceStart: original.start,
    sourceEnd: original.end,
    isFinalFragment: index === originalParts.length - 1,
  }));
};

export function createReaderPageBlocks(paragraphs: ReaderParagraph[], options: { blockCapacity: number; blockGapWeight?: number; contentMode: ReaderContentMode }): ReaderPageBlock[] {
  const blockGapWeight = options.blockGapWeight ?? 48;
  return paragraphs.flatMap((paragraph) => blocksForParagraph(paragraph, options.blockCapacity, blockGapWeight, options.contentMode));
}

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
  createReaderPageBlocks(paragraphs, options).forEach((block) => {
    const weight = visibleWeight(block, options.contentMode) + blockGapWeight;
    if (page.length > 0 && used + weight > options.blockCapacity) {
      pages.push(page);
      page = [];
      used = 0;
    }
    page.push(block);
    used += weight;
  });
  if (page.length > 0) pages.push(page);
  return pages.length > 0 ? rebalanceTrailingPage(pages, options.blockCapacity, options.contentMode, blockGapWeight) : [[]];
}

export function paginateMeasuredReaderBlocks(blocks: ReaderPageBlock[], metrics: ReaderBlockMetric[], contentHeight: number): ReaderPage[] {
  const metricById = new Map(metrics.map((metric) => [metric.id, metric]));
  const pages: ReaderPage[] = [];
  let page: ReaderPage = [];
  let usedHeight = 0;

  blocks.forEach((block) => {
    const metric = metricById.get(block.id);
    if (!metric || metric.height <= 0) return;
    const previous = page[page.length - 1];
    const previousMetric = previous ? metricById.get(previous.id) : undefined;
    const nextHeight = page.length === 0 ? metric.height : usedHeight + (previousMetric?.gapAfter ?? 0) + metric.height;
    if (page.length > 0 && nextHeight > contentHeight) {
      pages.push(page);
      page = [block];
      usedHeight = metric.height;
      return;
    }
    page.push(block);
    usedHeight = nextHeight;
  });

  if (page.length > 0) pages.push(page);
  return pages.length > 0 ? pages : [[]];
}
