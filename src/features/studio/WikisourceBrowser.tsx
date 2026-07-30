import { ArrowLeft, BookOpen, Download, ExternalLink, LoaderCircle, Search } from 'lucide-react';
import { FormEvent, useState } from 'react';

import type { Book } from '../../domain/books/book';
import { createWikisourceBook, loadWikisourcePage, searchWikisource, type WikisourcePage, type WikisourceSearchResult } from './wikisource';

export type WikisourceBrowserProps = {
  onSaveBook: (book: Book) => void | Promise<void>;
  onBack: () => void;
  backLabel?: string;
  search?: (query: string) => Promise<WikisourceSearchResult[]>;
  loadPage?: (title: string) => Promise<WikisourcePage>;
};

export function WikisourceBrowser({ onSaveBook, onBack, backLabel = '返回工具列表', search = searchWikisource, loadPage = loadWikisourcePage }: WikisourceBrowserProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<WikisourceSearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [importingTitle, setImportingTitle] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [error, setError] = useState<string>();

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!query.trim()) return;
    setSearching(true);
    setError(undefined);
    setNotice(undefined);
    try { setResults(await search(query)); }
    catch (cause) { setResults([]); setError(cause instanceof Error ? cause.message : '搜索公开书源失败'); }
    finally { setSearching(false); }
  };
  const importPage = async (title: string) => {
    setImportingTitle(title);
    setError(undefined);
    setNotice(undefined);
    try {
      const page = await loadPage(title);
      await onSaveBook(createWikisourceBook(page));
      setNotice(`《${page.title}》已添加到书架`);
    } catch (cause) { setError(cause instanceof Error ? cause.message : '导入公开书籍失败'); }
    finally { setImportingTitle(undefined); }
  };

  return <section className="studio-page" aria-labelledby="wikisource-title">
    <button type="button" className="studio-tool-back" onClick={onBack}><ArrowLeft size={17} /> {backLabel}</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 公开书源</p><h2 id="wikisource-title">中文维基文库</h2><p className="page-lede">搜索并导入标注开放授权的中文文本。导入后书籍保存在当前设备，可离线阅读和翻译。</p></div><BookOpen size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="studio-card wikisource-browser">
      <div className="studio-card__heading"><div><p className="eyebrow">公开书源</p><h3>找一本可读的文本</h3></div><a className="text-button" href="https://zh.wikisource.org" target="_blank" rel="noreferrer">访问站点 <ExternalLink size={15} /></a></div>
      <form className="wikisource-search" onSubmit={(event) => { void submit(event); }}><label><span className="sr-only">搜索中文维基文库</span><Search size={18} aria-hidden="true" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索书名、作者或篇目" aria-label="搜索中文维基文库" /></label><button className="primary-action" type="submit" disabled={searching}>{searching ? <LoaderCircle className="is-spinning" size={17} /> : <Search size={17} />} 搜索</button></form>
      <p className="wikisource-browser__notice">长篇作品常按章节拆分；可以用“书名 + 回目”搜索后逐章导入。请以页面标注的授权信息为准。</p>
      {notice && <p className="wikisource-browser__success" role="status">{notice}</p>}
      {error && <p className="wikisource-browser__error" role="alert">{error}</p>}
      {results.length > 0 && <div className="wikisource-results">{results.map((result) => <article key={result.title}><div><h4>{result.title}</h4>{result.snippet && <p>{result.snippet}</p>}<small>{result.wordCount > 0 ? `${result.wordCount.toLocaleString()} 字` : '公开文本'}</small></div><button type="button" className="secondary-button" onClick={() => { void importPage(result.title); }} disabled={Boolean(importingTitle)}>{importingTitle === result.title ? <LoaderCircle className="is-spinning" size={16} /> : <Download size={16} />}{importingTitle === result.title ? '导入中' : '导入'}</button></article>)}</div>}
      {!searching && query.trim() && results.length === 0 && !error && <p className="wikisource-browser__empty">没有找到匹配页面，换一个书名或作者试试。</p>}
    </section>
  </section>;
}
