import { ArrowLeft, BookOpen, ExternalLink, Globe2, Plus, Search, Trash2 } from 'lucide-react';
import { FormEvent, useMemo, useState } from 'react';

import { buildZLibrarySearchUrl, loadZLibrarySources, saveZLibrarySources, validateZLibrarySearchTemplate, type ZLibrarySource } from './zlibrary';

export type ZLibraryBrowserProps = {
  onBack: () => void;
  openSearch?: (url: string) => void;
  storage?: Storage;
};

const browserStorage = (): Storage => window.localStorage;

export function ZLibraryBrowser({ onBack, openSearch = (url) => { window.open(url, '_blank', 'noopener,noreferrer'); }, storage = browserStorage() }: ZLibraryBrowserProps) {
  const [sources, setSources] = useState(() => loadZLibrarySources(storage));
  const [sourceId, setSourceId] = useState(sources[0].id);
  const [query, setQuery] = useState('');
  const [notice, setNotice] = useState<string>();
  const [error, setError] = useState<string>();
  const [showEditor, setShowEditor] = useState(false);
  const [sourceName, setSourceName] = useState('');
  const [searchTemplate, setSearchTemplate] = useState('');
  const activeSource = useMemo(() => sources.find((source) => source.id === sourceId) ?? sources[0], [sourceId, sources]);

  const submitSearch = (event: FormEvent) => {
    event.preventDefault();
    setError(undefined);
    setNotice(undefined);
    try {
      openSearch(buildZLibrarySearchUrl(activeSource.searchTemplate, query));
      setNotice(`已在“${activeSource.name}”中打开检索结果`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '无法打开检索页');
    }
  };

  const addSource = (event: FormEvent) => {
    event.preventDefault();
    setError(undefined);
    const name = sourceName.trim();
    if (!name) {
      setError('请填写镜像名称');
      return;
    }
    try {
      const nextSource: ZLibrarySource = {
        id: `zlibrary-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        name,
        searchTemplate: validateZLibrarySearchTemplate(searchTemplate),
      };
      const nextSources = [...sources, nextSource];
      saveZLibrarySources(nextSources, storage);
      setSources(nextSources);
      setSourceId(nextSource.id);
      setSourceName('');
      setSearchTemplate('');
      setShowEditor(false);
      setNotice(`“${name}”已保存到当前设备`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '无法保存镜像地址');
    }
  };

  const removeSource = (source: ZLibrarySource) => {
    if (source.builtIn) return;
    const nextSources = sources.filter((item) => item.id !== source.id);
    saveZLibrarySources(nextSources, storage);
    setSources(nextSources);
    if (sourceId === source.id) setSourceId(nextSources[0].id);
    setNotice(`“${source.name}”已移除`);
    setError(undefined);
  };

  return <section className="studio-page" aria-labelledby="zlibrary-title">
    <button type="button" className="studio-tool-back" onClick={onBack}><ArrowLeft size={17} /> 返回工具列表</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 外部书源</p><h2 id="zlibrary-title">Z-Library 与镜像</h2><p className="page-lede">用选定的入口搜索书籍；下载后再导入 AirRead，即可离线阅读、翻译与摘录。</p></div><BookOpen size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="studio-card zlibrary-browser">
      <div className="studio-card__heading"><div><p className="eyebrow">外部检索</p><h3>查找书籍</h3></div><button type="button" className="text-button" onClick={() => { setShowEditor((current) => !current); setError(undefined); }} aria-expanded={showEditor}><Globe2 size={15} /> 镜像管理</button></div>
      <form className="zlibrary-search" onSubmit={submitSearch}>
        <label><span>检索入口</span><select aria-label="Z-Library 检索入口" value={activeSource.id} onChange={(event) => { setSourceId(event.target.value); setNotice(undefined); setError(undefined); }}>{sources.map((source) => <option key={source.id} value={source.id}>{source.name}</option>)}</select></label>
        <label><span className="sr-only">搜索 Z-Library</span><Search size={18} aria-hidden="true" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="书名、作者或 ISBN" aria-label="搜索 Z-Library" /></label>
        <button className="primary-action" type="submit"><Search size={17} /> 外部搜索</button>
      </form>
      <p className="zlibrary-browser__notice">检索词会直接发送到你选定的站点。AirRead 不代理站点、不会代存账户信息或提供书籍文件；请确认使用和导入的内容符合当地法律及版权授权。</p>
      {showEditor && <form className="zlibrary-editor" onSubmit={addSource} aria-label="添加镜像">
        <div><p className="eyebrow">本地配置</p><h4>添加可用镜像</h4><p>填写站点提供的检索地址模板，必须保留 <code>{'{query}'}</code> 作为搜索词占位符。</p></div>
        <label>镜像名称<input value={sourceName} onChange={(event) => setSourceName(event.target.value)} placeholder="例如：我的 Z-Library 镜像" /></label>
        <label>检索地址模板<input value={searchTemplate} onChange={(event) => setSearchTemplate(event.target.value)} placeholder="https://example.com/s/{query}" inputMode="url" autoCapitalize="none" /></label>
        <div className="zlibrary-editor__actions"><button type="button" className="secondary-button" onClick={() => { setShowEditor(false); setSourceName(''); setSearchTemplate(''); setError(undefined); }}>取消</button><button type="submit" className="primary-action"><Plus size={17} /> 保存镜像</button></div>
      </form>}
      {sources.length > 1 && <div className="zlibrary-sources" aria-label="已保存镜像">{sources.filter((source) => !source.builtIn).map((source) => <div key={source.id}><div><strong>{source.name}</strong><small>{source.searchTemplate}</small></div><button type="button" className="icon-button" aria-label={`删除 ${source.name}`} onClick={() => removeSource(source)}><Trash2 size={16} /></button></div>)}</div>}
      {notice && <p className="wikisource-browser__success" role="status">{notice}</p>}
      {error && <p className="wikisource-browser__error" role="alert">{error}</p>}
      <div className="zlibrary-browser__import"><ExternalLink size={17} /><span>从外部站点取得文件后，回到“我的书架”选择“导入书籍”即可开始阅读。</span></div>
    </section>
  </section>;
}
