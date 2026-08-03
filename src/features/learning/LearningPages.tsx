import { useEffect, useRef, useState } from 'react';
import { AudioLines, BookOpenText, Check, ChevronRight, CircleCheck, Clock3, Headphones, Languages, PenLine, RefreshCw, RotateCcw, Volume2 } from 'lucide-react';

import { PwaInstallPrompt } from '../../pwa/PwaInstallPrompt';
import { todayKey } from '../../domain/learning/learningStore';
import { normalizeExerciseAnswer } from '../../domain/learning/taskExercises';
import type { LearningPack, LearningPlan, LearningReviewCard, LearningTask, LearningTaskExercise } from '../../domain/learning/learningTypes';
import { DailyMinutesInput } from './DailyMinutesInput';

export type TodayPageProps = {
  pack?: LearningPack;
  dueReviewCards: LearningReviewCard[];
  completedTaskIds: string[];
  taskResponses: Record<string, string>;
  completedPackIds: string[];
  generating?: boolean;
  generationError?: string;
  onGenerate: () => void;
  onReview: (cardId: string, remembered: boolean) => void;
  onSaveTaskResponse: (taskId: string, response: string) => void;
  onCompleteTask: (taskId: string) => void;
  onCompletePack: () => void;
};

const taskIcons = {
  review: RotateCcw,
  listen: Headphones,
  read: BookOpenText,
  speak: AudioLines,
  recall: Languages,
  write: PenLine,
};

const formatDate = (date: string): string => new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', weekday: 'long' }).format(new Date(`${date}T12:00:00`));

function SystemSpeechButton({ text, label = '使用系统朗读英文原文' }: { text: string; label?: string }) {
  const [speaking, setSpeaking] = useState(false);
  const supported = typeof window !== 'undefined' && 'speechSynthesis' in window;

  useEffect(() => () => { if ('speechSynthesis' in window) window.speechSynthesis.cancel(); }, []);

  const toggle = () => {
    if (!supported) return;
    if (speaking) {
      window.speechSynthesis.cancel();
      setSpeaking(false);
      return;
    }
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = 'en-US';
    utterance.rate = 0.88;
    utterance.onend = () => setSpeaking(false);
    utterance.onerror = () => setSpeaking(false);
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utterance);
    setSpeaking(true);
  };

  return <button type="button" className={`learning-icon-button${speaking ? ' learning-icon-button--active' : ''}`} onClick={toggle} disabled={!supported} aria-label={speaking ? '停止系统朗读' : label} title={supported ? '系统朗读（非原版音频）' : '当前浏览器不支持系统朗读'}><Volume2 size={17} /> <span>{speaking ? '停止' : '朗读'}</span></button>;
}

const wordCount = (value: string): number => value.trim().split(/\s+/u).filter(Boolean).length;

function TaskExercisePanel({ task, exercise, response, onSaveResponse, onComplete }: { task: LearningTask; exercise: LearningTaskExercise; response?: string; onSaveResponse: (response: string) => void; onComplete: () => void }) {
  const [feedback, setFeedback] = useState<string>();
  const [draft, setDraft] = useState(response ?? '');
  const [orderedTokens, setOrderedTokens] = useState<string[]>(response ? response.split('|').filter(Boolean) : []);
  const [recording, setRecording] = useState(false);
  const [recordUrl, setRecordUrl] = useState<string>();
  const recorderRef = useRef<MediaRecorder | undefined>(undefined);
  const chunksRef = useRef<Blob[]>([]);
  const orderChoices = (exercise.choices ?? []).map((word, index) => ({ id: `${index}:${word}`, word }));
  const orderedWords = orderedTokens.map((token) => orderChoices.find((choice) => choice.id === token)?.word).filter((word): word is string => Boolean(word));

  useEffect(() => () => {
    if (recordUrl) URL.revokeObjectURL(recordUrl);
    recorderRef.current?.stream.getTracks().forEach((track) => track.stop());
  }, [recordUrl]);

  const submitChoice = (choice: string) => {
    onSaveResponse(choice);
    if (choice === exercise.answer) {
      setFeedback('答对了，这句话就是你刚才听到的内容。');
      onComplete();
    } else {
      setFeedback('还不对，再播放一次，注意句子的开头和结尾。');
    }
  };

  const submitCloze = () => {
    onSaveResponse(draft);
    if (normalizeExerciseAnswer(draft) === normalizeExerciseAnswer(exercise.answer ?? '')) {
      setFeedback('填对了。');
      onComplete();
    } else {
      setFeedback('再读一遍原文，注意句子里的拼写。');
    }
  };

  const submitOrder = () => {
    const answer = normalizeExerciseAnswer(exercise.answer ?? '');
    const candidate = normalizeExerciseAnswer(orderedWords.join(' '));
    onSaveResponse(orderedTokens.join('|'));
    if (candidate === answer) {
      setFeedback('顺序正确。');
      onComplete();
    } else {
      setFeedback('顺序还需要调整，再试一次。');
    }
  };

  const startRecording = async () => {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') return;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      chunksRef.current = [];
      recorder.ondataavailable = (event) => { if (event.data.size > 0) chunksRef.current.push(event.data); };
      recorder.onstop = () => {
        stream.getTracks().forEach((track) => track.stop());
        const nextUrl = URL.createObjectURL(new Blob(chunksRef.current, { type: recorder.mimeType || 'audio/webm' }));
        setRecordUrl(nextUrl);
        onSaveResponse('recorded');
        onComplete();
      };
      recorderRef.current = recorder;
      recorder.start();
      setRecording(true);
    } catch {
      setFeedback('无法访问麦克风，请允许浏览器使用麦克风后重试。');
    }
  };

  const stopRecording = () => {
    recorderRef.current?.stop();
    setRecording(false);
  };

  if (exercise.type === 'listen-choice') return <div className="learning-exercise learning-exercise--listen"><div className="learning-exercise__title"><h4>听辨训练</h4><SystemSpeechButton text={exercise.text ?? ''} label="播放听力句子" /></div><p>{exercise.prompt}</p><div className="exercise-choice-list">{exercise.choices?.map((choice) => <button type="button" className={response === choice ? 'exercise-choice exercise-choice--selected' : 'exercise-choice'} key={choice} onClick={() => submitChoice(choice)}>{choice}</button>)}</div>{feedback && <p className="exercise-feedback" role="status">{feedback}</p>}</div>;

  if (exercise.type === 'cloze') return <div className="learning-exercise"><h4>阅读填空</h4><p>{exercise.prompt}</p><label className="exercise-field"><span>缺失单词</span><input aria-label="阅读填空答案" value={draft} onChange={(event) => { setDraft(event.target.value); onSaveResponse(event.target.value); }} autoCapitalize="none" autoCorrect="off" /></label><button type="button" className="primary-action exercise-submit" onClick={submitCloze}>检查答案</button>{feedback && <p className="exercise-feedback" role="status">{feedback}</p>}</div>;

  if (exercise.type === 'word-order') {
    const remaining = orderChoices.filter((choice) => !orderedTokens.includes(choice.id));
    return <div className="learning-exercise"><h4>句子重组</h4><p>{exercise.prompt}</p><div className="exercise-order-answer" aria-label="已选词语">{orderedWords.length ? orderedWords.map((word, index) => <button type="button" key={`${orderedTokens[index]}-${index}`} onClick={() => setOrderedTokens((tokens) => tokens.filter((_, tokenIndex) => tokenIndex !== index))}>{word}</button>) : <span>点击下方词语开始组句</span>}</div><div className="exercise-word-bank">{remaining.map((choice) => <button type="button" key={choice.id} onClick={() => setOrderedTokens((tokens) => [...tokens, choice.id])}>{choice.word}</button>)}</div><button type="button" className="primary-action exercise-submit" onClick={submitOrder} disabled={!orderedTokens.length}>检查顺序</button>{feedback && <p className="exercise-feedback" role="status">{feedback}</p>}</div>;
  }

  if (exercise.type === 'shadowing') return <div className="learning-exercise"><div className="learning-exercise__title"><h4>跟读录音</h4><SystemSpeechButton text={exercise.text ?? ''} label="播放跟读句子" /></div><p>{exercise.prompt}</p><p className="exercise-quote">{exercise.text}</p>{recordUrl && <audio className="exercise-recording" controls src={recordUrl}>你的浏览器不支持播放录音。</audio>}{recording ? <button type="button" className="secondary-button exercise-submit" onClick={stopRecording}>结束录音</button> : <button type="button" className="primary-action exercise-submit" onClick={() => { void startRecording(); }} disabled={!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined'}>{recordUrl ? '重新录一遍' : '开始录音'}</button>}{!navigator.mediaDevices?.getUserMedia && <p className="exercise-feedback">当前浏览器不支持录音，请完成跟读后再继续。</p>}</div>;

  return <div className="learning-exercise"><h4>短写作</h4><p>{exercise.prompt}</p><label className="exercise-field"><span>你的英文回答</span><textarea aria-label="短写作回答" value={draft} onChange={(event) => { setDraft(event.target.value); onSaveResponse(event.target.value); }} rows={4} autoCapitalize="sentences" /></label><div className="exercise-footer"><span>{wordCount(draft)} / {exercise.minimumWords ?? 10} 个词</span><button type="button" className="primary-action exercise-submit" onClick={onComplete} disabled={wordCount(draft) < (exercise.minimumWords ?? 10)}>保存并完成</button></div></div>;
}

function TaskRow({ task, completed, response, onSaveResponse, onComplete, onContinue, pendingReviewCount }: { task: LearningTask; completed: boolean; response?: string; onSaveResponse: (response: string) => void; onComplete: () => void; onContinue?: () => void; pendingReviewCount: number }) {
  const Icon = taskIcons[task.kind];
  return <article className={`learning-task${completed ? ' learning-task--complete' : ''}`}>
    <span className="learning-task__icon"><Icon size={18} /></span>
    <div className="learning-task__body"><small>{task.minutes} 分钟 · {task.kind === 'listen' ? '听力输入' : task.kind === 'speak' ? '口语输出' : task.kind === 'review' ? '间隔复习' : task.kind === 'read' ? '阅读理解' : task.kind === 'recall' ? '主动回忆' : '短写作'}</small><h3>{task.title}</h3>{completed ? <div className="learning-task__complete"><p className="learning-task__done"><Check size={15} /> 已完成</p>{onContinue && <button type="button" className="secondary-button learning-task__continue" onClick={onContinue}>下一项 <ChevronRight size={15} /></button>}</div> : task.kind === 'review' ? <p>{pendingReviewCount ? '请先完成上方的到期复习卡片。' : '今天没有到期词块，这一步会自动完成。'}</p> : task.exercise ? <TaskExercisePanel key={task.id} task={task} exercise={task.exercise} response={response} onSaveResponse={onSaveResponse} onComplete={onComplete} /> : <p>这份资料还没有练习数据，请重新获取今天的学习资料。</p>}</div>
  </article>;
}

function VocabularyCard({ item }: { item: LearningPack['vocabulary'][number] }) {
  const [revealed, setRevealed] = useState(false);

  return <button type="button" className={`vocabulary-card${revealed ? ' vocabulary-card--revealed' : ''}`} onClick={() => setRevealed((value) => !value)} aria-expanded={revealed}><strong>{item.term}</strong>{revealed ? <><span>{item.meaning}</span><small>{item.example}</small></> : <span className="vocabulary-card__hint">先在脑中回想释义，点击查看</span>}</button>;
}

export function TodayPage({ pack, dueReviewCards, completedTaskIds, taskResponses, completedPackIds, generating = false, generationError, onGenerate, onReview, onSaveTaskResponse, onCompleteTask, onCompletePack }: TodayPageProps) {
  const [translationVisible, setTranslationVisible] = useState(false);
  const [activeTask, setActiveTask] = useState(0);
  const complete = pack ? completedPackIds.includes(pack.id) : false;
  const completedCount = pack?.tasks.filter((task) => completedTaskIds.includes(task.id) || (task.kind === 'review' && dueReviewCards.length === 0)).length ?? 0;
  const activeTaskIndex = pack ? Math.min(activeTask, Math.max(0, pack.tasks.length - 1)) : 0;
  const pendingReviewCount = dueReviewCards.length;
  const readyToComplete = Boolean(pack && completedCount === pack.tasks.length && pendingReviewCount === 0);
  const nextTaskIndex = pack ? pack.tasks.findIndex((task, index) => index > activeTaskIndex && !completedTaskIds.includes(task.id) && !(task.kind === 'review' && pendingReviewCount === 0)) : -1;

  if (!pack) return <section className="learning-page learning-page--today" aria-labelledby="today-title">
    <header className="learning-page__header"><div><p className="eyebrow">每日英语学习包</p><h2 id="today-title">今天，学一点真的能用上的英语。</h2><p className="page-lede">系统会根据你设置的可用时间，安排输入、回忆、跟读和复习。</p></div></header>
    <PwaInstallPrompt />
    <section className="learning-empty-card"><span><SparkleMark /></span><h3>今天的学习资料还没准备好</h3><p>联网时会从开放许可资料中获取英文原文；配置模型后还会生成译文、词块和个性化训练。</p><button className="primary-action" type="button" onClick={onGenerate} disabled={generating}>{generating ? '正在获取资料…' : '获取今天的资料'} <ChevronRight size={17} /></button>{generationError && <p className="learning-error" role="alert">{generationError}</p>}</section>
  </section>;

  return <section className="learning-page learning-page--today" aria-labelledby="today-title">
    <header className="learning-page__header learning-page__header--compact"><div><p className="eyebrow">{formatDate(pack.date)}</p><h2 id="today-title">{pack.title}</h2><p className="page-lede">{pack.theme} · {pack.level}</p></div><div className="today-duration"><Clock3 size={18} /><strong>{pack.estimatedMinutes}</strong><span>分钟</span></div></header>
    <PwaInstallPrompt />
    {generationError && <p className="learning-inline-notice" role="status">{generationError}</p>}
    <section className="today-progress" aria-label="今日完成进度"><div><span>今日训练</span><strong>{completedCount} / {pack.tasks.length}</strong></div><span className="today-progress__track"><i style={{ width: `${pack.tasks.length ? (completedCount / pack.tasks.length) * 100 : 0}%` }} /></span><p>{pendingReviewCount > 0 ? `先完成 ${pendingReviewCount} 项到期复习，再开始今天的新材料。` : '到期复习已完成，可以开始今天的新材料。'}</p></section>

    <section className="learning-section learning-review-section" aria-labelledby="today-review-title"><div className="learning-section__heading"><div><p className="eyebrow">间隔重复</p><h3 id="today-review-title">今日复习</h3></div><span>{pendingReviewCount > 0 ? `${pendingReviewCount} 项待完成` : '已完成'}</span></div>{pendingReviewCount > 0 ? <div className="review-list review-list--today">{dueReviewCards.map((card) => <ReviewCard key={card.id} card={card} compact onReview={(remembered) => onReview(card.id, remembered)} />)}</div> : <p className="today-review-empty"><CircleCheck size={17} /> 今天没有到期内容，新的词块会在完成学习后加入队列。</p>}</section>

    <section className="learning-reader" aria-labelledby="lesson-content-title">
      <div className="learning-reader__meta"><span>{pack.sourceLabel}</span><span className={`audio-label audio-label--${pack.audioNote}`}>{pack.audioNote === 'original' ? '原版音频' : '系统朗读辅助'}</span></div>
      <div className="learning-reader__heading"><div><p className="eyebrow">今日材料</p><h3 id="lesson-content-title">先理解，再翻译</h3></div>{pack.audio ? <audio className="source-audio" controls preload="metadata" src={pack.audio.url}>你的浏览器暂不支持播放原版音频。</audio> : <SystemSpeechButton text={pack.originalText} />}</div>
      <p className="learning-reader__text">{pack.originalText}</p>
      {pack.translation ? <div className="translation-toggle"><button type="button" onClick={() => setTranslationVisible((visible) => !visible)} aria-expanded={translationVisible}><Languages size={16} /> {translationVisible ? '收起中文解释' : '查看中文解释'}</button>{translationVisible && <p>{pack.translation}</p>}</div> : <p className="translation-empty"><Languages size={16} /> 配置模型后，AirRead 会为这篇开放资料生成中文解释、词块和针对性训练。</p>}
      <footer className="learning-source-note">
        <span>{pack.audioNote === 'original' ? `音频：${pack.audio?.label}${pack.audio?.accent ? ` · ${pack.audio.accent}` : ''}` : '这份内容暂无原版录音，可用系统朗读辅助理解与跟读。'}</span>
        {pack.license && <span>{pack.license}</span>}
        {(pack.audio?.sourceUrl ?? pack.sourceUrl) && <a href={pack.audio?.sourceUrl ?? pack.sourceUrl} target="_blank" rel="noreferrer">{pack.audio?.sourceUrl ? '查看音频来源' : '查看来源'}</a>}
      </footer>
    </section>

    <section className="learning-section" aria-labelledby="vocabulary-title"><div className="learning-section__heading"><div><p className="eyebrow">词块，不是孤立单词</p><h3 id="vocabulary-title">今天需要记住</h3></div><span>{pack.vocabulary.length ? `${pack.vocabulary.length} 个` : '等待生成'}</span></div>{pack.vocabulary.length ? <div className="vocabulary-list">{pack.vocabulary.map((item) => <VocabularyCard key={item.term} item={item} />)}</div> : <p className="vocabulary-empty">当前是开放资料原文。配置模型后会从这篇材料中提取词块、释义和例句。</p>}</section>

    <section className="learning-section" aria-labelledby="tasks-title"><div className="learning-section__heading"><div><p className="eyebrow">按顺序完成</p><h3 id="tasks-title">今天的训练</h3></div><span>剩余 {Math.max(0, pack.tasks.length - completedCount)} 项</span></div><div className="learning-task-list">{pack.tasks.map((task, index) => <button className={`learning-task-launch${activeTaskIndex === index ? ' learning-task-launch--active' : ''}`} type="button" key={task.id} onClick={() => setActiveTask(index)} aria-pressed={activeTaskIndex === index}><span>{index + 1}</span><span>{task.title}</span></button>)}</div><TaskRow task={pack.tasks[activeTaskIndex]} completed={completedTaskIds.includes(pack.tasks[activeTaskIndex].id) || (pack.tasks[activeTaskIndex].kind === 'review' && pendingReviewCount === 0)} response={taskResponses[pack.tasks[activeTaskIndex].id]} pendingReviewCount={pendingReviewCount} onSaveResponse={(response) => onSaveTaskResponse(pack.tasks[activeTaskIndex].id, response)} onComplete={() => onCompleteTask(pack.tasks[activeTaskIndex].id)} onContinue={nextTaskIndex >= 0 ? () => setActiveTask(nextTaskIndex) : undefined} /></section>

    <section className={`learning-complete-card${complete ? ' learning-complete-card--done' : ''}`}><CircleCheck size={23} /><div><strong>{complete ? '今天的学习已完成' : readyToComplete ? '可以完成今天的学习了' : '完成训练和复习后再收尾'}</strong><p>{complete ? '词块已经加入后续复习队列。明天打开 AirRead 即可继续。' : pendingReviewCount > 0 ? `还有 ${pendingReviewCount} 项复习需要完成。` : `还有 ${Math.max(0, pack.tasks.length - completedCount)} 项训练需要完成。`}</p></div><button className={complete ? 'secondary-button' : 'primary-action'} type="button" onClick={onCompletePack} disabled={!complete && !readyToComplete}>{complete ? '已完成' : '完成今日学习'}</button></section>
  </section>;
}

function SparkleMark() {
  return <svg viewBox="0 0 28 28" aria-hidden="true"><path d="M14 1.8 17 11l9.2 3-9.2 3-3 9.2-3-9.2-9.2-3 9.2-3 3-9.2Z" fill="currentColor" /></svg>;
}

export function PlanPage({ plan, onMinutesChange, onRefreshPlan }: { plan: LearningPlan; onMinutesChange: (minutes: number) => void; onRefreshPlan: () => void }) {
  return <section className="learning-page learning-plan-page" aria-labelledby="plan-title">
    <header className="learning-page__header learning-plan-page__header"><div><p className="eyebrow">自动编排</p><h2 id="plan-title">你的英语能力计划</h2><p className="page-lede">目标固定为听、说、读都能应对真实英语。你只决定每天能留给自己的时间。</p></div><button className="plan-refresh-button" type="button" onClick={onRefreshPlan}><RefreshCw size={16} /><span>换一批</span></button></header>
    <section className="time-setting-card"><span className="time-setting-card__icon"><Clock3 size={22} /></span><div><p className="eyebrow">每日可用时间</p><h3>今天和之后每天，我能学</h3></div><label><DailyMinutesInput value={plan.dailyMinutes} onChange={onMinutesChange} /><span>分钟</span></label></section>
    <p className="learning-plan-note">改动时长后，七天训练结构和今天的材料会同步重排；已经完成的复习仍会保留。</p>
    <section className="learning-section learning-plan-list" aria-label="七天学习计划">{plan.days.map((day, index) => <article key={day.date} className={day.date === todayKey() ? 'learning-plan-day learning-plan-day--today' : 'learning-plan-day'}><span className="learning-plan-day__index">{index + 1}</span><div><small>{formatDate(day.date)}</small><h3>{day.theme}</h3><p>{day.focus}</p><span className="learning-plan-day__pattern">{day.practicePattern}</span></div><strong>{day.minutes}<small>分钟</small></strong></article>)}</section>
  </section>;
}

function ReviewCard({ card, compact = false, onReview }: { card: LearningReviewCard; compact?: boolean; onReview: (remembered: boolean) => void }) {
  const [revealed, setRevealed] = useState(false);
  return <article className={`review-card${compact ? ' review-card--compact' : ''}`}><small>先回忆，不要急着看答案</small><h3>{card.term}</h3>{revealed ? <><p>{card.meaning}</p><em>{card.example}</em><div><button type="button" className="secondary-button" onClick={() => onReview(false)}>没想起来</button><button type="button" className="primary-action" onClick={() => onReview(true)}>记住了</button></div></> : <button className="review-card__reveal" type="button" onClick={() => setRevealed(true)}>显示释义</button>}</article>;
}
