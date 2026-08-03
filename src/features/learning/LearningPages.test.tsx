import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { createCuratedPack } from '../../domain/learning/learningGenerator';
import { TodayPage } from './LearningPages';

describe('TodayPage', () => {
  it('clearly distinguishes original source audio from system read-aloud', () => {
    const pack = {
      ...createCuratedPack('2026-08-03', 15),
      audioNote: 'original' as const,
      audio: { url: 'https://audio.example/lesson.mp3', label: '公开录音', language: 'en', accent: 'US', license: 'CC BY 4.0' },
    };

    render(<TodayPage pack={pack} completedTaskIds={[]} completedPackIds={[]} onGenerate={vi.fn()} onCompleteTask={vi.fn()} onCompletePack={vi.fn()} />);

    expect(screen.getByText('原版音频')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '使用系统朗读英文原文' })).not.toBeInTheDocument();
    expect(screen.getByText('音频：公开录音 · US')).toBeInTheDocument();
  });
});
