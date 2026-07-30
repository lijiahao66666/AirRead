const CHINESE_CATALOG_SEARCH_API = '/api/book-sources/chinese-catalog';
const GUTENBERG_SEARCH_API = '/api/book-sources/gutenberg';
const MAX_RESULTS_PER_SOURCE = 6;

type Fetcher = typeof fetch;

export type PublicBookSourceResult = {
  id: string;
  title: string;
  author: string;
  description: string;
  provider: 'chinese-catalog' | 'gutenberg';
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

  const [chineseCatalog, gutenberg] = await Promise.allSettled([
    searchChineseCatalog(normalizedQuery, fetcher),
    searchGutenberg(normalizedQuery, fetcher),
  ]);
  const unavailableProviders = [
    ...(chineseCatalog.status === 'rejected' ? ['中文书目'] : []),
    ...(gutenberg.status === 'rejected' ? ['Project Gutenberg'] : []),
  ];
  if (unavailableProviders.length === 2) throw new Error('书目服务暂时无法连接，请稍后重试');

  return {
    results: [
      ...(chineseCatalog.status === 'fulfilled' ? chineseCatalog.value : []),
      ...(gutenberg.status === 'fulfilled' ? gutenberg.value : []),
    ],
    unavailableProviders,
  };
}

async function searchChineseCatalog(query: string, fetcher: Fetcher): Promise<PublicBookSourceResult[]> {
  const response = await fetcher(`${CHINESE_CATALOG_SEARCH_API}?${new URLSearchParams({ query })}`);
  if (!response.ok) throw new Error('中文书目暂时无法连接，请稍后重试');
  const payload = await response.json() as Array<{ id?: string; title?: string; url?: string; author_name?: string; year?: string }>;

  return payload.flatMap((item): PublicBookSourceResult[] => {
    if (!item.id || !item.title || !item.url) return [];
    return [{
      id: `chinese-catalog:${item.id}`,
      title: item.title,
      author: item.author_name || '作者未注明',
      description: [item.year, '中文书目'].filter(Boolean).join(' · '),
      provider: 'chinese-catalog',
      providerName: '中文书目 · 豆瓣读书',
      action: 'open',
      actionLabel: '查看书目',
      sourceUrl: item.url,
    }];
  }).slice(0, MAX_RESULTS_PER_SOURCE);
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
