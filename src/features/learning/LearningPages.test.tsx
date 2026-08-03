import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { createOpenLearningPack } from '../../domain/learning/learningGenerator';
import { buildPlan } from '../../domain/learning/learningStore';
import { PlanPage, TodayPage } from './LearningPages';

describe('TodayPage', () => {
  const pack = createOpenLearningPack('2026-08-03', 15, {
    title: 'City library',
    text: 'The city library opens early on weekdays. Visitors can borrow books and use computers. Staff members can help people find information.',
    sourceLabel: 'Simple English Wikipedia（开放资料）',
    sourceUrl: 'https://simple.wikipedia.org/wiki/Library',
    license: 'CC BY-SA 4.0',
  });

  it('clearly distinguishes original source audio from system read-aloud', () => {
    const audioPack = {
      ...pack,
      audioNote: 'original' as const,
      audio: { url: 'https://audio.example/lesson.mp3', label: '公开录音', language: 'en', accent: 'US', license: 'CC BY 4.0' },
    };

    render(<TodayPage pack={audioPack} dueReviewCards={[]} completedTaskIds={[]} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onSaveTaskResponse={vi.fn()} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    expect(screen.getByText('原版音频')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '使用系统朗读英文原文' })).not.toBeInTheDocument();
    expect(screen.getByText('音频：公开录音 · US')).toBeInTheDocument();
  });

  it('puts due review cards into the daily learning flow before new practice', () => {
    const onReview = vi.fn();
    const dueCard = { id: 'review-1', term: 'be ready to', meaning: '准备好', example: 'I am ready to start.', dueAt: '2026-08-03', intervalDays: 1, repetitions: 1 };

    render(<TodayPage pack={pack} dueReviewCards={[dueCard]} completedTaskIds={pack.tasks.map((task) => task.id)} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={onReview} onSaveTaskResponse={vi.fn()} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    expect(screen.getByRole('heading', { name: '今日复习' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今天的训练' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '显示释义' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '完成今日学习' })).toBeDisabled();
  });

  it('shows the source and vocabulary before asking for material-based training', () => {
    render(<TodayPage pack={pack} dueReviewCards={[]} completedTaskIds={[]} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onSaveTaskResponse={vi.fn()} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    const reader = screen.getByRole('heading', { name: '先理解，再翻译' });
    const vocabulary = screen.getByRole('heading', { name: '今天需要记住' });
    const training = screen.getByRole('heading', { name: '今天的训练' });
    expect(reader.compareDocumentPosition(vocabulary) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(vocabulary.compareDocumentPosition(training) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('turns vocabulary into an active recall card and continues to the next exercise', () => {
    const packWithVocabulary = {
      ...pack,
      vocabulary: [{ term: 'be ready to', meaning: '准备好做某事', example: 'I am ready to start.', dueAt: '2026-08-04', intervalDays: 1, repetitions: 0 }],
    };

    render(<TodayPage pack={packWithVocabulary} dueReviewCards={[]} completedTaskIds={[]} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onSaveTaskResponse={vi.fn()} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    expect(screen.queryByText('准备好做某事')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /be ready to/ }));
    expect(screen.getByText('准备好做某事')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '听辨训练' })).toBeInTheDocument();
    const listeningTask = packWithVocabulary.tasks.find((task) => task.kind === 'listen')!;
    fireEvent.click(screen.getByRole('button', { name: listeningTask.exercise!.answer! }));
    expect(screen.getByRole('heading', { name: '阅读填空' })).toBeInTheDocument();
  });

  it('uses an answerable mobile listening exercise instead of a completion check', () => {
    const onCompleteTask = vi.fn();

    render(<TodayPage pack={pack} dueReviewCards={[]} completedTaskIds={[]} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onSaveTaskResponse={vi.fn()} onCompleteTask={onCompleteTask} onCompletePack={vi.fn()} />);

    const listeningTask = pack.tasks.find((task) => task.kind === 'listen')!;
    expect(screen.getByRole('heading', { name: '听辨训练' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: listeningTask.exercise!.answer! }));
    expect(onCompleteTask).toHaveBeenCalledWith(listeningTask.id);
    expect(screen.queryByRole('button', { name: `完成 ${listeningTask.title}` })).not.toBeInTheDocument();
  });

  it('checks a reading answer before completing the task', () => {
    const onCompleteTask = vi.fn();
    const readTask = pack.tasks.find((task) => task.kind === 'read')!;

    render(<TodayPage pack={pack} dueReviewCards={[]} completedTaskIds={[]} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onSaveTaskResponse={vi.fn()} onCompleteTask={onCompleteTask} onCompletePack={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: '查看全部训练' }));
    fireEvent.click(screen.getByRole('button', { name: new RegExp(readTask.title) }));
    fireEvent.change(screen.getByRole('textbox', { name: '阅读填空答案' }), { target: { value: 'wrong' } });
    fireEvent.click(screen.getByRole('button', { name: '检查答案' }));
    expect(onCompleteTask).not.toHaveBeenCalled();
    fireEvent.change(screen.getByRole('textbox', { name: '阅读填空答案' }), { target: { value: readTask.exercise?.answer ?? '' } });
    fireEvent.click(screen.getByRole('button', { name: '检查答案' }));
    expect(onCompleteTask).toHaveBeenCalledWith(readTask.id);
  });

  it('requires a real written response before completing a writing task', () => {
    const onCompleteTask = vi.fn();
    const longPack = createOpenLearningPack('2026-08-03', 30, {
      title: 'City library',
      text: 'The city library opens early on weekdays. Visitors can borrow books and use computers. Staff members can help people find information.',
      sourceLabel: 'Simple English Wikipedia（开放资料）',
      sourceUrl: 'https://simple.wikipedia.org/wiki/Library',
      license: 'CC BY-SA 4.0',
    });
    const writeTask = longPack.tasks.find((task) => task.kind === 'write')!;

    render(<TodayPage pack={longPack} dueReviewCards={[]} completedTaskIds={[]} taskResponses={{}} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onSaveTaskResponse={vi.fn()} onCompleteTask={onCompleteTask} onCompletePack={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: '查看全部训练' }));
    fireEvent.click(screen.getByRole('button', { name: new RegExp(writeTask.title) }));
    const submit = screen.getByRole('button', { name: '保存并完成' });
    expect(submit).toBeDisabled();
    fireEvent.change(screen.getByRole('textbox', { name: '短写作回答' }), { target: { value: 'The library helps people learn and gives me a quiet place to read every day.' } });
    expect(submit).toBeEnabled();
    fireEvent.click(submit);
    expect(onCompleteTask).toHaveBeenCalledWith(writeTask.id);
  });

  it('updates the available time and lets the learner rotate the plan batch', () => {
    const onMinutesChange = vi.fn();
    const onRefreshPlan = vi.fn();

    render(<PlanPage plan={buildPlan(15, '2026-08-03')} onMinutesChange={onMinutesChange} onRefreshPlan={onRefreshPlan} />);

    const minutesInput = screen.getByRole('spinbutton', { name: '每日可用分钟数' });
    fireEvent.change(minutesInput, { target: { value: '30' } });
    fireEvent.blur(minutesInput);
    fireEvent.click(screen.getByRole('button', { name: '换一批' }));

    expect(onMinutesChange).toHaveBeenCalledWith(30);
    expect(onRefreshPlan).toHaveBeenCalledOnce();
    expect(screen.getAllByText('复习 · 听读 · 跟读')).toHaveLength(7);
  });
});
