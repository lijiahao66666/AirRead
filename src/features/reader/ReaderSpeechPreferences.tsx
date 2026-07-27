import { Headphones, Languages, Play, Volume2 } from 'lucide-react';

import { SPEECH_RATE_OPTIONS, speechVoiceQualityScore, voicesForLocale } from './readerPreferences';

type VoiceKind = 'source' | 'target';

type ReaderSpeechPreferencesProps = {
  supported: boolean;
  voices: SpeechSynthesisVoice[];
  sourceLocale: string;
  targetLocale: string;
  sourceVoiceURI: string;
  targetVoiceURI: string;
  rate: number;
  onVoiceChange: (kind: VoiceKind, voiceURI: string) => void;
  onRateChange: (rate: number) => void;
  onPreview: (kind: VoiceKind) => void;
};

const languageNameForLocale = (locale: string): string => ({
  en: '英语',
  zh: '中文',
  ja: '日语',
  ko: '韩语',
  fr: '法语',
  de: '德语',
  es: '西班牙语',
  ru: '俄语',
})[locale.toLowerCase().split('-')[0]] ?? locale;

function VoiceRow({ kind, label, locale, value, voices, supported, onChange, onPreview }: {
  kind: VoiceKind;
  label: string;
  locale: string;
  value: string;
  voices: SpeechSynthesisVoice[];
  supported: boolean;
  onChange: (kind: VoiceKind, voiceURI: string) => void;
  onPreview: (kind: VoiceKind) => void;
}) {
  const matchingVoices = voicesForLocale(voices, locale);
  const Icon = kind === 'source' ? Volume2 : Languages;
  return <div className="reader-voice-row">
    <span className="reader-voice-row__icon"><Icon size={16} /></span>
    <label><span><strong>{label}</strong><small>{languageNameForLocale(locale)}</small></span><select aria-label={`${label}音色`} value={value} onChange={(event) => onChange(kind, event.target.value)} disabled={!supported}><option value="">自动匹配（推荐）</option>{matchingVoices.map((voice) => <option value={voice.voiceURI} key={voice.voiceURI}>{voice.name}{speechVoiceQualityScore(voice) >= 2 ? ' · 推荐' : voice.localService ? ' · 本机' : ' · 在线'}</option>)}</select></label>
    <button type="button" className="reader-voice-preview" onClick={() => onPreview(kind)} disabled={!supported || matchingVoices.length === 0} aria-label={`试听${label}音色`}><Play size={15} /></button>
  </div>;
}

export function ReaderSpeechPreferences({ supported, voices, sourceLocale, targetLocale, sourceVoiceURI, targetVoiceURI, rate, onVoiceChange, onRateChange, onPreview }: ReaderSpeechPreferencesProps) {
  return <section className="reader-control-section reader-speech-preferences" aria-labelledby="reader-speech-preferences-title">
    <header className="reader-speech-preferences__header"><span><Headphones size={17} /></span><div><p>声音与语速</p><h3 id="reader-speech-preferences-title">朗读声音</h3></div></header>
    {supported && <p className="reader-speech-voice-guidance">声音由当前设备提供，已隐藏效果音并优先常用人声；需要更自然的声音，可在系统“朗读”设置中下载增强音色。</p>}
    <div className="reader-voice-list">
      <VoiceRow kind="source" label="原文" locale={sourceLocale} value={sourceVoiceURI} voices={voices} supported={supported} onChange={onVoiceChange} onPreview={onPreview} />
      <VoiceRow kind="target" label="译文" locale={targetLocale} value={targetVoiceURI} voices={voices} supported={supported} onChange={onVoiceChange} onPreview={onPreview} />
    </div>
    {supported && voices.length === 0 && <p className="reader-speech-voices-note">当前浏览器未返回可选系统音色，将使用系统默认朗读。</p>}
    <div className="reader-rate-setting"><span>语速</span><div role="group" aria-label="朗读速度">{SPEECH_RATE_OPTIONS.map((option) => <button type="button" className={option === rate ? 'is-active' : ''} aria-pressed={option === rate} onClick={() => onRateChange(option)} key={option}>{option.toFixed(1)}×</button>)}</div></div>
    {!supported && <p className="reader-speech-support-note">当前浏览器不支持设备朗读。</p>}
  </section>;
}
