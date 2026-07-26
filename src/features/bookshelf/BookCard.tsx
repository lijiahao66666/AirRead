import { Clock3, Trash2 } from 'lucide-react';

import type { Book } from '../../domain/books/book';
import { BookCover } from '../../ui/BookCover';

type BookCardProps = {
  book: Book;
  onOpen: (id: string) => void;
  onDelete: (id: string) => void;
};

export function BookCard({ book, onOpen, onDelete }: BookCardProps) {
  const progress = Math.round(Math.max(0, Math.min(1, book.readingProgress)) * 100);
  return (
    <article className="book-card">
      <a className="book-card__open" href={`#reader/${book.id}`} onClick={(event) => { event.preventDefault(); onOpen(book.id); }} aria-label={`阅读 ${book.title}，进度 ${progress}%`}>
        <div className="book-card__cover" aria-hidden="true">
          <BookCover src={book.coverDataUrl} />
        </div>
        <div className="book-card__body">
          <h3>{book.title}</h3>
          <p>{book.author || (book.format === 'epub' ? 'EPUB 书籍' : 'TXT 文本')}</p>
          <div className="book-card__progress-meta"><span><Clock3 size={15} /> 阅读进度</span><strong>{progress}%</strong></div>
          <div className="book-card__progress" aria-hidden="true">
            <span style={{ width: `${progress}%` }} />
          </div>
        </div>
      </a>
      <button type="button" className="icon-button book-card__delete" onClick={() => onDelete(book.id)} aria-label={`删除 ${book.title}`}>
        <Trash2 size={17} />
      </button>
    </article>
  );
}
