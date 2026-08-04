import { fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { createStoryMemoryFixture } from '../../test/learningFixture';
import { LearningSettingsPage } from './LearningSettingsPage';

describe('LearningSettingsPage serial story controls', () => {
  afterEach(() => vi.restoreAllMocks());

  it('saves an optional premise and exposes an EPUB archive for the current story', () => {
    const storage = window.localStorage;
    storage.clear();
    const onStoryProfileChange = vi.fn();
    const onStartNewStory = vi.fn();
    const memory = createStoryMemoryFixture();

    render(<LearningSettingsPage
      store={new ProviderProfileStore(storage)}
      dailyMinutes={15}
      storyProfile={{ premise: '', createdAt: 1 }}
      storyMemory={memory}
      packs={{}}
      onMinutesChange={vi.fn()}
      onModelChange={vi.fn()}
      onStoryProfileChange={onStoryProfileChange}
      onStartNewStory={onStartNewStory}
    />);

    const premise = screen.getByRole('textbox', { name: '你的大概设定（可选）' });
    fireEvent.change(premise, { target: { value: '轻科幻悬疑，主角在地铁里收到未来消息。' } });
    fireEvent.click(screen.getByRole('button', { name: '保存设定' }));
    expect(onStoryProfileChange).toHaveBeenCalledWith('轻科幻悬疑，主角在地铁里收到未来消息。');
    expect(screen.getByRole('button', { name: '导出 EPUB' })).toBeInTheDocument();
  });

  it('requires confirmation before starting a new story', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false);
    const onStartNewStory = vi.fn();
    render(<LearningSettingsPage
      store={new ProviderProfileStore(window.localStorage)}
      dailyMinutes={15}
      storyProfile={{ premise: '旧设定', createdAt: 1 }}
      storyMemory={createStoryMemoryFixture()}
      packs={{}}
      onMinutesChange={vi.fn()}
      onModelChange={vi.fn()}
      onStoryProfileChange={vi.fn()}
      onStartNewStory={onStartNewStory}
    />);

    fireEvent.click(screen.getByRole('button', { name: '开始新故事' }));

    expect(window.confirm).toHaveBeenCalled();
    expect(onStartNewStory).not.toHaveBeenCalled();
  });
});
