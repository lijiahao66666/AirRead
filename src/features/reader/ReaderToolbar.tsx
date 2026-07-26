import { ArrowLeft, ChevronLeft, ChevronRight, List, Settings2 } from 'lucide-react';

type ReaderToolbarProps = { title: string; chapterTitle: string; chapterIndex: number; chapterCount: number; onBack: () => void; onPrevious: () => void; onNext: () => void; onOpenContents: () => void; onOpenSettings: () => void };

export function ReaderToolbar({ title, chapterTitle, chapterIndex, chapterCount, onBack, onPrevious, onNext, onOpenContents, onOpenSettings }: ReaderToolbarProps) {
  return (
    <header className="reader-toolbar">
      <button type="button" className="reader-back" onClick={onBack} aria-label="返回书架"><ArrowLeft size={18} /> <span>书架</span></button>
      <div className="reader-toolbar__title"><strong>{title}</strong><span>{chapterTitle} · {chapterIndex + 1}/{chapterCount}</span></div>
      <div className="reader-toolbar__actions">
        <button type="button" onClick={onOpenContents} aria-label="打开目录"><List size={18} /></button>
        <button type="button" onClick={onOpenSettings} aria-label="打开阅读设置"><Settings2 size={18} /></button>
      </div>
      <div className="reader-toolbar__chapters" aria-label="章节切换"><button type="button" onClick={onPrevious} disabled={chapterIndex === 0} aria-label="上一章"><ChevronLeft size={19} /></button><button type="button" onClick={onNext} disabled={chapterIndex >= chapterCount - 1} aria-label="下一章"><ChevronRight size={19} /></button></div>
    </header>
  );
}
