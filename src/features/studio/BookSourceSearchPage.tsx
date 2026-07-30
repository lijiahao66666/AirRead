import { ArrowLeft, BookOpen, Download, ExternalLink, LoaderCircle, Search } from 'lucide-react';
import { FormEvent, useRef, useState } from 'react';

import type { Book } from '../../domain/books/book';
import { createWikisourceBook, loadWikisourcePage, type WikisourcePage } from './wikisource';
import { searchPublicBookSources, type PublicBookSourceResult, type PublicBookSourceSearch } from './publicBookSources';

export type BookSourceSearchPageProps = {
  onBack: () => void;
  onSaveBook: (book: Book) => void | Promise<void>;
  search?: (query: string) => Promise<PublicBookSourceSearch>;
  loadWikisourcePage?: (title: string) => Promise<WikisourcePage>;
};

export function BookSourceSearchPage({ onBack, onSaveBook, search = searchPublicBookSources, loadWikisourcePage: loadPage = loadWikisourcePage }: BookSourceSearchPageProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<PublicBookSourceResult[]>([]);
  const [unavailableProviders, setUnavailableProviders] = useState<string[]>([]);
  const [searching, setSearching] = useState(false);
  const [importingId, setImportingId] = useState<string>();
  const [notice, setNotice] = useState<string>();
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
    setNotice(undefined);
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
      setError(cause instanceof Error ? cause.message : '开放书源暂时无法连接，请稍后重试');
    } finally {
      if (requestId === searchSequence.current) setSearching(false);
    }
  };

  const importWikisource = async (result: PublicBookSourceResult) => {
    if (!result.sourceTitle) return;
    setImportingId(result.id);
    setError(undefined);
    setNotice(undefined);
    try {
      const page = await loadPage(result.sourceTitle);
      await onSaveBook(createWikisourceBook(page));
      setNotice(`《${page.title}》已添加到书架`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '导入中文维基文库文本失败，请稍后重试');
    } finally {
      setImportingId(undefined);
    }
  };

  return <section className="studio-page" aria-labelledby="book-source-search-title">
    <button type="button" className="studio-tool-back" onClick={onBack}><ArrowLeft size={17} /> 返回工作室</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 书籍搜索</p><h2 id="book-source-search-title">搜索书籍</h2><p className="page-lede">输入一次关键词，AirRead 会自动检索当前可用的开放资源，并在同一列表中汇总结果。</p></div><BookOpen size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="studio-card source-search" aria-label="开放书籍搜索">
      <div className="studio-card__heading"><div><p className="eyebrow">自动并行检索</p><h3>统一搜索</h3></div><span>自动聚合</span></div>
      <form className="source-search__form" onSubmit={(event) => { void submit(event); }}>
        <label><span className="sr-only">搜索开放书籍</span><Search size={18} aria-hidden="true" /><input value={query} onChange={(event) => { setQuery(event.target.value); setHasSearched(false); }} placeholder="书名、作者或关键词" aria-label="搜索开放书籍" /></label>
        <button className="primary-action" type="submit" disabled={searching}>{searching ? <LoaderCircle className="is-spinning" size={17} /> : <Search size={17} />} 搜索全部书源</button>
      </form>
      <p className="source-search__notice">仅展示可合法使用的开放资源。结果会标明可直接导入，或需先下载 EPUB 后从书架导入。</p>
      {unavailableProviders.length > 0 && <p className="source-search__partial" role="status">部分开放资源暂时不可用，已展示其他结果。</p>}
      {notice && <p className="source-search__success" role="status">{notice}</p>}
      {error && <p className="source-search__error" role="alert">{error}</p>}
      {results.length > 0 && <div className="source-search__results">{results.map((result) => <article key={result.id}>
        <div><span className="source-search__provider">{result.providerName}</span><h4>{result.title}</h4><p>{result.author}</p><small>{result.description}</small></div>
        {result.action === 'import'
          ? <button type="button" className="secondary-button" onClick={() => { void importWikisource(result); }} disabled={Boolean(importingId)}>{importingId === result.id ? <LoaderCircle className="is-spinning" size={16} /> : <Download size={16} />}{importingId === result.id ? '导入中' : '导入'}</button>
          : <a className="secondary-button" href={result.downloadUrl} target="_blank" rel="noreferrer">下载 EPUB <ExternalLink size={16} /></a>}
      </article>)}</div>}
      {!searching && hasSearched && results.length === 0 && !error && <p className="source-search__empty">没有找到可用的开放书籍，换一个书名、作者或英文关键词试试。</p>}
    </section>
  </section>;
}
