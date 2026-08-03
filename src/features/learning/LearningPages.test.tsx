import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { createCuratedPack } from '../../domain/learning/learningGenerator';
import { buildPlan } from '../../domain/learning/learningStore';
import { PlanPage, TodayPage } from './LearningPages';

describe('TodayPage', () => {
  it('clearly distinguishes original source audio from system read-aloud', () => {
    const pack = {
      ...createCuratedPack('2026-08-03', 15),
      audioNote: 'original' as const,
      audio: { url: 'https://audio.example/lesson.mp3', label: '公开录音', language: 'en', accent: 'US', license: 'CC BY 4.0' },
    };

    render(<TodayPage pack={pack} dueReviewCards={[]} completedTaskIds={[]} completedPackIds={[]} onGenerate={vi.fn()} onReview={vi.fn()} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    expect(screen.getByText('原版音频')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '使用系统朗读英文原文' })).not.toBeInTheDocument();
    expect(screen.getByText('音频：公开录音 · US')).toBeInTheDocument();
  });

  it('puts due review cards into the daily learning flow before new practice', () => {
    const onReview = vi.fn();
    const pack = createCuratedPack('2026-08-03', 15);
    const dueCard = { id: 'review-1', term: 'be ready to', meaning: '准备好', example: 'I am ready to start.', dueAt: '2026-08-03', intervalDays: 1, repetitions: 1 };

    render(<TodayPage pack={pack} dueReviewCards={[dueCard]} completedTaskIds={pack.tasks.map((task) => task.id)} completedPackIds={[]} onGenerate={vi.fn()} onReview={onReview} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    expect(screen.getByRole('heading', { name: '今日复习' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '今天的训练' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '显示释义' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '完成今日学习' })).toBeDisabled();
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
