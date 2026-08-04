import { useEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent, type ReactNode } from 'react';
import { CalendarDays, Clock3, Home, Settings2, Target } from 'lucide-react';

import { ProviderProfileStore } from './domain/ai/providerStore';
import { generateLearningPack, isLearningModel } from './domain/learning/learningGenerator';
import { persistAutomaticStoryArchive } from './domain/learning/storyArchive';
import { completePack, completeTask, dueReviewCards, loadLearningState, reviewCard, rewindStoryForPack, rotatePlan, saveGeneratedStory, saveLearningState, saveTaskResponse, startNewStory, todayKey, updateDailyMinutes, updateStoryProfile } from './domain/learning/learningStore';
import type { LearningState } from './domain/learning/learningTypes';
import { LearningSettingsPage } from './features/learning/LearningSettingsPage';
import { PlanPage, TodayPage } from './features/learning/LearningPages';
import './styles/global.css';

type AppRoute = 'today' | 'plan' | 'settings';
type AppLocation = { route: AppRoute };

const providerStore = new ProviderProfileStore();
const navigation: Array<{ label: string; route: AppRoute; icon: typeof Home }> = [
  { label: '今日学习', route: 'today', icon: Home },
  { label: '学习计划', route: 'plan', icon: CalendarDays },
];

const locationFromHash = (): AppLocation => {
  const rawRoute = window.location.hash.slice(1).split('/')[0];
  if (rawRoute === 'plan') return { route: 'plan' };
  if (rawRoute === 'review') return { route: 'today' };
  if (rawRoute === 'settings') return { route: 'settings' };
  return { route: 'today' };
};

const persist = (next: LearningState, setState: (state: LearningState) => void): void => {
  setState(next);
  saveLearningState(next);
};

const clearTodayLearning = (state: LearningState): LearningState => {
  const date = todayKey();
  const existingPack = state.packs[date];
  const rewound = rewindStoryForPack(state, existingPack);
  const existingPackId = existingPack?.id;
  const packIds = new Set([`pack-${date}`, existingPackId].filter((id): id is string => Boolean(id)));
  const { [date]: _today, ...remainingPacks } = rewound.packs;
  return {
    ...rewound,
    packs: remainingPacks,
    completedPackIds: state.completedPackIds.filter((id) => !packIds.has(id)),
    completedTaskIds: state.completedTaskIds.filter((id) => ![...packIds].some((packId) => id.startsWith(`${packId}:`))),
    taskResponses: Object.fromEntries(Object.entries(state.taskResponses).filter(([id]) => ![...packIds].some((packId) => id.startsWith(`${packId}:`)))),
  };
};

const bootstrapLearningState = (): LearningState => loadLearningState();

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
  const todayPlanDay = learningState.plan.days.find((day) => day.date === todayKey());

  const handleGenerate = async () => {
    if (generating) return;
    setGenerating(true);
    setGenerationError(undefined);
    try {
      const generated = await generateLearningPack(selectedModel, learningState.plan.dailyMinutes, todayKey(), todayPlanDay, learningState.storyProfile, learningState.storyMemory);
      const nextState = saveGeneratedStory(learningState, generated.pack, generated.storyMemory);
      persist(nextState, setLearningState);
      void persistAutomaticStoryArchive(generated.storyMemory, nextState.packs);
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : '';
      setGenerationError(message.includes('请先在学习设置中') ? message : '模型暂时无法连接或返回内容不完整，请检查模型设置后重试。');
    } finally {
      setGenerating(false);
    }
  };

  useEffect(() => {
    if (todayPack || generating || !selectedModel) return;
    const generationKey = `${todayKey()}:${selectedModel.id}:${learningState.plan.dailyMinutes}:${learningState.plan.themeSetIndex}:${learningState.storyMemory?.storyId ?? 'new'}:${learningState.storyMemory?.chapterNumber ?? 0}`;
    if (automaticGenerationRef.current === generationKey) return;
    automaticGenerationRef.current = generationKey;
    void handleGenerate();
  }, [generating, learningState.plan.dailyMinutes, learningState.plan.themeSetIndex, learningState.storyMemory?.chapterNumber, learningState.storyMemory?.storyId, selectedModel, todayPack, todayPlanDay?.focus, todayPlanDay?.theme]);

  const handleMinutesChange = (minutes: number) => {
    const next = clearTodayLearning(updateDailyMinutes(learningState, minutes));
    automaticGenerationRef.current = undefined;
    setGenerationError(undefined);
    persist(next, setLearningState);
  };

  const handlePlanRefresh = () => {
    const next = clearTodayLearning(rotatePlan(learningState));
    automaticGenerationRef.current = undefined;
    setGenerationError(undefined);
    persist(next, setLearningState);
  };

  const handleModelChange = (id: string | undefined) => {
    persist({ ...learningState, selectedModelId: id }, setLearningState);
    setModelVersion((version) => version + 1);
  };

  const handleStoryProfileChange = (premise: string) => {
    persist(updateStoryProfile(learningState, premise), setLearningState);
  };

  const handleStartNewStory = (premise: string) => {
    automaticGenerationRef.current = undefined;
    setGenerationError(undefined);
    persist(startNewStory(updateStoryProfile(learningState, premise)), setLearningState);
  };

  let content: ReactNode;
  if (location.route === 'plan') {
    content = <PlanPage plan={learningState.plan} onMinutesChange={handleMinutesChange} onRefreshPlan={handlePlanRefresh} />;
  } else if (location.route === 'settings') {
    content = <LearningSettingsPage store={providerStore} dailyMinutes={learningState.plan.dailyMinutes} selectedModelId={learningState.selectedModelId} storyProfile={learningState.storyProfile} storyMemory={learningState.storyMemory} packs={learningState.packs} onMinutesChange={handleMinutesChange} onModelChange={handleModelChange} onStoryProfileChange={handleStoryProfileChange} onStartNewStory={handleStartNewStory} />;
  } else {
    content = <TodayPage pack={todayPack} dueReviewCards={dueReviewCards(learningState)} completedTaskIds={learningState.completedTaskIds} taskResponses={learningState.taskResponses} completedPackIds={learningState.completedPackIds} generating={generating} generationError={generationError} onGenerate={() => { void handleGenerate(); }} onReview={(cardId, remembered) => persist(reviewCard(learningState, cardId, remembered), setLearningState)} onSaveTaskResponse={(taskId, response) => persist(saveTaskResponse(learningState, taskId, response), setLearningState)} onCompleteTask={(taskId) => persist(completeTask(learningState, taskId), setLearningState)} onCompletePack={() => todayPack && persist(completePack(learningState, todayPack), setLearningState)} />;
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
