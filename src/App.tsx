import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, BookOpen, LibraryBig, Settings2, Sparkles } from 'lucide-react';

import { parseBook } from './domain/books/bookParser';
import { createBookStore } from './domain/books/bookStore';
import type { Book } from './domain/books/book';
import { BookshelfPage } from './features/bookshelf/BookshelfPage';
import { ReaderPage } from './features/reader/ReaderPage';
import { BookStudioPage } from './features/studio/BookStudioPage';
import { SettingsPage } from './features/settings/SettingsPage';
import { ProviderProfileStore } from './domain/ai/providerStore';
import './styles/global.css';

type AppRoute = 'bookshelf' | 'reader' | 'studio' | 'settings';
type AppLocation = { route: AppRoute; bookId?: string };
const primaryNavigation: Array<{ label: string; route: Exclude<AppRoute, 'reader'>; icon: typeof LibraryBig }> = [
  { label: '书架', route: 'bookshelf', icon: LibraryBig },
  { label: '书籍工作室', route: 'studio', icon: Sparkles },
  { label: '设置', route: 'settings', icon: Settings2 },
];
const bookStore = createBookStore();
const providerStore = new ProviderProfileStore();

function locationFromHash(): AppLocation {
  const [rawRoute, bookId] = window.location.hash.slice(1).split('/');
  const route = rawRoute === 'reader' || rawRoute === 'studio' || rawRoute === 'settings' ? rawRoute : 'bookshelf';
  return { route, bookId: route === 'reader' ? bookId : undefined };
}

function MissingBookPage() {
  return <section className="placeholder-page" aria-labelledby="missing-book-title"><p className="eyebrow">阅读器</p><h2 id="missing-book-title">找不到书籍</h2><p>这本书可能已经从当前设备删除，或者阅读链接已经失效。</p><button type="button" className="secondary-button" onClick={() => { window.location.hash = 'bookshelf'; }} aria-label="返回书架"><ArrowLeft size={17} /> 返回书架</button></section>;
}

export default function App() {
  const [location, setLocation] = useState<AppLocation>(locationFromHash);
  const [books, setBooks] = useState<Book[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const activeBook = useMemo(() => books.find((book) => book.id === location.bookId), [books, location.bookId]);

  useEffect(() => {
    const onHashChange = () => setLocation(locationFromHash());
    window.addEventListener('hashchange', onHashChange);
    void bookStore.listBooks().then(setBooks).catch(() => setError('读取书架失败')).finally(() => setLoading(false));
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  const importBook = async (file: File) => {
    setError(undefined);
    try {
      const imported = await parseBook(file);
      await bookStore.saveBook(imported);
      setBooks((current) => [imported, ...current.filter((book) => book.id !== imported.id)]);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '导入书籍失败');
    }
  };

  const openBook = (bookId: string) => { window.location.hash = `reader/${bookId}`; };
  const deleteBook = async (bookId: string) => {
    await bookStore.deleteBook(bookId);
    setBooks((current) => current.filter((book) => book.id !== bookId));
    if (location.bookId === bookId) window.location.hash = 'bookshelf';
  };
  const updateProgress = async (bookId: string, progress: Pick<Book, 'readingChapter' | 'readingProgress' | 'lastReadAt'>) => {
    await bookStore.updateBook(bookId, progress);
    setBooks((current) => current.map((book) => book.id === bookId ? { ...book, ...progress } : book));
  };
  const updateTranslationPreferences = async (bookId: string, translationPreferences: Book['translationPreferences']) => {
    await bookStore.updateBook(bookId, { translationPreferences });
    setBooks((current) => current.map((book) => book.id === bookId ? { ...book, translationPreferences } : book));
  };
  const updateSelectionPreferences = async (bookId: string, selectionPreferences: Book['selectionPreferences']) => {
    await bookStore.updateBook(bookId, { selectionPreferences });
    setBooks((current) => current.map((book) => book.id === bookId ? { ...book, selectionPreferences } : book));
  };
  const saveGeneratedBook = async (book: Book) => {
    await bookStore.saveBook(book);
    setBooks((current) => [book, ...current.filter((candidate) => candidate.id !== book.id)]);
  };

  let content;
  if (location.route === 'reader') {
    content = loading ? <div className="state-card" role="status">正在读取书籍</div> : activeBook
      ? <ReaderPage key={activeBook.id} book={activeBook} onProgress={(progress) => updateProgress(activeBook.id, progress)} onTranslationPreferencesChange={(preferences) => updateTranslationPreferences(activeBook.id, preferences)} onSelectionPreferencesChange={(preferences) => updateSelectionPreferences(activeBook.id, preferences)} onBack={() => { window.location.hash = 'bookshelf'; }} />
      : <MissingBookPage />;
  } else if (location.route === 'studio') {
    content = <BookStudioPage books={books} providerStore={providerStore} onSaveBook={saveGeneratedBook} />;
  } else if (location.route === 'settings') {
    content = <SettingsPage store={providerStore} />;
  } else {
    content = <BookshelfPage books={books} loading={loading} error={error} onImport={importBook} onOpen={openBook} onDelete={deleteBook} />;
  }

  return <div className="app-shell" data-route={location.route}>
    <aside className="app-rail">
      <header className="brand"><h1><a href="#bookshelf" aria-label="AirRead 灵阅">AirRead <span>灵阅</span></a></h1><p>沉浸式双语阅读</p></header>
      <nav className="primary-navigation" aria-label="主导航">{primaryNavigation.map(({ label, route: navRoute, icon: Icon }) => <a key={navRoute} href={`#${navRoute}`} aria-current={location.route === navRoute || (location.route === 'reader' && navRoute === 'bookshelf') ? 'page' : undefined}><Icon size={18} /> <span>{label}</span></a>)}</nav>
      <div className="rail-footer"><BookOpen size={16} /> 本地存储 · 可离线阅读</div>
    </aside>
    <main>{content}</main>
  </div>;
}
