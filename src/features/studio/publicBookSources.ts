import { searchWikisource } from './wikisource';

const ARCHIVE_SEARCH_API = 'https://archive.org/advancedsearch.php';
const ARCHIVE_METADATA_API = 'https://archive.org/metadata/';
const ARCHIVE_DOWNLOAD_BASE = 'https://archive.org/download/';
const ARCHIVE_DETAILS_BASE = 'https://archive.org/details/';
const MAX_ARCHIVE_RESULTS = 6;

type Fetcher = typeof fetch;

export type PublicBookSourceResult = {
  id: string;
  title: string;
  author: string;
  description: string;
  provider: 'wikisource' | 'archive-gutenberg';
  providerName: string;
  action: 'import' | 'download';
  sourceTitle?: string;
  downloadUrl?: string;
  sourceUrl: string;
};

export type PublicBookSourceSearch = {
  results: PublicBookSourceResult[];
  unavailableProviders: string[];
};

export async function searchPublicBookSources(query: string, fetcher: Fetcher = fetch): Promise<PublicBookSourceSearch> {
  const normalizedQuery = query.trim();
  if (!normalizedQuery) return { results: [], unavailableProviders: [] };

  const [wikisource, archive] = await Promise.allSettled([
    searchWikisource(normalizedQuery, fetcher),
    searchArchiveGutenberg(normalizedQuery, fetcher),
  ]);
  const unavailableProviders = [
    ...(wikisource.status === 'rejected' ? ['中文维基文库'] : []),
    ...(archive.status === 'rejected' ? ['Gutenberg 公共领域书库'] : []),
  ];
  if (unavailableProviders.length === 2) throw new Error('开放书源暂时无法连接，请稍后重试');

  return {
    results: [
      ...(wikisource.status === 'fulfilled' ? wikisource.value.map((result): PublicBookSourceResult => ({
        id: `wikisource:${result.title}`,
        title: result.title,
        author: '中文维基文库',
        description: result.snippet || (result.wordCount > 0 ? `${result.wordCount.toLocaleString()} 字开放文本` : '开放文本'),
        provider: 'wikisource',
        providerName: '中文维基文库',
        action: 'import',
        sourceTitle: result.title,
        sourceUrl: `https://zh.wikisource.org/wiki/${encodeURIComponent(result.title.replace(/ /gu, '_'))}`,
      })) : []),
      ...(archive.status === 'fulfilled' ? archive.value : []),
    ],
    unavailableProviders,
  };
}

async function searchArchiveGutenberg(query: string, fetcher: Fetcher): Promise<PublicBookSourceResult[]> {
  const search = new URLSearchParams({
    q: `collection:gutenberg AND (${query.replace(/["\\]/gu, ' ').trim()})`,
    'fl[]': 'identifier,title,creator,year',
    rows: String(MAX_ARCHIVE_RESULTS),
    output: 'json',
  });
  const response = await fetcher(`${ARCHIVE_SEARCH_API}?${search}`);
  if (!response.ok) throw new Error('Gutenberg 公共领域书库暂时无法连接，请稍后重试');
  const payload = await response.json() as { response?: { docs?: Array<{ identifier?: string; title?: string; creator?: string | string[]; year?: string | number }> } };
  const candidates = (payload.response?.docs ?? []).flatMap((item) => item.identifier && item.title ? [{
    identifier: item.identifier,
    title: item.title,
    author: Array.isArray(item.creator) ? item.creator.join('、') : item.creator ?? '作者未注明',
    year: item.year ? String(item.year) : '',
  }] : []);
  const downloads = await Promise.allSettled(candidates.map((candidate) => loadArchiveEpub(candidate.identifier, fetcher)));

  return candidates.flatMap((candidate, index): PublicBookSourceResult[] => {
    const download = downloads[index];
    if (download.status !== 'fulfilled' || !download.value) return [];
    return [{
      id: `archive-gutenberg:${candidate.identifier}`,
      title: candidate.title,
      author: candidate.author,
      description: [candidate.year, '公共领域 EPUB'].filter(Boolean).join(' · '),
      provider: 'archive-gutenberg',
      providerName: 'Gutenberg 公共领域书库',
      action: 'download',
      downloadUrl: download.value,
      sourceUrl: `${ARCHIVE_DETAILS_BASE}${encodeURIComponent(candidate.identifier)}`,
    }];
  });
}

async function loadArchiveEpub(identifier: string, fetcher: Fetcher): Promise<string | undefined> {
  const response = await fetcher(`${ARCHIVE_METADATA_API}${encodeURIComponent(identifier)}`);
  if (!response.ok) throw new Error('无法读取 EPUB 下载信息');
  const payload = await response.json() as { files?: Array<{ name?: string; format?: string }> };
  const epub = payload.files?.find((file) => file.format === 'EPUB' && file.name);
  return epub?.name ? `${ARCHIVE_DOWNLOAD_BASE}${encodeURIComponent(identifier)}/${encodeURIComponent(epub.name)}` : undefined;
}
