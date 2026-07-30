import { ArrowLeft, BookOpen, Download, LoaderCircle, Search } from 'lucide-react';
import { FormEvent, useRef, useState } from 'react';

import type { Book } from '../../domain/books/book';
import { downloadGutenbergBook, searchGutenberg, type GutenbergSearchResult } from './gutenberg';

export type BookSourceSearchPageProps = {
  onBack: () => void;
  onImportBook: (book: Book) => void | Promise<void>;
  search?: (query: string) => Promise<GutenbergSearchResult[]>;
  download?: (result: GutenbergSearchResult) => Promise<Book>;
};

export function BookSourceSearchPage({ onBack, onImportBook, search = searchGutenberg, download = downloadGutenbergBook }: BookSourceSearchPageProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<GutenbergSearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [importingTitle, setImportingTitle] = useState<string>();
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
    setError(undefined);
    try {
      const nextResults = await search(query);
      if (requestId !== searchSequence.current) return;
      setResults(nextResults);
      setHasSearched(true);
    } catch (cause) {
      if (requestId !== searchSequence.current) return;
      setResults([]);
      setError(cause instanceof Error ? cause.message : '开放作品暂时无法连接，请稍后重试');
    } finally {
      if (requestId === searchSequence.current) setSearching(false);
    }
  };

  const importAndRead = async (result: GutenbergSearchResult) => {
    if (importingTitle) return;
    setImportingTitle(result.title);
    setError(undefined);
    try {
      await onImportBook(await download(result));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '导入作品失败，请稍后重试');
    } finally {
      setImportingTitle(undefined);
    }
  };

  return <section className="studio-page" aria-labelledby="book-source-search-title">
    <button type="button" className="studio-tool-back" onClick={onBack}><ArrowLeft size={17} /> 返回工作室</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 开放作品</p><h2 id="book-source-search-title">搜索并导入作品</h2><p className="page-lede">检索 Project Gutenberg 的英文公版 EPUB，导入后立即进入阅读。</p></div><BookOpen size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="studio-card source-search" aria-label="开放作品搜索">
      <div className="studio-card__heading"><div><p className="eyebrow">Project Gutenberg · 英文公版 EPUB</p><h3>搜索作品</h3></div><span>可直接阅读</span></div>
      <form className="source-search__form" onSubmit={(event) => { void submit(event); }}>
        <label><span className="sr-only">搜索开放作品</span><Search size={18} aria-hidden="true" /><input value={query} onChange={(event) => { setQuery(event.target.value); setHasSearched(false); }} placeholder="书名、作者或英文关键词" aria-label="搜索开放作品" /></label>
        <button className="primary-action" type="submit" disabled={searching || Boolean(importingTitle)}>{searching ? <LoaderCircle className="is-spinning" size={17} /> : <Search size={17} />} 搜索作品</button>
      </form>
      <p className="source-search__notice">仅显示可下载的英文公版 EPUB。导入内容保存在当前设备，授权说明随书籍来源一同保存。</p>
      {error && <p className="source-search__error" role="alert">{error}</p>}
      {results.length > 0 && <div className="source-search__results">{results.map((result) => <article key={result.title}>
        <div><span className="source-search__provider">Project Gutenberg · EPUB</span><h4>{result.title}</h4><p>{result.author}</p><small>{result.downloads || '公版作品'}</small></div>
        <button type="button" className="secondary-button" onClick={() => { void importAndRead(result); }} disabled={Boolean(importingTitle)}>{importingTitle === result.title ? <LoaderCircle className="is-spinning" size={16} /> : <Download size={16} />} {importingTitle === result.title ? '正在导入' : '导入并阅读'}</button>
      </article>)}</div>}
      {!searching && hasSearched && results.length === 0 && !error && <p className="source-search__empty">没有找到可导入的开放作品，换一个书名、作者或关键词试试。</p>}
    </section>
  </section>;
}
