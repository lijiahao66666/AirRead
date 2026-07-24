import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { BUILT_IN_FREE_PROFILE } from '../../domain/ai/providerProfile';
import { ProviderProfileStore } from '../../domain/ai/providerStore';
import { ProviderConnectionError } from '../../domain/ai/translationTypes';
import { ReaderPreferencesStore } from '../reader/readerPreferences';
import { SettingsPage } from './SettingsPage';

describe('SettingsPage', () => {
  beforeEach(() => localStorage.clear());

  it('shows exact local privacy guidance and protects the built-in free profile', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);

    expect(screen.getByText('书籍和服务密钥只保存在当前浏览器。使用第三方翻译时，待翻译文本会直接发送到该服务。')).toBeInTheDocument();
    expect(screen.getByText('翻译请求由当前浏览器直接发送到所选服务。部分服务不允许网页直接连接；若测试失败，请改用支持浏览器访问的地址，或在自己的设备上运行中转服务。')).toBeInTheDocument();
    expect(screen.getByText('免费翻译')).toBeInTheDocument();
    expect(screen.getByText('当前使用')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '删除 免费翻译' })).not.toBeInTheDocument();
    expect(screen.getByLabelText('免费翻译线路')).toHaveValue('auto');
  });

  it('persists the selected free translation route', () => {
    const store = new ProviderProfileStore(localStorage);
    render(<SettingsPage store={store} />);

    fireEvent.change(screen.getByLabelText('免费翻译线路'), { target: { value: 'google' } });

    expect(store.getFreeRoute()).toBe('google');
    expect(screen.getByText('免费翻译线路已切换为Google Translate')).toBeInTheDocument();
  });

  it('persists translation direction and speech speed in reading preferences', () => {
    const readerStore = new ReaderPreferencesStore(localStorage);
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} readerStore={readerStore} />);

    fireEvent.change(screen.getByLabelText('翻译源语言'), { target: { value: 'ja' } });
    fireEvent.change(screen.getByLabelText('翻译目标语言'), { target: { value: 'en' } });
    fireEvent.change(screen.getByLabelText('朗读速度'), { target: { value: '1.2' } });

    expect(readerStore.get()).toMatchObject({ sourceLanguage: 'ja', targetLanguage: 'en', speechRate: 1.2 });
    expect(screen.getByLabelText('翻译源语言')).toHaveValue('ja');
    expect(screen.getByLabelText('翻译目标语言')).toHaveValue('en');
  });

  it('validates, creates, edits, enables, disables, selects, and deletes a profile', async () => {
    const store = new ProviderProfileStore(localStorage);
    const testConnection = vi.fn().mockResolvedValue(undefined);
    render(<SettingsPage store={store} testConnection={testConnection} />);

    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    expect(screen.getByRole('heading', { name: '添加翻译服务' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('服务类型'), { target: { value: 'openai-compatible' } });
    expect(screen.getByRole('button', { name: '保存配置' })).not.toBeDisabled();

    fireEvent.change(screen.getByLabelText('服务名称'), { target: { value: '我的模型' } });
    fireEvent.change(screen.getByLabelText('Base URL'), { target: { value: 'https://models.example/v1' } });
    fireEvent.change(screen.getByLabelText('模型名称'), { target: { value: 'reader-model' } });
    fireEvent.change(screen.getByLabelText('翻译提示词'), { target: { value: '采用自然、克制的出版级中文。' } });
    fireEvent.change(screen.getByLabelText('API Key'), { target: { value: 'sk-local-secret' } });
    expect(screen.getByLabelText('API Key')).toHaveAttribute('type', 'password');
    expect(document.body.textContent).not.toContain('sk-local-secret');
    fireEvent.click(screen.getByRole('button', { name: '显示密钥' }));
    expect(screen.getByLabelText('API Key')).toHaveAttribute('type', 'text');
    fireEvent.click(screen.getByRole('button', { name: '隐藏密钥' }));
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));

    expect(screen.getByText('我的模型')).toBeInTheDocument();
    expect(store.list()).toEqual(expect.arrayContaining([expect.objectContaining({ prompt: '采用自然、克制的出版级中文。' })]));
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

  it('explains validation problems instead of silently disabling save', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);
    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    expect(screen.getByRole('button', { name: '保存配置' })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: '测试连接' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));
    expect(screen.getByRole('alert')).toHaveTextContent('请输入 Base URL');
    expect(screen.getByRole('alert')).toHaveTextContent('请输入模型名称');
    expect(screen.getByRole('alert')).toHaveTextContent('请输入 API Key');
  });

  it('groups dedicated translation APIs and persists Youdao credentials', async () => {
    const store = new ProviderProfileStore(localStorage);
    const testConnection = vi.fn().mockResolvedValue(undefined);
    render(<SettingsPage store={store} testConnection={testConnection} />);

    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    expect(screen.getByRole('option', { name: 'OpenAI 兼容协议（Chat Completions）' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'OpenAI Responses API' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Anthropic Messages API' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: '自定义 HTTP 翻译（JSON）' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: '有道智云文本翻译' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'DeepL API' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('服务名称'), { target: { value: '我的有道' } });
    fireEvent.change(screen.getByLabelText('服务类型'), { target: { value: 'youdao' } });
    fireEvent.change(screen.getByLabelText('App Key'), { target: { value: 'app-key' } });
    fireEvent.change(screen.getByLabelText('App Secret'), { target: { value: 'app-secret' } });
    expect(screen.getByRole('button', { name: '保存配置' })).not.toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: '测试连接' }));
    await waitFor(() => expect(testConnection).toHaveBeenCalledWith(expect.objectContaining({ appSecret: 'app-secret' })));
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));

    expect(store.list()).toEqual(expect.arrayContaining([expect.objectContaining({ name: '我的有道', kind: 'youdao', apiKey: 'app-key', appSecret: 'app-secret' })]));
    fireEvent.click(screen.getByRole('button', { name: '编辑 我的有道' }));
    expect(screen.getByLabelText('App Secret')).toHaveValue('app••••••••••ret');
  });

  it('clears protocol-specific fields when switching model protocols', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);
    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    fireEvent.change(screen.getByLabelText('服务名称'), { target: { value: '模型配置' } });
    fireEvent.change(screen.getByLabelText('Base URL'), { target: { value: 'https://models.example/v1' } });
    fireEvent.change(screen.getByLabelText('模型名称'), { target: { value: 'reader-model' } });
    fireEvent.change(screen.getByLabelText('API Key'), { target: { value: 'openai-secret' } });
    fireEvent.change(screen.getByLabelText('翻译提示词'), { target: { value: '使用文学化表达' } });
    fireEvent.change(screen.getByLabelText('服务类型'), { target: { value: 'anthropic-messages' } });

    expect(screen.getByLabelText('Base URL')).toHaveValue('');
    expect(screen.getByLabelText('模型名称')).toHaveValue('');
    expect(screen.getByLabelText('API Key')).toHaveValue('');
    expect(screen.getByLabelText('翻译提示词')).toHaveValue('');
    expect(screen.getByLabelText('Base URL')).toHaveAttribute('placeholder', 'https://api.anthropic.com');
  });

  it('uses the official DeepL Free address as a placeholder', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);
    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    fireEvent.change(screen.getByLabelText('服务类型'), { target: { value: 'deepl' } });

    expect(screen.getByLabelText('Base URL')).toHaveValue('');
    expect(screen.getByLabelText('Base URL')).toHaveAttribute('placeholder', 'https://api-free.deepl.com');
    expect(screen.getByLabelText('API Key')).toBeInTheDocument();
  });

  it('shows the free route explanation behind a compact help button', () => {
    render(<SettingsPage store={new ProviderProfileStore(localStorage)} />);
    const help = screen.getByRole('button', { name: '免费线路说明' });
    expect(screen.getByLabelText('免费翻译线路')).toHaveValue('auto');
    expect(help).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(help);
    expect(screen.getByRole('note')).toHaveTextContent('按 MyMemory → Azure Edge → Google Translate 顺序尝试，返回第一个有效译文。');
    fireEvent.change(screen.getByLabelText('免费翻译线路'), { target: { value: 'google' } });
    expect(screen.getByRole('note')).toHaveTextContent('Google Translate GTX 线路，需要当前网络可以访问 Google。');
  });

  it('saves a custom HTTP translation profile with its documented contract', () => {
    const store = new ProviderProfileStore(localStorage);
    render(<SettingsPage store={store} />);
    fireEvent.click(screen.getByRole('button', { name: '添加翻译服务' }));
    fireEvent.change(screen.getByLabelText('服务类型'), { target: { value: 'custom-http' } });
    fireEvent.change(screen.getByLabelText('翻译接口 URL'), { target: { value: 'https://translate.example.test/api' } });
    fireEvent.change(screen.getByLabelText('API Key'), { target: { value: 'custom-key' } });
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));

    expect(store.list()).toEqual(expect.arrayContaining([expect.objectContaining({ kind: 'custom-http', baseUrl: 'https://translate.example.test/api', apiKey: 'custom-key' })]));
  });
});
