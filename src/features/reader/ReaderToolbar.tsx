import { ArrowLeft } from 'lucide-react';

type ReaderToolbarProps = { title: string; chapterTitle: string; chapterIndex: number; chapterCount: number; onBack: () => void };

export function ReaderToolbar({ title, chapterTitle, chapterIndex, chapterCount, onBack }: ReaderToolbarProps) {
  return (
    <header className="reader-toolbar">
      <button type="button" className="reader-back" onClick={onBack} aria-label="返回书架"><ArrowLeft size={18} /> <span>书架</span></button>
      <div className="reader-toolbar__title"><strong>{title}</strong><span>{chapterTitle} · {chapterIndex + 1}/{chapterCount}</span></div>
    </header>
  );
}
