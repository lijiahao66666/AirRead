import { RotateCcw, X } from 'lucide-react';

import { languageLabel, READER_LANGUAGE_OPTIONS, type ReaderLanguage } from './readerPreferences';
import type { ReaderContentMode } from './readerPagination';

type ReaderTranslationControlsProps = {
  translatedCount: number;
  totalCount: number;
  running: boolean;
  failed: number;
  contentMode: ReaderContentMode;
  targetLanguage: Exclude<ReaderLanguage, 'auto'>;
  globalTargetLanguage: Exclude<ReaderLanguage, 'auto'>;
  targetOverride?: Exclude<ReaderLanguage, 'auto'>;
  onModeChange: (mode: ReaderContentMode) => void;
  onStop: () => void;
  onTargetLanguageChange: (language: '' | Exclude<ReaderLanguage, 'auto'>) => void;
};

export function ReaderTranslationControls({ translatedCount, totalCount, running, failed, contentMode, targetLanguage, globalTargetLanguage, targetOverride, onModeChange, onStop, onTargetLanguageChange }: ReaderTranslationControlsProps) {
  const hasTranslations = translatedCount > 0;
  const bilingualLabel = running
    ? '正在生成本章双语'
    : failed
      ? '重试本章双语'
      : hasTranslations
        ? '显示本章双语'
        : '生成本章双语';

  const translationLabel = running
    ? '正在生成本章纯译文'
    : failed
      ? '重试本章纯译文'
      : hasTranslations
        ? '显示本章纯译文'
        : '生成本章纯译文';

  return <div className="reader-language-control">
    <label className="reader-target-control"><span>目标语言</span><select aria-label="本书翻译目标语言" value={targetOverride ?? ''} onChange={(event) => onTargetLanguageChange(event.target.value as '' | Exclude<ReaderLanguage, 'auto'>)} disabled={running}><option value="">跟随阅读设置 · {languageLabel(globalTargetLanguage)}</option>{READER_LANGUAGE_OPTIONS.filter((option) => option.value !== 'auto').map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></label>
    <div className="reader-language-switch" role="group" aria-label={`阅读显示模式，目标语言为${languageLabel(targetLanguage)}`}>
      <button type="button" className={contentMode === 'original' ? 'is-active' : ''} aria-pressed={contentMode === 'original'} aria-label="切换到原文" onClick={() => onModeChange('original')}>原文</button>
      <button type="button" className={contentMode === 'bilingual' ? 'is-active' : ''} aria-pressed={contentMode === 'bilingual'} aria-label={bilingualLabel} onClick={() => onModeChange('bilingual')} disabled={totalCount === 0}>双语</button>
      <button type="button" className={contentMode === 'translation' ? 'is-active' : ''} aria-pressed={contentMode === 'translation'} aria-label={translationLabel} onClick={() => onModeChange('translation')} disabled={totalCount === 0}>译文</button>
    </div>
    {running && <div className="reader-translation-progress" role="status"><span>生成中 {translatedCount}/{totalCount}</span><button type="button" onClick={onStop} aria-label="停止本章翻译"><X size={14} /></button></div>}
    {!running && failed > 0 && <button type="button" className="reader-translation-retry" onClick={() => onModeChange(contentMode === 'original' ? 'bilingual' : contentMode)} aria-label="重试未完成段落"><RotateCcw size={13} /> {failed} 段未完成</button>}
  </div>;
}
