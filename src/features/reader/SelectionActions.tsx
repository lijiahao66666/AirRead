import type { CSSProperties } from 'react';
import { Check, ChevronDown, Copy, Languages, Play, RotateCcw, X } from 'lucide-react';

import { languageLabel, READER_LANGUAGE_OPTIONS, type ReaderLanguage } from './readerPreferences';

type SelectionActionsProps = {
  source: string;
  targetLanguage: Exclude<ReaderLanguage, 'auto'>;
  globalTargetLanguage: Exclude<ReaderLanguage, 'auto'>;
  targetOverride?: Exclude<ReaderLanguage, 'auto'>;
  anchor: { x: number; y: number };
  placement: 'above' | 'below';
  translation?: string;
  loading: boolean;
  error?: string;
  notice?: string;
  copied?: boolean;
  canRead: boolean;
  onTranslate: () => void;
  onRead: () => void;
  onTargetLanguageChange: (language: '' | Exclude<ReaderLanguage, 'auto'>) => void;
  onCopy: () => void;
  onDismiss: () => void;
};

export function SelectionActions({ source, targetLanguage, globalTargetLanguage, targetOverride, anchor, placement, translation, loading, error, notice, copied, canRead, onTranslate, onRead, onTargetLanguageChange, onCopy, onDismiss }: SelectionActionsProps) {
  const expanded = loading || Boolean(translation) || Boolean(error) || Boolean(notice);
  const style = { '--selection-x': `${anchor.x}px`, '--selection-y': `${anchor.y}px` } as CSSProperties;

  return <aside className={`selection-actions selection-actions--${placement} ${expanded ? 'selection-actions--expanded' : ''}`} style={style} aria-label="选中文本操作">
    {expanded ? <>
      <div className="selection-actions__heading"><span><Languages size={15} /> 划词翻译</span><button type="button" className="selection-actions__icon-action" onClick={onDismiss} aria-label="关闭划词翻译"><X size={15} /></button></div>
      <TargetLanguageSelect targetLanguage={targetLanguage} globalTargetLanguage={globalTargetLanguage} targetOverride={targetOverride} onChange={onTargetLanguageChange} disabled={loading} />
      <p className="selection-actions__source">{source}</p>
      <div className="selection-actions__result" aria-live="polite">
        {loading && <p role="status">正在翻译…</p>}
        {notice && <p className="selection-actions__notice" role="status">{notice}</p>}
        {translation && <p lang={targetLanguage}>{translation}</p>}
        {error && <div className="selection-actions__error" role="alert"><span>{error}</span><button type="button" onClick={onTranslate} aria-label="重试划词翻译"><RotateCcw size={14} /> 重试</button></div>}
      </div>
      <div className="selection-actions__secondary" role="toolbar" aria-label="译文操作"><button type="button" onClick={onRead} disabled={!canRead}><Play size={14} /> 朗读</button><button type="button" onClick={onCopy}><Copy size={14} /> {copied ? '已复制' : '复制'}</button></div>
    </> : <div className="selection-actions__toolbar" role="toolbar" aria-label="划词操作">
      <button type="button" className="selection-actions__primary" onClick={onTranslate} aria-label="翻译选中文本"><Languages size={15} /><span>翻译</span></button>
      <TargetLanguageSelect targetLanguage={targetLanguage} globalTargetLanguage={globalTargetLanguage} targetOverride={targetOverride} onChange={onTargetLanguageChange} compact />
      <button type="button" className="selection-actions__icon-action" onClick={onRead} disabled={!canRead} aria-label="朗读选中文本"><Play size={16} /></button>
      <button type="button" className="selection-actions__icon-action" onClick={onCopy} aria-label="复制选中文本">{copied ? <Check size={16} /> : <Copy size={16} />}</button>
      <button type="button" className="selection-actions__icon-action selection-actions__close" onClick={onDismiss} aria-label="关闭选中文本操作"><X size={16} /></button>
    </div>}
  </aside>;
}

type TargetLanguageSelectProps = {
  targetLanguage: Exclude<ReaderLanguage, 'auto'>;
  globalTargetLanguage: Exclude<ReaderLanguage, 'auto'>;
  targetOverride?: Exclude<ReaderLanguage, 'auto'>;
  onChange: (language: '' | Exclude<ReaderLanguage, 'auto'>) => void;
  compact?: boolean;
  disabled?: boolean;
};

function TargetLanguageSelect({ targetLanguage, globalTargetLanguage, targetOverride, onChange, compact = false, disabled = false }: TargetLanguageSelectProps) {
  return <label className={`selection-actions__target ${compact ? 'selection-actions__target--compact' : ''}`}><span>译为</span><select aria-label="划词翻译目标语言" value={targetOverride ?? ''} onChange={(event) => onChange(event.target.value as '' | Exclude<ReaderLanguage, 'auto'>)} disabled={disabled}><option value="">{languageLabel(globalTargetLanguage)}</option>{READER_LANGUAGE_OPTIONS.filter((option) => option.value !== 'auto').map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select><ChevronDown size={14} aria-hidden="true" /></label>;
}
