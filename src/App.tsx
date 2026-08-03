import { useEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent, type ReactNode } from 'react';
import { CalendarDays, Clock3, Home, Settings2, Target, RotateCcw } from 'lucide-react';

import { ProviderProfileStore } from './domain/ai/providerStore';
import { createCuratedPack, generateLearningPack, isLearningModel } from './domain/learning/learningGenerator';
import { completePack, completeTask, loadLearningState, reviewCard, saveLearningState, savePack, todayKey, updateDailyMinutes } from './domain/learning/learningStore';
import type { LearningState } from './domain/learning/learningTypes';
import { LearningSettingsPage } from './features/learning/LearningSettingsPage';
import { PlanPage, ReviewPage, TodayPage } from './features/learning/LearningPages';
import './styles/global.css';

type AppRoute = 'today' | 'plan' | 'review' | 'settings';
type AppLocation = { route: AppRoute };

const providerStore = new ProviderProfileStore();
const navigation: Array<{ label: string; route: AppRoute; icon: typeof Home }> = [
  { label: '今日学习', route: 'today', icon: Home },
  { label: '学习计划', route: 'plan', icon: CalendarDays },
  { label: '复习', route: 'review', icon: RotateCcw },
];

const locationFromHash = (): AppLocation => {
  const rawRoute = window.location.hash.slice(1).split('/')[0];
  if (rawRoute === 'plan') return { route: 'plan' };
  if (rawRoute === 'review') return { route: 'review' };
  if (rawRoute === 'settings') return { route: 'settings' };
  return { route: 'today' };
};

const persist = (next: LearningState, setState: (state: LearningState) => void): void => {
  setState(next);
  saveLearningState(next);
};

const bootstrapLearningState = (): LearningState => {
  const state = loadLearningState();
  if (state.packs[todayKey()]) return state;
  const configuredModel = state.selectedModelId ? providerStore.get(state.selectedModelId) : providerStore.selected();
  if (isLearningModel(configuredModel)) return state;
  const seeded = savePack(state, createCuratedPack(todayKey(), state.plan.dailyMinutes));
  saveLearningState(seeded);
  return seeded;
};

function clearPointerControlFocus(event: ReactMouseEvent<HTMLDivElement>) {
  if (event.detail === 0 || !(event.target instanceof Element)) return;
  const activatedControl = event.target.closest('button, a');
  if (activatedControl instanceof HTMLElement) activatedControl.blur();
}

export default function App() {
  const [location, setLocation] = useState<AppLocation>(locationFromHash);
  const [learningState, setLearningState] = useState<LearningState>(bootstrapLearningState);
  const [generating, setGenerating] = useState(false);
  const [generationError, setGenerationError] = useState<string>();
  const [modelVersion, setModelVersion] = useState(0);
  const automaticGenerationRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    const onHashChange = () => setLocation(locationFromHash());
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  useEffect(() => {
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
  }, [location.route]);

  const modelProfiles = useMemo(() => providerStore.list().filter(isLearningModel), [modelVersion]);
  const selectedModel = useMemo(() => modelProfiles.find((profile) => profile.id === learningState.selectedModelId) ?? modelProfiles[0], [learningState.selectedModelId, modelProfiles]);
  const todayPack = learningState.packs[todayKey()];

  const handleGenerate = async () => {
    if (generating) return;
    setGenerating(true);
    setGenerationError(undefined);
    try {
      const pack = await generateLearningPack(selectedModel, learningState.plan.dailyMinutes);
      persist(savePack(learningState, pack), setLearningState);
    } catch (cause) {
      setGenerationError(cause instanceof Error ? cause.message : '学习包生成失败，请检查模型配置后重试');
    } finally {
      setGenerating(false);
    }
  };

  useEffect(() => {
    if (todayPack || generating) return;
    if (!selectedModel) {
      persist(savePack(learningState, createCuratedPack(todayKey(), learningState.plan.dailyMinutes)), setLearningState);
      return;
    }
    const generationKey = `${todayKey()}:${selectedModel.id}:${learningState.plan.dailyMinutes}`;
    if (automaticGenerationRef.current === generationKey) return;
    automaticGenerationRef.current = generationKey;
    void handleGenerate();
  }, [generating, learningState.plan.dailyMinutes, selectedModel, todayPack]);

  const handleMinutesChange = (minutes: number) => {
    const next = updateDailyMinutes(learningState, minutes);
    const { [todayKey()]: _today, ...remainingPacks } = next.packs;
    persist({ ...next, packs: remainingPacks }, setLearningState);
  };

  const handleModelChange = (id: string | undefined) => {
    persist({ ...learningState, selectedModelId: id }, setLearningState);
    setModelVersion((version) => version + 1);
  };

  let content: ReactNode;
  if (location.route === 'plan') {
    content = <PlanPage plan={learningState.plan} onMinutesChange={handleMinutesChange} />;
  } else if (location.route === 'review') {
    content = <ReviewPage state={learningState} onReview={(cardId, remembered) => persist(reviewCard(learningState, cardId, remembered), setLearningState)} />;
  } else if (location.route === 'settings') {
    content = <LearningSettingsPage store={providerStore} dailyMinutes={learningState.plan.dailyMinutes} selectedModelId={learningState.selectedModelId} onMinutesChange={handleMinutesChange} onModelChange={handleModelChange} />;
  } else {
    content = <TodayPage pack={todayPack} completedTaskIds={learningState.completedTaskIds} completedPackIds={learningState.completedPackIds} generating={generating} generationError={generationError} onGenerate={() => { void handleGenerate(); }} onCompleteTask={(taskId) => persist(completeTask(learningState, taskId), setLearningState)} onCompletePack={() => todayPack && persist(completePack(learningState, todayPack), setLearningState)} />;
  }

  return <div className="app-shell learning-app" data-route={location.route} onClickCapture={clearPointerControlFocus}>
    <aside className="app-rail">
      <header className="brand"><a className="brand-lockup" href="#today" aria-label="AirRead 英语学习"><span className="brand-mark" aria-hidden="true"><img src="/icons/airread-mark.svg" alt="" /></span><h1 className="brand-copy"><strong>AirRead</strong><em>英语学习</em><small>每天学一点，真的听得懂</small></h1></a><a className="brand-utility" href="#settings" aria-label="学习设置" title="学习设置" aria-current={location.route === 'settings' ? 'page' : undefined}><Settings2 size={17} /></a></header>
      <div className="learning-goal-card"><Target size={17} /><div><strong>固定学习目标</strong><span>听懂 · 交流 · 阅读 · 应试</span></div></div>
      <nav className="primary-navigation" aria-label="主导航">{navigation.map(({ label, route, icon: Icon }) => <a key={route} href={`#${route}`} aria-current={location.route === route ? 'page' : undefined}><Icon size={18} /> <span>{label}</span></a>)}</nav>
      <div className="rail-footer"><Clock3 size={16} /> 每天 {learningState.plan.dailyMinutes} 分钟 · 本地保存</div>
    </aside>
    <main>{content}</main>
  </div>;
}
