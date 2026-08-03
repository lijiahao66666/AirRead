import { useEffect, useState } from 'react';
import { AudioLines, BookOpenText, Check, ChevronRight, CircleCheck, Clock3, Headphones, Languages, PenLine, RefreshCw, RotateCcw, Volume2 } from 'lucide-react';

import { PwaInstallPrompt } from '../../pwa/PwaInstallPrompt';
import { todayKey } from '../../domain/learning/learningStore';
import type { LearningPack, LearningPlan, LearningReviewCard, LearningTask } from '../../domain/learning/learningTypes';
import { DailyMinutesInput } from './DailyMinutesInput';

export type TodayPageProps = {
  pack?: LearningPack;
  dueReviewCards: LearningReviewCard[];
  completedTaskIds: string[];
  completedPackIds: string[];
  generating?: boolean;
  generationError?: string;
  onGenerate: () => void;
  onReview: (cardId: string, remembered: boolean) => void;
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

function SystemSpeechButton({ text }: { text: string }) {
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

  return <button type="button" className={`learning-icon-button${speaking ? ' learning-icon-button--active' : ''}`} onClick={toggle} disabled={!supported} aria-label={speaking ? '停止系统朗读' : '使用系统朗读英文原文'} title={supported ? '系统朗读（非原版音频）' : '当前浏览器不支持系统朗读'}><Volume2 size={17} /> <span>{speaking ? '停止' : '朗读'}</span></button>;
}

function TaskRow({ task, completed, onComplete }: { task: LearningTask; completed: boolean; onComplete: () => void }) {
  const Icon = taskIcons[task.kind];
  return <article className={`learning-task${completed ? ' learning-task--complete' : ''}`}>
    <span className="learning-task__icon"><Icon size={18} /></span>
    <div><small>{task.minutes} 分钟 · {task.kind === 'listen' ? '听力输入' : task.kind === 'speak' ? '口语输出' : task.kind === 'review' ? '间隔复习' : '主动学习'}</small><h3>{task.title}</h3><p>{task.instruction}</p></div>
    <button type="button" className="task-check" onClick={onComplete} aria-pressed={completed} aria-label={`${completed ? '已完成' : '完成'} ${task.title}`}>{completed ? <Check size={17} /> : <span />}</button>
  </article>;
}

export function TodayPage({ pack, dueReviewCards, completedTaskIds, completedPackIds, generating = false, generationError, onGenerate, onReview, onCompleteTask, onCompletePack }: TodayPageProps) {
  const [translationVisible, setTranslationVisible] = useState(false);
  const [activeTask, setActiveTask] = useState(0);
  const complete = pack ? completedPackIds.includes(pack.id) : false;
  const completedCount = pack?.tasks.filter((task) => completedTaskIds.includes(task.id)).length ?? 0;
  const activeTaskIndex = pack ? Math.min(activeTask, Math.max(0, pack.tasks.length - 1)) : 0;
  const pendingReviewCount = dueReviewCards.length;
  const readyToComplete = Boolean(pack && completedCount === pack.tasks.length && pendingReviewCount === 0);

  if (!pack) return <section className="learning-page learning-page--today" aria-labelledby="today-title">
    <header className="learning-page__header"><div><p className="eyebrow">每日英语学习包</p><h2 id="today-title">今天，学一点真的能用上的英语。</h2><p className="page-lede">系统会根据你设置的可用时间，安排输入、回忆、跟读和复习。</p></div></header>
    <PwaInstallPrompt />
    <section className="learning-empty-card"><span><SparkleMark /></span><h3>还没有今天的学习包</h3><p>先用本地练习样例开始；配置模型后，可以生成更贴近你节奏的内容。</p><button className="primary-action" type="button" onClick={onGenerate} disabled={generating}>{generating ? '正在准备…' : '准备今天的学习包'} <ChevronRight size={17} /></button>{generationError && <p className="learning-error" role="alert">{generationError}</p>}</section>
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
      <div className="translation-toggle"><button type="button" onClick={() => setTranslationVisible((visible) => !visible)} aria-expanded={translationVisible}><Languages size={16} /> {translationVisible ? '收起中文解释' : '查看中文解释'}</button>{translationVisible && <p>{pack.translation}</p>}</div>
      <footer className="learning-source-note">
        <span>{pack.audioNote === 'original' ? `音频：${pack.audio?.label}${pack.audio?.accent ? ` · ${pack.audio.accent}` : ''}` : '这份内容暂无原版录音，可用系统朗读辅助理解与跟读。'}</span>
        {pack.license && <span>{pack.license}</span>}
        {(pack.audio?.sourceUrl ?? pack.sourceUrl) && <a href={pack.audio?.sourceUrl ?? pack.sourceUrl} target="_blank" rel="noreferrer">{pack.audio?.sourceUrl ? '查看音频来源' : '查看来源'}</a>}
      </footer>
    </section>

    <section className="learning-section" aria-labelledby="vocabulary-title"><div className="learning-section__heading"><div><p className="eyebrow">词块，不是孤立单词</p><h3 id="vocabulary-title">今天需要记住</h3></div><span>{pack.vocabulary.length} 个</span></div><div className="vocabulary-list">{pack.vocabulary.map((item) => <article key={item.term}><strong>{item.term}</strong><p>{item.meaning}</p><small>{item.example}</small></article>)}</div></section>

    <section className="learning-section" aria-labelledby="tasks-title"><div className="learning-section__heading"><div><p className="eyebrow">按顺序完成</p><h3 id="tasks-title">今天的训练</h3></div><span>剩余 {Math.max(0, pack.tasks.length - completedCount)} 项</span></div><div className="learning-task-list">{pack.tasks.map((task, index) => <button className={`learning-task-launch${activeTaskIndex === index ? ' learning-task-launch--active' : ''}`} type="button" key={task.id} onClick={() => setActiveTask(index)}><span>{index + 1}</span><span>{task.title}</span></button>)}</div><TaskRow task={pack.tasks[activeTaskIndex]} completed={completedTaskIds.includes(pack.tasks[activeTaskIndex].id)} onComplete={() => onCompleteTask(pack.tasks[activeTaskIndex].id)} /></section>

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
