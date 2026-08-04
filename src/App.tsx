import { useEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent, type ReactNode } from 'react';
import { Clock3, Settings2, Target } from 'lucide-react';

import { ProviderProfileStore } from './domain/ai/providerStore';
import { generateLearningPack, isLearningModel } from './domain/learning/learningGenerator';
import { persistAutomaticStoryArchive } from './domain/learning/storyArchive';
import { completePack, completeTask, dueReviewCards, latestPackForDate, loadLearningState, packsForDate, reviewCard, rewindStoryForPack, saveGeneratedStory, saveLearningState, savePrefetchedStory, saveTaskResponse, startNewStory, todayKey, updateChapterWordCount, updateDailyMinutes, updateStoryProfile, usePrefetchedStory } from './domain/learning/learningStore';
import type { LearningPack, LearningState, LearningStoryMemory } from './domain/learning/learningTypes';
import { LearningSettingsPage } from './features/learning/LearningSettingsPage';
import { TodayPage } from './features/learning/LearningPages';
import './styles/global.css';

type AppRoute = 'today' | 'settings';
type AppLocation = { route: AppRoute };

const providerStore = new ProviderProfileStore();

const locationFromHash = (): AppLocation => {
  const rawRoute = window.location.hash.slice(1).split('/')[0];
  if (rawRoute === 'plan') {
    window.history.replaceState(null, '', '#today');
    return { route: 'today' };
  }
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
  const datePacks = packsForDate(state.packs, date).sort((left, right) => right.story.chapterNumber - left.story.chapterNumber);
  const packIds = new Set(datePacks.map((pack) => pack.id));
  const rewound = datePacks.reduce((current, pack) => rewindStoryForPack(current, pack), state);
  const remainingPacks = Object.fromEntries(Object.entries(rewound.packs).filter(([, pack]) => pack.date !== date));
  return {
    ...rewound,
    packs: remainingPacks,
    completedPackIds: state.completedPackIds.filter((id) => !packIds.has(id)),
    completedTaskIds: state.completedTaskIds.filter((id) => ![...packIds].some((packId) => id.startsWith(`${packId}:`))),
    taskResponses: Object.fromEntries(Object.entries(state.taskResponses).filter(([id]) => ![...packIds].some((packId) => id.startsWith(`${packId}:`)))),
    prefetchedStory: undefined,
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
  const [prefetchingNextChapter, setPrefetchingNextChapter] = useState(false);
  const [generationError, setGenerationError] = useState<string>();
  const [prefetchError, setPrefetchError] = useState<string>();
  const [modelVersion, setModelVersion] = useState(0);
  const automaticGenerationRef = useRef<string | undefined>(undefined);
  const prefetchGenerationRef = useRef<string | undefined>(undefined);

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
  const todayPack = latestPackForDate(learningState.packs, todayKey());
  const todayPlanDay = learningState.plan.days.find((day) => day.date === todayKey());

  const prefetchNextChapter = async (sourcePack: LearningPack, sourceMemory: LearningStoryMemory) => {
    if (!selectedModel) return;
    const prefetchKey = `${sourcePack.id}:${selectedModel.id}:${learningState.plan.dailyMinutes}:${learningState.storyProfile.chapterWordCount}`;
    if (prefetchGenerationRef.current === prefetchKey) return;
    prefetchGenerationRef.current = prefetchKey;
    setPrefetchingNextChapter(true);
    setPrefetchError(undefined);
    try {
      const generated = await generateLearningPack(selectedModel, learningState.plan.dailyMinutes, todayKey(), todayPlanDay, learningState.storyProfile, sourceMemory);
      setLearningState((current) => {
        if (current.storyMemory?.storyId !== sourceMemory.storyId
          || current.storyMemory.chapterNumber !== sourceMemory.chapterNumber
          || current.plan.dailyMinutes !== learningState.plan.dailyMinutes
          || current.storyProfile.chapterWordCount !== learningState.storyProfile.chapterWordCount
          || !Object.values(current.packs).some((pack) => pack.id === sourcePack.id)) return current;
        const next = savePrefetchedStory(current, sourcePack.id, generated);
        saveLearningState(next);
        return next;
      });
    } catch {
      prefetchGenerationRef.current = undefined;
      setPrefetchError('下一章未能提前准备好，完成当前学习后仍可手动生成。');
    } finally {
      setPrefetchingNextChapter(false);
    }
  };

  const handleGenerate = async () => {
    if (generating) return;
    setGenerating(true);
    setGenerationError(undefined);
    try {
      const generated = await generateLearningPack(selectedModel, learningState.plan.dailyMinutes, todayKey(), todayPlanDay, learningState.storyProfile, learningState.storyMemory);
      const nextState = saveGeneratedStory(learningState, generated.pack, generated.storyMemory);
      persist(nextState, setLearningState);
      void persistAutomaticStoryArchive(generated.storyMemory, nextState.packs);
      void prefetchNextChapter(generated.pack, generated.storyMemory);
    } catch (cause) {
      const message = cause instanceof Error ? cause.message.trim() : '';
      setGenerationError(message || '生成失败，请稍后重试。');
    } finally {
      setGenerating(false);
    }
  };

  useEffect(() => {
    if (todayPack || generating || !selectedModel) return;
    const generationKey = `${todayKey()}:${selectedModel.id}:${learningState.plan.dailyMinutes}:${learningState.plan.themeSetIndex}:${learningState.storyProfile.chapterWordCount}:${learningState.storyMemory?.storyId ?? 'new'}:${learningState.storyMemory?.chapterNumber ?? 0}`;
    if (automaticGenerationRef.current === generationKey) return;
    automaticGenerationRef.current = generationKey;
    void handleGenerate();
  }, [generating, learningState.plan.dailyMinutes, learningState.plan.themeSetIndex, learningState.storyProfile.chapterWordCount, learningState.storyMemory?.chapterNumber, learningState.storyMemory?.storyId, selectedModel, todayPack, todayPlanDay?.focus, todayPlanDay?.theme]);

  const handleMinutesChange = (minutes: number) => {
    const next = clearTodayLearning(updateDailyMinutes(learningState, minutes));
    automaticGenerationRef.current = undefined;
    prefetchGenerationRef.current = undefined;
    setGenerationError(undefined);
    setPrefetchError(undefined);
    persist(next, setLearningState);
  };

  const handleModelChange = (id: string | undefined) => {
    persist({ ...learningState, selectedModelId: id, prefetchedStory: undefined }, setLearningState);
    prefetchGenerationRef.current = undefined;
    setPrefetchError(undefined);
    setModelVersion((version) => version + 1);
  };

  const handleChapterWordCountChange = (chapterWordCount: number) => {
    persist(updateChapterWordCount(learningState, chapterWordCount), setLearningState);
    prefetchGenerationRef.current = undefined;
    setPrefetchError(undefined);
  };

  const handleStoryProfileChange = (premise: string) => {
    persist(updateStoryProfile(learningState, premise), setLearningState);
  };

  const handleStartNewStory = (premise: string) => {
    automaticGenerationRef.current = undefined;
    prefetchGenerationRef.current = undefined;
    setGenerationError(undefined);
    setPrefetchError(undefined);
    persist(startNewStory(updateStoryProfile(learningState, premise)), setLearningState);
  };

  const handleContinueToNextChapter = () => {
    if (todayPack && learningState.prefetchedStory?.sourcePackId === todayPack.id) {
      const prepared = learningState.prefetchedStory;
      const nextState = usePrefetchedStory(learningState, todayPack.id);
      persist(nextState, setLearningState);
      void persistAutomaticStoryArchive(prepared.storyMemory, nextState.packs);
      void prefetchNextChapter(prepared.pack, prepared.storyMemory);
      return;
    }
    void handleGenerate();
  };

  let content: ReactNode;
  if (location.route === 'settings') {
    content = <LearningSettingsPage store={providerStore} dailyMinutes={learningState.plan.dailyMinutes} selectedModelId={learningState.selectedModelId} storyProfile={learningState.storyProfile} storyMemory={learningState.storyMemory} packs={learningState.packs} generating={generating} generationError={generationError} onMinutesChange={handleMinutesChange} onModelChange={handleModelChange} onStoryProfileChange={handleStoryProfileChange} onChapterWordCountChange={handleChapterWordCountChange} onStartNewStory={handleStartNewStory} />;
  } else {
    content = <TodayPage pack={todayPack} dueReviewCards={dueReviewCards(learningState)} completedTaskIds={learningState.completedTaskIds} taskResponses={learningState.taskResponses} completedPackIds={learningState.completedPackIds} generating={generating} generationError={generationError} nextChapterReady={learningState.prefetchedStory?.sourcePackId === todayPack?.id} prefetchingNextChapter={prefetchingNextChapter} prefetchError={prefetchError} onGenerate={() => { void handleGenerate(); }} onGenerateNextChapter={handleContinueToNextChapter} onReview={(cardId, remembered) => persist(reviewCard(learningState, cardId, remembered), setLearningState)} onSaveTaskResponse={(taskId, response) => persist(saveTaskResponse(learningState, taskId, response), setLearningState)} onCompleteTask={(taskId) => persist(completeTask(learningState, taskId), setLearningState)} onCompletePack={() => todayPack && persist(completePack(learningState, todayPack), setLearningState)} />;
  }

  return <div className="app-shell learning-app" data-route={location.route} onClickCapture={clearPointerControlFocus}>
    <aside className="app-rail">
      <header className="brand"><a className="brand-lockup" href="#today" aria-label="AirRead 英语学习"><span className="brand-mark" aria-hidden="true"><img src="/icons/airread-mark.svg" alt="" /></span><h1 className="brand-copy"><strong>AirRead</strong><em>英语学习</em><small>每天学一点，真的听得懂</small></h1></a><a className="brand-utility" href={location.route === 'settings' ? '#today' : '#settings'} aria-label={location.route === 'settings' ? '关闭学习设置' : '学习设置'} title={location.route === 'settings' ? '关闭学习设置' : '学习设置'} aria-current={location.route === 'settings' ? 'page' : undefined}><Settings2 size={17} /></a></header>
      <div className="learning-goal-card"><Target size={17} /><div><strong>固定学习目标</strong><span>听懂 · 交流 · 阅读 · 应试</span></div></div>
      <div className="rail-footer"><Clock3 size={16} /> 每天 {learningState.plan.dailyMinutes} 分钟 · 本地保存</div>
    </aside>
    <main>{content}</main>
  </div>;
}
