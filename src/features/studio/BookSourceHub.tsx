import { ArrowLeft, BookOpen, ChevronRight, Globe2 } from 'lucide-react';

export type BookSourceHubProps = {
  onBack: () => void;
  onOpenWikisource: () => void;
  onOpenZlibrary: () => void;
};

export function BookSourceHub({ onBack, onOpenWikisource, onOpenZlibrary }: BookSourceHubProps) {
  return <section className="studio-page" aria-labelledby="book-source-hub-title">
    <button type="button" className="studio-tool-back" onClick={onBack}><ArrowLeft size={17} /> 返回工作室</button>
    <header className="studio-page__header studio-page__header--tool"><div><p className="eyebrow">书籍工作室 · 书源中心</p><h2 id="book-source-hub-title">书源中心</h2><p className="page-lede">选择书源发现书籍；导入或下载后的文件始终由你保存在当前设备。</p></div><BookOpen size={40} strokeWidth={1.35} aria-hidden="true" /></header>
    <section className="studio-card source-hub" aria-label="可用书源">
      <div className="studio-card__heading"><div><p className="eyebrow">可用书源</p><h3>选择一个书源</h3></div><span>2 个书源</span></div>
      <div className="source-hub__list">
        <button type="button" className="source-hub__row" onClick={onOpenWikisource} aria-label="打开中文维基文库">
          <span className="source-hub__icon"><BookOpen size={21} aria-hidden="true" /></span>
          <span className="source-hub__content"><strong>中文维基文库</strong><small>搜索可公开导入的中文文本，保存后可离线阅读与翻译。</small></span>
          <ChevronRight size={20} aria-hidden="true" />
        </button>
        <button type="button" className="source-hub__row" onClick={onOpenZlibrary} aria-label="打开 Z-Library 与镜像">
          <span className="source-hub__icon"><Globe2 size={21} aria-hidden="true" /></span>
          <span className="source-hub__content"><strong>Z-Library 与镜像</strong><small>使用预设入口或你的可用镜像在外部检索，下载后再导入书架。</small></span>
          <ChevronRight size={20} aria-hidden="true" />
        </button>
      </div>
    </section>
  </section>;
}
