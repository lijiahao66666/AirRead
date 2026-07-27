import { readEpubArchive } from './epubArchive';
import type { Book } from './book';
import { extractPdfText } from './pdfText';
import { decodeText } from './textDecoder';
import { htmlToText, markdownToText } from './textDocument';

export async function parseBook(file: File): Promise<Book> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes.length === 0) throw new Error('书籍文件为空');
  const extension = file.name.toLowerCase().split('.').pop();
  const importedAt = Date.now();
  const id = createId();

  if (extension === 'pdf') {
    const extracted = await extractPdfText(bytes);
    return {
      id,
      title: extracted.title || titleFromFileName(file.name),
      author: extracted.author || '',
      format: 'pdf',
      bytes: Uint8Array.from(bytes),
      text: extracted.text,
      importedAt,
      readingChapter: 0,
      readingProgress: 0,
      generatedBilingual: false,
    };
  }

  if (extension === 'txt' || extension === 'md' || extension === 'markdown' || extension === 'html' || extension === 'htm') {
    const decoded = decodeText(bytes);
    const format = extension === 'txt' ? 'txt' : extension === 'md' || extension === 'markdown' ? 'markdown' : 'html';
    return {
      id,
      title: titleFromFileName(file.name),
      author: '',
      format,
      bytes: Uint8Array.from(bytes),
      text: format === 'markdown' ? markdownToText(decoded) : format === 'html' ? htmlToText(decoded) : decoded,
      importedAt,
      readingChapter: 0,
      readingProgress: 0,
      generatedBilingual: false,
    };
  }

  if (extension !== 'epub') throw new Error('仅支持 EPUB、TXT、Markdown、HTML 或包含可选文本的 PDF 文件');
  const archive = readEpubArchive(bytes);
  return {
    id,
    title: archive.title,
    author: archive.author,
    format: 'epub',
    bytes: Uint8Array.from(bytes),
    coverDataUrl: archive.coverDataUrl,
    importedAt,
    readingChapter: 0,
    readingProgress: 0,
    generatedBilingual: false,
  };
}

function titleFromFileName(fileName: string): string {
  return fileName.replace(/\.(?:txt|md|markdown|html?|pdf)$/iu, '') || '未命名书籍';
}

function createId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}
