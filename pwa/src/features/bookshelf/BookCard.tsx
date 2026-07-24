import { BookOpen, Clock3, Trash2 } from 'lucide-react';

import type { Book } from '../../domain/books/book';

type BookCardProps = {
  book: Book;
  onOpen: (id: string) => void;
  onDelete: (id: string) => void;
};

export function BookCard({ book, onOpen, onDelete }: BookCardProps) {
  const progress = Math.round(Math.max(0, Math.min(1, book.readingProgress)) * 100);
  return (
    <article className="book-card">
      <div className="book-card__cover" aria-hidden="true">
        {book.coverDataUrl ? <img src={book.coverDataUrl} alt="" /> : <BookOpen size={30} strokeWidth={1.5} />}
      </div>
      <div className="book-card__body">
        <h3>{book.title}</h3>
        <p>{book.author || (book.format === 'epub' ? 'EPUB 书籍' : 'TXT 文本')}</p>
        <div className="book-card__progress" aria-label={`阅读进度 ${progress}%`}>
          <span style={{ width: `${progress}%` }} />
        </div>
        <div className="book-card__actions">
          <button type="button" className="book-open-action" onClick={() => onOpen(book.id)} aria-label={`打开 ${book.title}`}>
            <Clock3 size={15} /> {progress > 0 ? '继续阅读' : '开始阅读'}
          </button>
          <button type="button" className="icon-button" onClick={() => onDelete(book.id)} aria-label={`删除 ${book.title}`}>
            <Trash2 size={16} />
          </button>
        </div>
      </div>
    </article>
  );
}
