import { ArrowLeft, Bookmark, BookmarkCheck } from 'lucide-react';

type ReaderToolbarProps = { title: string; chapterTitle: string; chapterIndex: number; chapterCount: number; bookmarked: boolean; onBack: () => void; onToggleBookmark: () => void };

export function ReaderToolbar({ title, chapterTitle, chapterIndex, chapterCount, bookmarked, onBack, onToggleBookmark }: ReaderToolbarProps) {
  return (
    <header className="reader-toolbar">
      <button type="button" className="reader-back" onClick={onBack} aria-label="返回书架"><ArrowLeft size={18} /> <span>书架</span></button>
      <div className="reader-toolbar__title"><strong>{title}</strong><span>{chapterTitle} · {chapterIndex + 1}/{chapterCount}</span></div>
      <button type="button" className={`reader-toolbar__action ${bookmarked ? 'is-active' : ''}`} onClick={onToggleBookmark} aria-label={bookmarked ? '移除当前书签' : '添加当前书签'} aria-pressed={bookmarked}>{bookmarked ? <BookmarkCheck size={18} /> : <Bookmark size={18} />}</button>
    </header>
  );
}
