import { ArrowLeft, ChevronLeft, ChevronRight } from 'lucide-react';

type ReaderToolbarProps = { title: string; chapterTitle: string; chapterIndex: number; chapterCount: number; onBack: () => void; onPrevious: () => void; onNext: () => void };

export function ReaderToolbar({ title, chapterTitle, chapterIndex, chapterCount, onBack, onPrevious, onNext }: ReaderToolbarProps) {
  return (
    <header className="reader-toolbar">
      <button type="button" className="reader-back" onClick={onBack} aria-label="返回书架"><ArrowLeft size={18} /> <span>书架</span></button>
      <div className="reader-toolbar__title"><strong>{title}</strong><span>{chapterTitle} · {chapterIndex + 1}/{chapterCount}</span></div>
      <div className="reader-toolbar__chapters"><button type="button" onClick={onPrevious} disabled={chapterIndex === 0} aria-label="上一章"><ChevronLeft size={19} /></button><button type="button" onClick={onNext} disabled={chapterIndex >= chapterCount - 1} aria-label="下一章"><ChevronRight size={19} /></button></div>
    </header>
  );
}
