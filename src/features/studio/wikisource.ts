import type { Book } from '../../domain/books/book';

const WIKISOURCE_API = '/api/open-books/wikisource';
const WIKISOURCE_PAGE = 'https://zh.wikisource.org/wiki/';

export type WikisourceSearchResult = {
  title: string;
  snippet: string;
  wordCount: number;
};

export type WikisourcePage = {
  title: string;
  text: string;
  url: string;
};

type Fetcher = typeof fetch;

const request = async <T>(parameters: Record<string, string>, fetcher: Fetcher): Promise<T> => {
  const search = new URLSearchParams({ format: 'json', origin: '*', ...parameters });
  const response = await fetcher(`${WIKISOURCE_API}?${search}`);
  if (!response.ok) throw new Error('中文维基文库暂时无法连接，请稍后重试');
  return response.json() as Promise<T>;
};

const plainText = (html: string): string => {
  const document = window.document.implementation.createHTMLDocument('wikisource');
  document.body.innerHTML = html;
  return (document.body.textContent ?? '').replace(/\s+/gu, ' ').trim();
};

export async function searchWikisource(query: string, fetcher: Fetcher = fetch): Promise<WikisourceSearchResult[]> {
  const normalizedQuery = query.trim();
  if (!normalizedQuery) return [];
  const response = await request<{ query?: { search?: Array<{ title?: string; snippet?: string; wordcount?: number }> } }>({
    action: 'query', list: 'search', srsearch: normalizedQuery, srlimit: '12', srnamespace: '0',
  }, fetcher);
  return (response.query?.search ?? []).flatMap((item) => item.title ? [{
    title: item.title,
    snippet: plainText(item.snippet ?? ''),
    wordCount: Number(item.wordcount) || 0,
  }] : []);
}

export function wikisourceHtmlToText(html: string): string {
  const document = window.document.implementation.createHTMLDocument('wikisource');
  document.body.innerHTML = html;
  const root = document.querySelector('.mw-parser-output') ?? document.body;
  root.querySelectorAll('script, style, table, .navbox, .noprint, .mw-editsection, .ambox, .authority-control, sup.reference').forEach((element) => element.remove());
  const blocks = [...root.querySelectorAll('h1, h2, h3, h4, h5, h6, p, li, blockquote')]
    .map((element) => {
      const value = (element.textContent ?? '').replace(/\s+/gu, ' ').trim();
      if (!value) return '';
      return /^H[1-6]$/u.test(element.tagName) ? `# ${value}` : value;
    })
    .filter(Boolean);
  return blocks.join('\n\n').replace(/\n{3,}/gu, '\n\n').trim();
}

export async function loadWikisourcePage(title: string, fetcher: Fetcher = fetch): Promise<WikisourcePage> {
  const response = await request<{ parse?: { title?: string; text?: { '*': string } }; error?: { info?: string } }>({
    action: 'parse', page: title, prop: 'text|displaytitle', redirects: '1',
  }, fetcher);
  const parsedTitle = response.parse?.title;
  const text = response.parse?.text?.['*'];
  if (!parsedTitle || !text) throw new Error(response.error?.info || '未能读取该页面正文');
  const content = wikisourceHtmlToText(text);
  if (!content) throw new Error('该页面没有可导入的正文');
  return { title: parsedTitle, text: content, url: `${WIKISOURCE_PAGE}${encodeURIComponent(parsedTitle.replace(/ /gu, '_'))}` };
}

export function createWikisourceBook(page: WikisourcePage): Book {
  const sourceNote = `来源说明\n\n本文导入自中文维基文库：${page.url}\n内容遵循中文维基文库页面标注的授权条款，通常为 CC BY-SA 4.0。`;
  const text = `# ${page.title}\n\n${page.text}\n\n# ${sourceNote}`;
  return {
    id: `wikisource:${encodeURIComponent(page.title)}`,
    title: page.title,
    author: '中文维基文库',
    format: 'txt',
    bytes: new TextEncoder().encode(text),
    text,
    importedAt: Date.now(),
    readingChapter: 0,
    readingProgress: 0,
    generatedBilingual: false,
    source: { provider: 'wikisource', url: page.url, license: '以页面标注的开放授权为准（通常为 CC BY-SA 4.0）' },
  };
}
