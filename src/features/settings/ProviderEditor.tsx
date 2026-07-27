import { Eye, EyeOff, FlaskConical, Save, X } from 'lucide-react';
import { useState } from 'react';

import { validateProviderProfile, type ProviderKind, type ProviderProfile } from '../../domain/ai/providerProfile';
import { DEFAULT_TRANSLATION_INSTRUCTIONS } from '../../domain/ai/translationTypes';

export type ProviderEditorProps = {
  profile: ProviderProfile;
  validationProfile?: ProviderProfile;
  onChange: (profile: ProviderProfile) => void;
  onSave: () => void;
  onCancel: () => void;
  onTest: () => void;
  mode?: 'create' | 'edit';
  error?: string;
  testing?: boolean;
  testResult?: { tone: 'success' | 'error'; message: string };
};

const kindLabels: Record<ProviderKind, string> = {
  free: '免费翻译',
  'openai-compatible': 'OpenAI 兼容协议（Chat Completions）',
  'openai-responses': 'OpenAI Responses API',
  'anthropic-messages': 'Anthropic Messages API',
  'custom-http': '自定义 HTTP 翻译（JSON）',
  'tencent-tmt': '腾讯云翻译 TMT',
  'azure-translator': 'Azure AI Translator',
  youdao: '有道智云文本翻译',
  deepl: 'DeepL API',
};

export function ProviderEditor({ profile, validationProfile, onChange, onSave, onCancel, onTest, mode = 'edit', error, testing = false, testResult }: ProviderEditorProps) {
  const [secretVisible, setSecretVisible] = useState(false);
  const [appSecretVisible, setAppSecretVisible] = useState(false);
  const update = (patch: Partial<ProviderProfile>) => onChange({ ...profile, ...patch });
  const handleKindChange = (kind: ProviderKind) => {
    onChange({ id: profile.id, name: profile.name, kind, enabled: profile.enabled });
  };
  const needsModel = profile.kind === 'openai-compatible' || profile.kind === 'openai-responses' || profile.kind === 'anthropic-messages';
  const needsUrl = profile.kind === 'openai-compatible' || profile.kind === 'openai-responses' || profile.kind === 'anthropic-messages' || profile.kind === 'custom-http' || profile.kind === 'azure-translator' || profile.kind === 'deepl';
  const needsRegion = profile.kind === 'tencent-tmt' || profile.kind === 'azure-translator';
  const needsAppSecret = profile.kind === 'youdao';
  const validation = validateProviderProfile(validationProfile ?? profile);
  const valid = validation.valid;
  const testLabel = testing ? '测试中…' : testResult?.tone === 'success' ? '测试通过' : testResult?.tone === 'error' ? '连接失败' : '测试连接';

  return <form className="provider-editor" onSubmit={(event) => { event.preventDefault(); onSave(); }}>
    <div className="settings-editor__header"><div><p className="eyebrow">翻译服务</p><h3>{mode === 'create' ? '添加翻译服务' : '编辑翻译服务'}</h3></div><button type="button" className="icon-button" onClick={onCancel} aria-label="关闭编辑器"><X size={18} /></button></div>
    <div className="settings-form-grid">
      <div className="settings-form-grid__service-row">
        <label>服务名称<input aria-label="服务名称" value={profile.name} onChange={(event) => update({ name: event.target.value })} placeholder="例如：我的模型服务" /></label>
        <label>服务类型<select aria-label="服务类型" value={profile.kind} onChange={(event) => handleKindChange(event.target.value as ProviderKind)}>
          <optgroup label="大语言模型翻译"><option value="openai-compatible">{kindLabels['openai-compatible']}</option><option value="openai-responses">{kindLabels['openai-responses']}</option><option value="anthropic-messages">{kindLabels['anthropic-messages']}</option></optgroup>
          <optgroup label="专用翻译 API"><option value="custom-http">{kindLabels['custom-http']}</option><option value="tencent-tmt">{kindLabels['tencent-tmt']}</option><option value="azure-translator">{kindLabels['azure-translator']}</option><option value="youdao">{kindLabels.youdao}</option><option value="deepl">{kindLabels.deepl}</option></optgroup>
        </select></label>
      </div>
      {needsUrl && <label className="settings-form-grid__wide">{profile.kind === 'custom-http' ? '翻译接口 URL' : 'Base URL'}{(profile.kind === 'anthropic-messages' || profile.kind === 'deepl') && <span className="field-hint">可留空使用官方默认地址</span>}<input aria-label={profile.kind === 'custom-http' ? '翻译接口 URL' : 'Base URL'} value={profile.baseUrl ?? ''} onChange={(event) => update({ baseUrl: event.target.value })} placeholder={profile.kind === 'anthropic-messages' ? 'https://api.anthropic.com' : profile.kind === 'deepl' ? 'https://api-free.deepl.com' : profile.kind === 'custom-http' ? 'https://example.com/translate' : 'https://...'} /></label>}
      {needsModel && <label>模型名称<input aria-label="模型名称" value={profile.model ?? ''} onChange={(event) => update({ model: event.target.value })} placeholder="模型名称" /></label>}
      <label className={needsRegion || needsModel ? '' : 'settings-form-grid__wide'}>{profile.kind === 'youdao' ? 'App Key' : 'API Key'}<input aria-label={profile.kind === 'youdao' ? 'App Key' : 'API Key'} type={secretVisible ? 'text' : 'password'} value={profile.apiKey ?? ''} onChange={(event) => update({ apiKey: event.target.value })} placeholder={profile.kind === 'tencent-tmt' ? 'SecretId:SecretKey' : '只保存在当前浏览器'} /><button type="button" className="secret-toggle" onClick={() => setSecretVisible((visible) => !visible)}>{secretVisible ? <><EyeOff size={15} /> 隐藏密钥</> : <><Eye size={15} /> 显示密钥</>}</button></label>
      {needsAppSecret && <label className="settings-form-grid__wide">App Secret<input aria-label="App Secret" type={appSecretVisible ? 'text' : 'password'} value={profile.appSecret ?? ''} onChange={(event) => update({ appSecret: event.target.value })} placeholder="只保存在当前浏览器" /><button type="button" className="secret-toggle" onClick={() => setAppSecretVisible((visible) => !visible)}>{appSecretVisible ? <><EyeOff size={15} /> 隐藏密钥</> : <><Eye size={15} /> 显示密钥</>}</button></label>}
      {needsRegion && <label>{profile.kind === 'tencent-tmt' ? '腾讯云地域' : 'Azure 区域（可选）'}<input aria-label={profile.kind === 'tencent-tmt' ? '腾讯云地域' : 'Azure 区域（可选）'} value={profile.region ?? ''} onChange={(event) => update({ region: event.target.value })} placeholder={profile.kind === 'tencent-tmt' ? 'ap-guangzhou' : 'eastasia'} /></label>}
      {needsModel && <label className="settings-form-grid__wide">翻译提示词<span className="field-hint">只填写翻译要求；源语言、目标语言、术语表和原文由 AirRead 自动附加</span><textarea aria-label="翻译提示词" value={profile.prompt ?? ''} onChange={(event) => update({ prompt: event.target.value })} maxLength={4_000} rows={4} placeholder={DEFAULT_TRANSLATION_INSTRUCTIONS} /></label>}
    </div>
    {profile.kind === 'youdao' && <p className="provider-editor__hint">有道智云文本翻译使用应用 ID（App Key）和应用密钥（App Secret）进行签名，请在有道智云控制台创建文本翻译应用后填写。</p>}
    {profile.kind === 'deepl' && <p className="provider-editor__hint">DeepL API Free 与 Pro 使用不同 Base URL；Free 默认地址为 api-free.deepl.com，每月额度由 DeepL 账户提供。</p>}
    {profile.kind === 'azure-translator' && <p className="provider-editor__hint">Azure AI Translator F0 每月提供 200 万字符免费额度，但仍需要你自己的 Azure Translator 资源、Key 和账户额度；这不是 AirRead 提供的公共额度。</p>}
    {profile.kind === 'custom-http' && <p className="provider-editor__hint">接口使用 POST JSON：<code>{'{ text, sourceLanguage, targetLanguage }'}</code>；请求头为 <code>Authorization: Bearer API Key</code>，响应返回 <code>translation</code> 或 <code>translatedText</code> 字段。</p>}
    {!valid && <ul className="provider-editor__validation" aria-label="配置校验提示">{validation.errors.map((message) => <li key={message}>{message}</li>)}</ul>}
    {error && <div className="settings-alert" role="alert">{error}</div>}
    <div className="settings-editor__actions"><button type="button" className="secondary-button" onClick={onCancel}>取消</button><div className="provider-editor__test-action"><button type="button" className={`secondary-button provider-editor__test-button${testResult ? ` provider-editor__test-button--${testResult.tone}` : ''}`} onClick={onTest} disabled={testing || !valid} title={testResult?.tone === 'error' ? testResult.message : undefined}><FlaskConical size={16} /> {testLabel}</button>{testResult?.tone === 'success' && <span className="sr-only" role="status">{testResult.message}</span>}{testResult?.tone === 'error' && <span className="provider-editor__test-popover" role="alert">{testResult.message}</span>}</div><button type="submit" className="primary-action"><Save size={16} /> 保存配置</button></div>
  </form>;
}
