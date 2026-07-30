export type PhraseSelectionBlock = {
  id: string;
  paragraphId: string;
  original: string;
  sourceStart?: number;
};

export type PhraseSelectionPoint = {
  blockId: string;
  segmentIndex: number;
};

export type PhraseSelectionRange = {
  start: PhraseSelectionPoint;
  end: PhraseSelectionPoint;
};

export type PhraseTextSegment = {
  text: string;
  selectable: boolean;
};

export type ResolvedPhraseSelection = {
  source: string;
  selectedTokenKeys: Set<string>;
  anchor: { paragraphId: string; sourceOffset: number };
};

const phraseSegmentPattern = /[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]|\s+|[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*|[^\s]/gu;
const selectableTextPattern = /[\p{L}\p{N}]/u;

export const phraseSelectionPointKey = ({ blockId, segmentIndex }: PhraseSelectionPoint): string => `${blockId}:${segmentIndex}`;

export function phraseTextSegments(text: string): PhraseTextSegment[] {
  return (text.match(phraseSegmentPattern) ?? []).map((segment) => ({ text: segment, selectable: selectableTextPattern.test(segment) }));
}

export function resolvePhraseSelection(blocks: PhraseSelectionBlock[], range: PhraseSelectionRange): ResolvedPhraseSelection | undefined {
  const points = blocks.flatMap((block, blockIndex) => phraseTextSegments(block.original).flatMap((segment, segmentIndex) => (
    segment.selectable ? [{ blockId: block.id, blockIndex, segmentIndex }] : []
  )));
  const startIndex = points.findIndex((point) => phraseSelectionPointKey(point) === phraseSelectionPointKey(range.start));
  const endIndex = points.findIndex((point) => phraseSelectionPointKey(point) === phraseSelectionPointKey(range.end));
  if (startIndex < 0 || endIndex < 0) return undefined;

  const [firstIndex, lastIndex] = startIndex <= endIndex ? [startIndex, endIndex] : [endIndex, startIndex];
  const start = points[firstIndex];
  const end = points[lastIndex];
  const selectedTokenKeys = new Set(points.slice(firstIndex, lastIndex + 1).map(phraseSelectionPointKey));
  const parts: Array<{ paragraphId: string; text: string }> = [];

  for (let blockIndex = start.blockIndex; blockIndex <= end.blockIndex; blockIndex += 1) {
    const block = blocks[blockIndex];
    const segments = phraseTextSegments(block.original);
    const startSegment = blockIndex === start.blockIndex ? start.segmentIndex : 0;
    const endSegment = blockIndex === end.blockIndex ? end.segmentIndex : segments.length - 1;
    const text = segments.slice(startSegment, endSegment + 1).map((segment) => segment.text).join('').trim();
    if (text) parts.push({ paragraphId: block.paragraphId, text });
  }

  const source = parts.reduce((result, part, index) => {
    if (index === 0) return part.text;
    const previous = parts[index - 1];
    return `${result}${previous.paragraphId === part.paragraphId ? ' ' : '\n\n'}${part.text}`;
  }, '');
  const startBlock = blocks[start.blockIndex];
  const sourceOffset = (startBlock.sourceStart ?? 0) + phraseTextSegments(startBlock.original)
    .slice(0, start.segmentIndex)
    .reduce((offset, segment) => offset + segment.text.length, 0);
  return source ? { source, selectedTokenKeys, anchor: { paragraphId: startBlock.paragraphId, sourceOffset } } : undefined;
}
