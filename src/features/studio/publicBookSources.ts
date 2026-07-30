const CHINESE_CATALOG_SEARCH_API = '/api/book-sources/chinese-catalog';
const MAX_RESULTS_PER_SOURCE = 6;

type Fetcher = typeof fetch;

export type PublicBookSourceResult = {
  id: string;
  title: string;
  author: string;
  description: string;
  provider: 'chinese-catalog';
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

  const results = await searchChineseCatalog(normalizedQuery, fetcher);
  return {
    results,
    unavailableProviders: [],
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
