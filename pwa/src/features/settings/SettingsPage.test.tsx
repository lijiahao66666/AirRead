import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { BUILT_IN_FREE_PROFILE } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { ProviderConnectionError } from '../../domain/ai/translationTypes';
import { SettingsPage } from './SettingsPage';

describe('SettingsPage', () => {
  beforeEach(() => localStorage.clear());

  it('shows exact local privacy guidance and protects the built-in free profile', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);

    expect(screen.getByText('书籍和服务密钥只保存在当前浏览器。使用第三方翻译时，选中的文本会直接发送到该服务。')).toBeInTheDocument();
    expect(screen.getByText('AirRead 会从当前浏览器直接请求你选择的服务，不经过 AirRead 服务器。部分服务不允许网页直接连接；若测试失败，请改用支持浏览器访问的地址，或在自己的设备上运行中转服务。')).toBeInTheDocument();
    expect(screen.getByText('免费翻译')).toBeInTheDocument();
    expect(screen.getByText('当前使用')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '删除 免费翻译' })).not.toBeInTheDocument();
  });

  it('validates, creates, edits, enables, disables, selects, and deletes a profile', async () => {
    const store = new ProviderProfileStore(localStorage);
    const testConnection = vi.fn().mockResolvedValue(undefined);
    render(<SettingsPage store={store} testConnection={testConnection} />);

    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    expect(screen.getByRole('heading', { name: '添加翻译服务' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('服务类型'), { target: { value: 'openai-compatible' } });
    expect(screen.getByRole('button', { name: '保存配置' })).toBeDisabled();

    fireEvent.change(screen.getByLabelText('服务名称'), { target: { value: '我的模型' } });
    fireEvent.change(screen.getByLabelText('Base URL'), { target: { value: 'https://models.example/v1' } });
    fireEvent.change(screen.getByLabelText('模型名称'), { target: { value: 'reader-model' } });
    fireEvent.change(screen.getByLabelText('API Key'), { target: { value: 'sk-local-secret' } });
    expect(screen.getByLabelText('API Key')).toHaveAttribute('type', 'password');
    expect(document.body.textContent).not.toContain('sk-local-secret');
    fireEvent.click(screen.getByRole('button', { name: '显示密钥' }));
    expect(screen.getByLabelText('API Key')).toHaveAttribute('type', 'text');
    fireEvent.click(screen.getByRole('button', { name: '隐藏密钥' }));
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));

    expect(screen.getByText('我的模型')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '设为当前 我的模型' }));
    expect(store.selected().name).toBe('我的模型');
    fireEvent.click(screen.getByRole('button', { name: '停用 我的模型' }));
    expect(store.get(store.list()[1].id)?.enabled).toBe(false);
    expect(store.selected()).toEqual(BUILT_IN_FREE_PROFILE);
    fireEvent.click(screen.getByRole('button', { name: '启用 我的模型' }));

    fireEvent.click(screen.getByRole('button', { name: '编辑 我的模型' }));
    expect(screen.getByRole('heading', { name: '编辑翻译服务' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('服务名称'), { target: { value: '更新模型' } });
    fireEvent.click(screen.getByRole('button', { name: '测试连接' }));
    await waitFor(() => expect(screen.getByText('连接成功')).toBeInTheDocument());
    expect(testConnection).toHaveBeenCalledWith(expect.objectContaining({ name: '更新模型', apiKey: 'sk-local-secret' }));
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));

    fireEvent.click(screen.getByRole('button', { name: '删除 更新模型' }));
    expect(screen.queryByText('更新模型')).not.toBeInTheDocument();
  });

  it('shows browser-blocked guidance without an Air proxy or secret-bearing error', async () => {
    const store = new ProviderProfileStore(localStorage);
    store.save({
      id: 'blocked', name: '浏览器受限模型', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://blocked.example/v1', model: 'reader', apiKey: 'never-show-this-secret',
    });
    const testConnection = vi.fn().mockRejectedValue(new ProviderConnectionError('浏览器受限模型'));
    render(<SettingsPage store={store} testConnection={testConnection} />);

    fireEvent.click(screen.getByRole('button', { name: '编辑 浏览器受限模型' }));
    fireEvent.click(screen.getByRole('button', { name: '测试连接' }));
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('该翻译服务不允许浏览器直接连接。请使用支持网页调用的地址，或运行你自己的本地中转服务'));
    expect(document.body.textContent).not.toContain('never-show-this-secret');
    expect(document.body.textContent).not.toContain('Air proxy');
  });

  it('masks an existing secret while allowing test and save to use the stored credential', async () => {
    const store = new ProviderProfileStore(localStorage);
    store.save({
      id: 'masked-edit', name: '已保存模型', kind: 'openai-compatible', enabled: true,
      baseUrl: 'https://models.example/v1', model: 'reader', apiKey: 'sk-original-secret',
    });
    const testConnection = vi.fn().mockResolvedValue(undefined);
    render(<SettingsPage store={store} testConnection={testConnection} />);

    fireEvent.click(screen.getByRole('button', { name: '编辑 已保存模型' }));
    expect(screen.getByLabelText('API Key')).toHaveValue('sk-••••••••••ret');
    expect(screen.getByLabelText('API Key')).not.toHaveValue('sk-original-secret');
    expect(document.body.textContent).not.toContain('sk-original-secret');
    fireEvent.click(screen.getByRole('button', { name: '测试连接' }));
    await waitFor(() => expect(testConnection).toHaveBeenCalledWith(expect.objectContaining({ apiKey: 'sk-original-secret' })));
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));
    expect(store.get('masked-edit')?.apiKey).toBe('sk-original-secret');
  });

  it('disables save and connection test until a profile passes validation', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);
    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    expect(screen.getByRole('button', { name: '保存配置' })).toBeDisabled();
    expect(screen.getByRole('button', { name: '测试连接' })).toBeDisabled();
  });
});
