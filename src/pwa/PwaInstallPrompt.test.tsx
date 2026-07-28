import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { PwaInstallPrompt } from './PwaInstallPrompt';

describe('PwaInstallPrompt', () => {
  afterEach(() => vi.restoreAllMocks());

  it('offers a user-initiated install after the browser defers its prompt', async () => {
    const prompt = vi.fn().mockResolvedValue(undefined);
    const event = Object.assign(new Event('beforeinstallprompt', { cancelable: true }), {
      prompt,
      userChoice: Promise.resolve({ outcome: 'accepted' as const }),
    });
    render(<PwaInstallPrompt />);

    window.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(await screen.findByRole('button', { name: '安装' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '安装' }));
    await waitFor(() => expect(prompt).toHaveBeenCalledOnce());
    await waitFor(() => expect(screen.queryByLabelText('安装 AirRead')).not.toBeInTheDocument());
  });
});
