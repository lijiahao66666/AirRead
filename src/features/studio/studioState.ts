import type { Book, Chapter } from '../../domain/books/book';
import { readEpubArchive } from '../../domain/books/epubArchive';

export type StudioStage = 'select' | 'inspect' | 'translate' | 'progress' | 'complete';
export type StudioStatus = 'idle' | 'running' | 'paused' | 'completed' | 'cancelled';
export type StudioParagraphStatus = 'pending' | 'translating' | 'success' | 'failed';

export type StudioParagraph = {
  id: string;
  chapterId: string;
  chapterIndex: number;
  elementIndex: number;
  original: string;
  translation?: string;
  status: StudioParagraphStatus;
  error?: string;
};

export type StudioConfig = {
  sourceLanguage: string;
  targetLanguage: string;
  providerId: string;
  glossary: Record<string, string>;
  outputBilingual: boolean;
};

export type StudioState = {
  stage: StudioStage;
  status: StudioStatus;
  book: Book;
  chapters: Chapter[];
  paragraphs: StudioParagraph[];
  totalCharacters: number;
  config: StudioConfig;
  blob?: Blob;
};

export type StudioAction =
  | { type: 'configure'; config: StudioConfig }
  | { type: 'start' }
  | { type: 'pause' }
  | { type: 'resume' }
  | { type: 'cancel' }
  | { type: 'paragraph-started'; paragraphId: string }
  | { type: 'paragraph-succeeded'; paragraphId: string; translation: string }
  | { type: 'paragraph-failed'; paragraphId: string; error: string }
  | { type: 'retry-failed' }
  | { type: 'complete'; blob: Blob };

const semanticSelector = 'h1,h2,h3,h4,h5,h6,p,li,blockquote';
const DEFAULT_CONFIG: StudioConfig = {
  sourceLanguage: 'auto',
  targetLanguage: 'zh-CN',
  providerId: 'builtin-free',
  glossary: {},
  outputBilingual: true,
};

export function createStudioState(book: Book): StudioState {
  if (book.format !== 'epub') throw new Error('书籍工作室目前只支持 EPUB');
  const archive = readEpubArchive(book.bytes);
  const paragraphs = archive.chapters.flatMap((chapter, chapterIndex) => semanticParagraphs(chapter.content).map((original, elementIndex) => ({
    id: `${chapter.id}:${elementIndex}`,
    chapterId: chapter.id,
    chapterIndex,
    elementIndex,
    original,
    status: 'pending' as const,
  })));
  return {
    stage: 'inspect',
    status: 'idle',
    book,
    chapters: archive.chapters,
    paragraphs,
    totalCharacters: paragraphs.reduce((total, paragraph) => total + paragraph.original.length, 0),
    config: { ...DEFAULT_CONFIG },
  };
}

export function studioReducer(state: StudioState, action: StudioAction): StudioState {
  switch (action.type) {
    case 'configure':
      return { ...state, stage: 'translate', config: action.config };
    case 'start':
      return { ...state, stage: 'progress', status: 'running' };
    case 'pause':
      return state.status === 'running' ? { ...state, status: 'paused' } : state;
    case 'resume':
      return state.status === 'paused' ? { ...state, status: 'running' } : state;
    case 'cancel':
      return { ...state, stage: 'select', status: 'cancelled' };
    case 'paragraph-started':
      return updateParagraph(state, action.paragraphId, (paragraph) => ({ ...paragraph, status: 'translating', error: undefined }));
    case 'paragraph-succeeded':
      return updateParagraph(state, action.paragraphId, (paragraph) => ({ ...paragraph, status: 'success', translation: action.translation, error: undefined }));
    case 'paragraph-failed':
      return updateParagraph(state, action.paragraphId, (paragraph) => ({ ...paragraph, status: 'failed', error: action.error }));
    case 'retry-failed':
      return {
        ...state,
        status: 'running',
        paragraphs: state.paragraphs.map((paragraph) => paragraph.status === 'failed' ? { ...paragraph, status: 'pending', error: undefined } : paragraph),
      };
    case 'complete':
      return { ...state, stage: 'complete', status: 'completed', blob: action.blob };
  }
}

export function buildBilingualChapters(state: StudioState): Chapter[] {
  return state.chapters.map((chapter, chapterIndex) => {
    const document = parseXhtml(chapter.content);
    const elements = semanticElements(document);
    const translations = state.paragraphs.filter((paragraph) => paragraph.chapterIndex === chapterIndex);
    translations.slice().reverse().forEach((paragraph) => {
      const original = elements[paragraph.elementIndex];
      if (!original || !paragraph.translation) return;
      const translation = document.createElementNS('http://www.w3.org/1999/xhtml', 'p');
      translation.setAttribute('class', 'airread-translation');
      translation.setAttribute('lang', state.config.targetLanguage);
      translation.textContent = paragraph.translation;
      if (['li', 'blockquote'].includes(original.tagName.toLowerCase())) original.appendChild(translation);
      else original.parentNode?.insertBefore(translation, original.nextSibling);
    });
    return { ...chapter, content: new XMLSerializer().serializeToString(document) };
  });
}

export function buildStudioChapters(state: StudioState): Chapter[] {
  if (state.config.outputBilingual) return buildBilingualChapters(state);
  return state.chapters.map((chapter, chapterIndex) => {
    const document = parseXhtml(chapter.content);
    const elements = semanticElements(document);
    state.paragraphs
      .filter((paragraph) => paragraph.chapterIndex === chapterIndex)
      .forEach((paragraph) => {
        const original = elements[paragraph.elementIndex];
        if (original && paragraph.translation) replaceTextPreservingMarkup(original, paragraph.translation);
      });
    return { ...chapter, content: new XMLSerializer().serializeToString(document) };
  });
}

function updateParagraph(state: StudioState, id: string, update: (paragraph: StudioParagraph) => StudioParagraph): StudioState {
  return { ...state, paragraphs: state.paragraphs.map((paragraph) => paragraph.id === id ? update(paragraph) : paragraph) };
}

function semanticParagraphs(content: string): string[] {
  const document = parseXhtml(content);
  return semanticElements(document)
    .map((element) => element.textContent?.replace(/\s+/g, ' ').trim() || '')
    .filter(Boolean);
}

function semanticElements(document: Document): Element[] {
  return [...document.querySelectorAll(semanticSelector)]
    .filter((element) => !element.parentElement?.closest(semanticSelector));
}

function replaceTextPreservingMarkup(element: Element, translation: string): void {
  const textNodes = collectTextNodes(element);
  if (textNodes.length === 0) {
    element.textContent = translation;
    return;
  }
  const sourceLength = textNodes.reduce((total, node) => total + node.data.length, 0);
  let offset = 0;
  textNodes.forEach((node, index) => {
    const length = index === textNodes.length - 1
      ? translation.length - offset
      : Math.round((translation.length * node.data.length) / Math.max(1, sourceLength));
    node.data = translation.slice(offset, offset + Math.max(0, length));
    offset += Math.max(0, length);
  });
}

function collectTextNodes(element: Element): Text[] {
  const nodes: Text[] = [];
  const visit = (node: Node) => {
    if (node.nodeType === 3) nodes.push(node as Text);
    else node.childNodes.forEach(visit);
  };
  visit(element);
  return nodes;
}

function parseXhtml(content: string): Document {
  const document = new DOMParser().parseFromString(content, 'application/xhtml+xml');
  if (document.querySelector('parsererror')) throw new Error('EPUB 章节 XHTML 无法解析');
  return document;
}
