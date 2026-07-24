import { RotateCcw, X } from 'lucide-react';

import { languageLabel, READER_LANGUAGE_OPTIONS, type ReaderLanguage } from './readerPreferences';

type ReaderTranslationControlsProps = {
  translatedCount: number;
  totalCount: number;
  running: boolean;
  failed: number;
  showTranslations: boolean;
  targetLanguage: Exclude<ReaderLanguage, 'auto'>;
  globalTargetLanguage: Exclude<ReaderLanguage, 'auto'>;
  targetOverride?: Exclude<ReaderLanguage, 'auto'>;
  onShowOriginal: () => void;
  onShowBilingual: () => void;
  onStop: () => void;
  onTargetLanguageChange: (language: '' | Exclude<ReaderLanguage, 'auto'>) => void;
};

export function ReaderTranslationControls({ translatedCount, totalCount, running, failed, showTranslations, targetLanguage, globalTargetLanguage, targetOverride, onShowOriginal, onShowBilingual, onStop, onTargetLanguageChange }: ReaderTranslationControlsProps) {
  const hasTranslations = translatedCount > 0;
  const bilingualActive = showTranslations && (hasTranslations || running);
  const bilingualLabel = running
    ? '正在生成本章双语'
    : failed
      ? '重试本章双语'
      : hasTranslations
        ? '显示本章双语'
        : '生成本章双语';

  return <div className="reader-language-control">
    <label className="reader-target-control"><span>译为</span><select aria-label="本书翻译目标语言" value={targetOverride ?? ''} onChange={(event) => onTargetLanguageChange(event.target.value as '' | Exclude<ReaderLanguage, 'auto'>)} disabled={running}><option value="">跟随全局（{languageLabel(globalTargetLanguage)}）</option>{READER_LANGUAGE_OPTIONS.filter((option) => option.value !== 'auto').map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></label>
    <div className="reader-language-switch" role="group" aria-label={`阅读语言，当前译为${languageLabel(targetLanguage)}`}>
      <button type="button" className={!bilingualActive ? 'is-active' : ''} aria-pressed={!bilingualActive} aria-label="切换到原文" onClick={onShowOriginal}>原文</button>
      <button type="button" className={bilingualActive ? 'is-active' : ''} aria-pressed={bilingualActive} aria-label={bilingualLabel} onClick={onShowBilingual} disabled={totalCount === 0}>双语</button>
    </div>
    {running && <div className="reader-translation-progress" role="status"><span>生成中 {translatedCount}/{totalCount}</span><button type="button" onClick={onStop} aria-label="停止生成本章双语"><X size={14} /></button></div>}
    {!running && failed > 0 && <button type="button" className="reader-translation-retry" onClick={onShowBilingual} aria-label="重试未完成段落"><RotateCcw size={13} /> {failed} 段未完成</button>}
  </div>;
}
