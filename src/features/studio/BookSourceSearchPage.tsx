import { ArrowLeft, BookOpen, ExternalLink, LoaderCircle, Search } from 'lucide-react';
import { FormEvent, useRef, useState } from 'react';

import { searchPublicBookSources, type PublicBookSourceResult, type PublicBookSourceSearch } from './publicBookSources';

export type BookSourceSearchPageProps = {
  onBack: () => void;
  search?: (query: string) => Promise<PublicBookSourceSearch>;
};

export function BookSourceSearchPage({ onBack, search = searchPublicBookSources }: BookSourceSearchPageProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<PublicBookSourceResult[]>([]);
  const [unavailableProviders, setUnavailableProviders] = useState<string[]>([]);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string>();
  const [hasSearched, setHasSearched] = useState(false);
  const searchSequence = useRef(0);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!query.trim()) return;
    const requestId = ++searchSequence.current;
    setSearching(true);
    setHasSearched(false);
    setResults([]);
    setUnavailableProviders([]);
    setError(undefined);
    try {
      const response = await search(query);
      if (requestId !== searchSequence.current) return;
      setResults(response.results);
      setUnavailableProviders(response.unavailableProviders);
      setHasSearched(true);
    } catch (cause) {
      if (requestId !== searchSequence.current) return;
      setResults([]);
      setUnavailableProviders([]);
      setError(cause instanceof Error ? cause.message : '书目服务暂时无法连接，请稍后重试');
    } finally {
      if (requestId === searchSequence.current) setSearching(false);
    }
  };

  return <section className="studio-page" aria-labelledby="book-source-search-title">
    <button type="button" className="studio-tool-back" onClick={onBack}><ArrowLeft size={17} /> 返回工作室</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 书籍搜索</p><h2 id="book-source-search-title">搜索书籍</h2><p className="page-lede">输入一次关键词，AirRead 会汇总当前可访问的中文书目与公共领域书目。</p></div><BookOpen size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="studio-card source-search" aria-label="书籍搜索">
      <div className="studio-card__heading"><div><p className="eyebrow">自动并行检索</p><h3>统一搜索</h3></div><span>自动聚合</span></div>
      <form className="source-search__form" onSubmit={(event) => { void submit(event); }}>
        <label><span className="sr-only">搜索开放书籍</span><Search size={18} aria-hidden="true" /><input value={query} onChange={(event) => { setQuery(event.target.value); setHasSearched(false); }} placeholder="书名、作者或关键词" aria-label="搜索开放书籍" /></label>
        <button className="primary-action" type="submit" disabled={searching}>{searching ? <LoaderCircle className="is-spinning" size={17} /> : <Search size={17} />} 搜索全部书源</button>
      </form>
      <p className="source-search__notice">仅提供书目检索与来源跳转；书籍正文、下载方式与授权以来源页面为准。</p>
      {unavailableProviders.length > 0 && <p className="source-search__partial" role="status">{unavailableProviders.join('、')} 暂时不可用，已展示其他来源的结果。</p>}
      {error && <p className="source-search__error" role="alert">{error}</p>}
      {results.length > 0 && <div className="source-search__results">{results.map((result) => <article key={result.id}>
        <div><span className="source-search__provider">{result.providerName}</span><h4>{result.title}</h4><p>{result.author}</p><small>{result.description}</small></div>
        <a className="secondary-button" href={result.sourceUrl} target="_blank" rel="noreferrer">{result.actionLabel} <ExternalLink size={16} /></a>
      </article>)}</div>}
      {!searching && hasSearched && results.length === 0 && !error && <p className="source-search__empty">没有找到可用书目，换一个书名、作者或关键词试试。</p>}
    </section>
  </section>;
}
