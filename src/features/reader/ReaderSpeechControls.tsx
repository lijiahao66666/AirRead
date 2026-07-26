import { Pause, Play, Square, Volume2 } from 'lucide-react';

export type SpeechPlaybackState = 'idle' | 'playing' | 'paused';

type ReaderSpeechControlsProps = {
  supported: boolean;
  state: SpeechPlaybackState;
  currentIndex: number;
  totalCount: number;
  rate: number;
  error?: string;
  onStart: () => void;
  onPause: () => void;
  onResume: () => void;
  onStop: () => void;
  onRateChange: () => void;
};

export function ReaderSpeechControls({ supported, state, currentIndex, totalCount, rate, error, onStart, onPause, onResume, onStop, onRateChange }: ReaderSpeechControlsProps) {
  if (state === 'idle') return <div className="reader-listen-entry">
    <button type="button" className="reader-listen-button" onClick={onStart} disabled={!supported || totalCount === 0} aria-label={supported ? '朗读本章' : '当前浏览器不支持朗读'}><Volume2 size={16} /><span className="reader-speech-label">朗读</span></button>
    {error && <span className="reader-speech-error" role="alert">{error}</span>}
  </div>;

  const progress = totalCount > 0 ? ((currentIndex + 1) / totalCount) * 100 : 0;
  return <>
    <div className="reader-listen-entry">
      <button type="button" className="reader-listen-button is-active" onClick={state === 'playing' ? onPause : onResume} aria-label={state === 'playing' ? '正在朗读' : '朗读已暂停'}><Volume2 size={16} /><span className="reader-speech-label">朗读</span></button>
    </div>
    <aside className="reader-speech-player" aria-label="章节朗读" aria-live="polite">
      <span className="reader-speech-player__icon"><Volume2 size={20} /></span>
      <div className="reader-speech-player__body">
        <strong>{state === 'paused' ? '朗读已暂停' : '正在朗读'} {currentIndex + 1}/{totalCount}</strong>
        <div className="reader-speech-player__track" aria-hidden="true"><span style={{ width: `${progress}%` }} /></div>
      </div>
      <div className="reader-speech-player__actions">
        {state === 'playing'
          ? <button type="button" className="reader-speech-player__primary" onClick={onPause} aria-label="暂停朗读"><Pause size={17} /></button>
          : <button type="button" className="reader-speech-player__primary" onClick={onResume} aria-label="继续朗读"><Play size={17} /></button>}
        <button type="button" className="reader-speech-player__rate" onClick={onRateChange} aria-label={`调整朗读速度，当前 ${rate.toFixed(1)} 倍`}>{rate.toFixed(1)}×</button>
        <button type="button" className="reader-speech-player__stop" onClick={onStop} aria-label="停止朗读"><Square size={15} /></button>
      </div>
    </aside>
  </>;
}
