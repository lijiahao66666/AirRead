const CLASSICS_SEARCH_API = '/api/book-sources/classics';
const GUTENBERG_SEARCH_API = '/api/book-sources/gutenberg';
const MAX_RESULTS_PER_SOURCE = 6;

type Fetcher = typeof fetch;

export type PublicBookSourceResult = {
  id: string;
  title: string;
  author: string;
  description: string;
  provider: 'classics-index' | 'gutenberg';
  providerName: string;
  action: 'open';
  actionLabel: string;
  sourceUrl: string;
};

export type PublicBookSourceSearch = {
  results: PublicBookSourceResult[];
  unavailableProviders: string[];
};

export async function searchPublicBookSources(query: string, fetcher: Fetcher = fetch): Promise<PublicBookSourceSearch> {
  const normalizedQuery = query.trim();
  if (!normalizedQuery) return { results: [], unavailableProviders: [] };

  const [classics, gutenberg] = await Promise.allSettled([
    searchClassicsIndex(normalizedQuery, fetcher),
    searchGutenberg(normalizedQuery, fetcher),
  ]);
  const unavailableProviders = [
    ...(classics.status === 'rejected' ? ['中文典籍索引'] : []),
    ...(gutenberg.status === 'rejected' ? ['Project Gutenberg'] : []),
  ];
  if (unavailableProviders.length === 2) throw new Error('开放书源暂时无法连接，请稍后重试');

  return {
    results: [
      ...(classics.status === 'fulfilled' ? classics.value : []),
      ...(gutenberg.status === 'fulfilled' ? gutenberg.value : []),
    ],
    unavailableProviders,
  };
}

async function searchClassicsIndex(query: string, fetcher: Fetcher): Promise<PublicBookSourceResult[]> {
  const response = await fetcher(`${CLASSICS_SEARCH_API}?${new URLSearchParams({ query })}`);
  if (!response.ok) throw new Error('中文典籍索引暂时无法连接，请稍后重试');
  const html = await response.text();
  const document = new DOMParser().parseFromString(html, 'text/html');
  const seen = new Set<string>();

  return [...document.querySelectorAll<HTMLAnchorElement>('a[href^="/guwen/book"]')]
    .flatMap((anchor): PublicBookSourceResult[] => {
      const href = anchor.getAttribute('href');
      const title = normalizedText(anchor.textContent);
      if (!href || !title || seen.has(href)) return [];
      seen.add(href);
      const container = anchor.closest('div[id^="zhengwen"]');
      const description = normalizedText(container?.querySelector('.contson')?.textContent).slice(0, 170) || '中文传统典籍页面';
      const metadata = [...(container?.querySelectorAll('div[style*="display: flex"] span') ?? [])]
        .map((element) => normalizedText(element.textContent))
        .filter(Boolean);
      const author = metadata.find((value) => !/名句|先秦|经部|史部|子部|集部|类$/u.test(value)) ?? '中文传统典籍';

      return [{
        id: `classics-index:${href}`,
        title,
        author,
        description,
        provider: 'classics-index',
        providerName: '中文典籍索引 · 古文岛',
        action: 'open',
        actionLabel: '前往阅读',
        sourceUrl: new URL(href, 'https://www.guwendao.net').toString(),
      }];
    })
    .slice(0, MAX_RESULTS_PER_SOURCE);
}

async function searchGutenberg(query: string, fetcher: Fetcher): Promise<PublicBookSourceResult[]> {
  const response = await fetcher(`${GUTENBERG_SEARCH_API}?${new URLSearchParams({ query })}`);
  if (!response.ok) throw new Error('Project Gutenberg 暂时无法连接，请稍后重试');
  const payload = await response.json() as {
    results?: Array<{ id?: number; title?: string; authors?: Array<{ name?: string }>; download_count?: number }>;
  };

  return (payload.results ?? []).flatMap((item): PublicBookSourceResult[] => {
    if (!item.id || !item.title) return [];
    const author = item.authors?.map((person) => person.name).filter((name): name is string => Boolean(name)).join('、') || '作者未注明';
    return [{
      id: `gutenberg:${item.id}`,
      title: item.title,
      author,
      description: `${Number(item.download_count ?? 0).toLocaleString()} 次下载 · 公共领域书目`,
      provider: 'gutenberg',
      providerName: 'Project Gutenberg',
      action: 'open',
      actionLabel: '查看书目',
      sourceUrl: `https://www.gutenberg.org/ebooks/${item.id}`,
    }];
  }).slice(0, MAX_RESULTS_PER_SOURCE);
}

function normalizedText(value: string | null | undefined): string {
  return (value ?? '').replace(/\s+/gu, ' ').trim();
}
