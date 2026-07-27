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
        : `将朗读本章${contentLabel === '原文' ? '原文' : contentLabel}`;

  return <section className="reader-control-section reader-speech-controls" aria-labelledby="reader-speech-controls-title">
    <header className="reader-control-section__header"><span><Volume2 size={17} /></span><div><h3 id="reader-speech-controls-title">章节朗读</h3><p>按当前原文、双语或译文显示方式连续朗读。</p></div></header>
    <div className="reader-speech-controls__playback" aria-live="polite">
      <span>{status}</span>
      {!active
        ? <button type="button" className="reader-speech-controls__primary" onClick={onStart} disabled={!supported || totalCount === 0} aria-label={supported ? startLabel : '当前浏览器不支持朗读'}><Play size={17} />开始朗读</button>
        : <div className="reader-speech-controls__actions">
          {state === 'playing'
            ? <button type="button" className="reader-speech-controls__primary" onClick={onPause} aria-label="暂停朗读"><Pause size={17} />暂停</button>
            : <button type="button" className="reader-speech-controls__primary" onClick={onResume} aria-label="继续朗读"><Play size={17} />继续</button>}
          <button type="button" className="reader-speech-controls__secondary" onClick={onStop} aria-label="停止朗读"><Square size={15} />停止</button>
        </div>}
    </div>
    {error && <p className="reader-speech-controls__error" role="alert">{error}</p>}
  </section>;
}
