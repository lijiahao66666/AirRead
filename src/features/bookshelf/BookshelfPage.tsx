import { ChangeEvent, useMemo, useRef, useState } from 'react';
import { BookOpen, ChevronRight, Search, Upload } from 'lucide-react';

import type { Book } from '../../domain/books/book';
import { BookCard } from './BookCard';

export type BookshelfPageProps = {
  books: Book[];
  loading?: boolean;
  error?: string;
  onImport: (file: File) => void | Promise<void>;
  onOpen: (bookId: string) => void;
  onDelete: (bookId: string) => void;
  onSearch?: (query: string) => void;
};

export function BookshelfPage({ books, loading = false, error, onImport, onOpen, onDelete, onSearch }: BookshelfPageProps) {
  const [query, setQuery] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const filteredBooks = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    if (!normalized) return books;
    return books.filter((book) => `${book.title} ${book.author}`.toLocaleLowerCase().includes(normalized));
  }, [books, query]);
  const continueBook = books
    .filter((book) => book.lastReadAt != null || book.readingProgress > 0)
    .sort((left, right) => (right.lastReadAt ?? 0) - (left.lastReadAt ?? 0))[0];
  const handleImport = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) void onImport(file);
    event.target.value = '';
  };
  const handleDelete = (bookId: string) => {
    const target = books.find((book) => book.id === bookId);
    if (window.confirm(`确定从书架删除《${target?.title || '这本书'}》吗？`)) onDelete(bookId);
  };

  return (
    <section className="bookshelf-page" aria-labelledby="bookshelf-title">
      <div className="bookshelf-page__header">
        <div>
          <p className="eyebrow">阅读空间</p>
          <h2 id="bookshelf-title">我的书架</h2>
          <p className="page-lede">导入 EPUB 或 TXT，在当前设备继续阅读、生成本章双语、划词翻译或朗读原文。</p>
        </div>
        <div className="bookshelf-page__actions">
          <button className="primary-action import-action" type="button" onClick={() => inputRef.current?.click()}><Upload size={17} /> 导入书籍</button>
          <input ref={inputRef} className="import-input" type="file" accept=".epub,.txt,application/epub+zip,text/plain" onChange={handleImport} aria-label="导入 EPUB 或 TXT" />
        </div>
      </div>
      {continueBook && (
        <button className="continue-card" type="button" onClick={() => onOpen(continueBook.id)}>
          <span className="continue-card__icon"><BookOpen size={22} /></span>
          <span><small>继续阅读</small><strong>{continueBook.title}</strong><em>{Math.round(continueBook.readingProgress * 100)}% 已读</em></span>
          <span className="continue-card__arrow" aria-hidden="true"><ChevronRight size={20} /></span>
        </button>
      )}
      <div className="bookshelf-toolbar">
        <h3>全部书籍 <span>{books.length}</span></h3>
        <label className="search-field"><Search size={17} /><span className="sr-only">搜索书架</span><input type="search" aria-label="搜索书架" placeholder="搜索书名或作者" value={query} onChange={(event) => { setQuery(event.target.value); onSearch?.(event.target.value); }} /></label>
      </div>
      {loading && <div className="state-card" role="status">正在读取书架</div>}
      {error && <div className="state-card state-card--error" role="alert">{error}</div>}
      {!loading && !error && books.length === 0 && <div className="state-card state-card--empty"><BookOpen size={28} /><strong>书架还是空的</strong><p>导入一本 EPUB 或 TXT，开始第一段双语阅读。</p><button className="primary-action" type="button" onClick={() => inputRef.current?.click()}><Upload size={17} /> 导入第一本书</button></div>}
      {!loading && !error && books.length > 0 && filteredBooks.length === 0 && <div className="state-card">没有找到匹配的书籍</div>}
      {!loading && !error && filteredBooks.length > 0 && <div className="book-grid">{filteredBooks.map((book) => <BookCard key={book.id} book={book} onOpen={onOpen} onDelete={handleDelete} />)}</div>}
    </section>
  );
}
