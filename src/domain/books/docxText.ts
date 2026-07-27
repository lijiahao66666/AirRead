import { strFromU8, unzipSync } from 'fflate';

export type ExtractedDocxText = {
  title?: string;
  author?: string;
  text: string;
};

export function extractDocxText(bytes: Uint8Array): ExtractedDocxText {
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes);
  } catch {
    throw new Error('DOCX 文件无法解压，可能已损坏');
  }

  const documentXml = files['word/document.xml'];
  if (!documentXml) throw new Error('DOCX 缺少正文文档');
  const document = parseXml(strFromU8(documentXml), '正文');
  const paragraphs = Array.from(document.getElementsByTagNameNS('*', 'p'))
    .map(extractParagraph)
    .filter(Boolean);
  const text = paragraphs.join('\n\n').trim();
  if (!text) throw new Error('未从 DOCX 提取到可读文本');

  const coreProperties = files['docProps/core.xml']
    ? parseXml(strFromU8(files['docProps/core.xml']), '元数据')
    : undefined;
  return {
    title: coreProperties ? metadataValue(coreProperties, 'title') : undefined,
    author: coreProperties ? metadataValue(coreProperties, 'creator') : undefined,
    text,
  };
}

function parseXml(source: string, label: string): XMLDocument {
  if (typeof DOMParser === 'undefined') throw new Error(`当前浏览器无法解析 DOCX ${label}`);
  const document = new DOMParser().parseFromString(source, 'application/xml');
  if (document.documentElement.localName === 'parsererror' || document.getElementsByTagName('parsererror').length > 0) {
    throw new Error(`DOCX ${label}格式无效`);
  }
  return document;
}

function extractParagraph(paragraph: Element): string {
  let text = '';
  for (const element of Array.from(paragraph.getElementsByTagName('*'))) {
    const name = element.localName.toLowerCase();
    if (name === 't') text += element.textContent || '';
    else if (name === 'tab') text += '\t';
    else if (name === 'br' || name === 'cr') text += '\n';
  }
  const normalizedText = text.replace(/\u00a0/gu, ' ').trim();
  const level = headingLevel(paragraph);
  return level ? `${'#'.repeat(level)} ${normalizedText}` : normalizedText;
}

function headingLevel(paragraph: Element): number | undefined {
  const style = paragraph.getElementsByTagNameNS('*', 'pStyle')[0];
  const styleValue = wordAttribute(style, 'val');
  const styleMatch = styleValue?.match(/(?:heading|标题)\s*([1-6])$/iu);
  if (styleMatch?.[1]) return Number(styleMatch[1]);

  const outlineLevel = Number(wordAttribute(paragraph.getElementsByTagNameNS('*', 'outlineLvl')[0], 'val'));
  return Number.isInteger(outlineLevel) && outlineLevel >= 0 && outlineLevel <= 5 ? outlineLevel + 1 : undefined;
}

function wordAttribute(element: Element | undefined, localName: string): string | undefined {
  return Array.from(element?.attributes || []).find((attribute) => attribute.localName === localName)?.value;
}

function metadataValue(document: XMLDocument, name: string): string | undefined {
  const element = document.getElementsByTagNameNS('*', name)[0];
  const value = element?.textContent?.trim();
  return value || undefined;
}
