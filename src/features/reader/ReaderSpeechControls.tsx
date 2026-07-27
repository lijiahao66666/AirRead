import { Pause, Play, Square, Volume2 } from 'lucide-react';

export type SpeechPlaybackState = 'idle' | 'playing' | 'paused';

type ReaderSpeechControlsProps = {
  supported: boolean;
  state: SpeechPlaybackState;
  contentLabel: '原文' | '双语' | '译文';
  currentIndex: number;
  totalCount: number;
  error?: string;
  onStart: () => void;
  onPause: () => void;
  onResume: () => void;
  onStop: () => void;
};

export function ReaderSpeechControls({ supported, state, contentLabel, currentIndex, totalCount, error, onStart, onPause, onResume, onStop }: ReaderSpeechControlsProps) {
  const startLabel = contentLabel === '原文' ? '朗读本章' : `朗读本章${contentLabel}`;
  const active = state !== 'idle';
  const status = !supported
    ? '当前浏览器不支持设备朗读'
    : totalCount === 0
      ? '当前显示模式没有可朗读的内容'
      : active
        ? `${state === 'paused' ? '朗读已暂停' : '正在朗读'} · ${contentLabel} ${currentIndex + 1}/${totalCount}`
        : `${contentLabel} · 共 ${totalCount} 段`;

  return <section className="reader-control-section reader-speech-controls" aria-labelledby="reader-speech-controls-title">
    <div className="reader-speech-controls__playback" aria-live="polite">
      <div className="reader-speech-controls__identity"><span className="reader-speech-controls__icon"><Volume2 size={19} /></span><div><p>本章朗读</p><h3 id="reader-speech-controls-title">{active ? (state === 'paused' ? '暂停中' : '正在播放') : '准备开始'}</h3><span>{status}</span></div></div>
      <div className="reader-speech-controls__actions">
        {!active
          ? <button type="button" className="reader-speech-controls__primary" onClick={onStart} disabled={!supported || totalCount === 0} aria-label={supported ? startLabel : '当前浏览器不支持朗读'}><Play size={17} /><span>开始</span></button>
          : <>
            {state === 'playing'
              ? <button type="button" className="reader-speech-controls__primary" onClick={onPause} aria-label="暂停朗读"><Pause size={17} /><span>暂停</span></button>
              : <button type="button" className="reader-speech-controls__primary" onClick={onResume} aria-label="继续朗读"><Play size={17} /><span>继续</span></button>}
            <button type="button" className="reader-speech-controls__secondary" onClick={onStop} aria-label="停止朗读"><Square size={15} /></button>
          </>}
      </div>
    </div>
    {error && <p className="reader-speech-controls__error" role="alert">{error}</p>}
  </section>;
}
