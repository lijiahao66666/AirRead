import { useState } from 'react';
import { Check, Copy, Languages, Play, RotateCcw } from 'lucide-react';

import { languageLabel, READER_LANGUAGE_OPTIONS, type ReaderLanguage } from './readerPreferences';

type SelectionActionsProps = {
  source: string;
  targetLanguage: Exclude<ReaderLanguage, 'auto'>;
  globalTargetLanguage: Exclude<ReaderLanguage, 'auto'>;
  targetOverride?: Exclude<ReaderLanguage, 'auto'>;
  translation?: string;
  loading: boolean;
  error?: string;
  notice?: string;
  copied?: boolean;
  canRead: boolean;
  onRetry: () => void;
  onRead: () => void;
  onTargetLanguageChange: (language: '' | Exclude<ReaderLanguage, 'auto'>) => void;
  onCopy: () => void;
};

export function SelectionActions({ source, targetLanguage, globalTargetLanguage, targetOverride, translation, loading, error, notice, copied, canRead, onRetry, onRead, onTargetLanguageChange, onCopy }: SelectionActionsProps) {
  const [languagePickerOpen, setLanguagePickerOpen] = useState(false);
  const selectedLanguageLabel = languageLabel(targetLanguage);
  const chooseLanguage = (language: '' | Exclude<ReaderLanguage, 'auto'>) => {
    onTargetLanguageChange(language);
    setLanguagePickerOpen(false);
  };

  return <>
    <aside className="selection-actions" aria-label="选中文本操作">
      <header className="selection-actions__heading">
        <span><Languages size={16} /> 划词翻译</span>
        <button type="button" className="selection-actions__language-trigger" aria-label={`选择划词翻译目标语言，当前${selectedLanguageLabel}`} aria-haspopup="dialog" aria-expanded={languagePickerOpen} onClick={() => setLanguagePickerOpen(true)}>译为 {selectedLanguageLabel}</button>
      </header>
      <p className="selection-actions__source">{source}</p>
      <div className="selection-actions__result" aria-live="polite">
        {loading && <p role="status">正在翻译…</p>}
        {notice && <p className="selection-actions__notice" role="status">{notice}</p>}
        {translation && <p lang={targetLanguage}>{translation}</p>}
        {error && <div className="selection-actions__error" role="alert"><span>{error}</span><button type="button" onClick={onRetry} aria-label="重试划词翻译"><RotateCcw size={14} /> 重试</button></div>}
      </div>
      <div className="selection-actions__secondary" role="toolbar" aria-label="译文操作"><button type="button" onClick={onRead} disabled={!canRead}><Play size={15} /> 朗读</button><button type="button" onClick={onCopy}><Copy size={15} /> {copied ? '已复制' : '复制'}</button></div>
    </aside>
    {languagePickerOpen && <div className="selection-language-picker-backdrop" role="presentation" onClick={() => setLanguagePickerOpen(false)}>
      <section className="selection-language-picker" role="dialog" aria-modal="true" aria-label="划词翻译目标语言" onClick={(event) => event.stopPropagation()}>
        <header><span>翻译为</span><p>仅影响这本书的划词翻译</p></header>
        <div role="listbox" aria-label="目标语言">
          <button type="button" role="option" aria-selected={!targetOverride} className={!targetOverride ? 'is-selected' : ''} onClick={() => chooseLanguage('')}><span>跟随阅读翻译</span><strong>{languageLabel(globalTargetLanguage)}</strong></button>
          {READER_LANGUAGE_OPTIONS.filter((option) => option.value !== 'auto').map((option) => {
            const language = option.value as Exclude<ReaderLanguage, 'auto'>;
            return <button type="button" role="option" aria-selected={targetOverride === language} className={targetOverride === language ? 'is-selected' : ''} onClick={() => chooseLanguage(language)} key={language}><span>{option.label}</span>{targetOverride === language && <Check size={16} aria-hidden="true" />}</button>;
          })}
        </div>
      </section>
    </div>}
  </>;
}
