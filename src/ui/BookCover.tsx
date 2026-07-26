import { useEffect, useState } from 'react';
import { BookOpen, FileText } from 'lucide-react';

type BookCoverProps = {
  src?: string;
  alt?: string;
  variant?: 'book' | 'file';
};

export function BookCover({ src, alt = '', variant = 'book' }: BookCoverProps) {
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setFailed(false);
  }, [src]);

  if (src && !failed) {
    return <img src={src} alt={alt} loading="lazy" decoding="async" onError={() => setFailed(true)} />;
  }

  const Icon = variant === 'file' ? FileText : BookOpen;
  return <span className="book-cover-placeholder" aria-hidden="true"><Icon size={variant === 'file' ? 24 : 30} strokeWidth={1.5} /></span>;
}
