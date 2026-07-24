import { AzureTranslatorEngine } from './azureTranslator';
import { AnthropicMessagesEngine } from './anthropicMessages';
import { DeepLTranslatorEngine } from './deeplTranslator';
import { FreeTranslationEngine } from './freeTranslation';
import { OpenAiCompatibleEngine } from './openAiCompatible';
import { OpenAiResponsesEngine } from './openAiResponses';
import { validateProviderProfile, type ProviderProfile } from './providerProfile';
import { TencentTmtEngine } from './tencentTmt';
import { YoudaoTranslatorEngine } from './youdaoTranslator';
import type { TranslationEngine } from './translationTypes';

export const createTranslationEngine = (profile: ProviderProfile): TranslationEngine => {
  const validation = validateProviderProfile(profile);
  if (!profile.enabled || !validation.valid) throw new Error('Provider 配置无效或未启用');

  switch (profile.kind) {
    case 'free': return new FreeTranslationEngine(profile.freeRoute ?? 'auto');
    case 'openai-compatible': return new OpenAiCompatibleEngine(profile);
    case 'openai-responses': return new OpenAiResponsesEngine(profile);
    case 'anthropic-messages': return new AnthropicMessagesEngine(profile);
    case 'tencent-tmt': return new TencentTmtEngine(profile);
    case 'azure-translator': return new AzureTranslatorEngine(profile);
    case 'youdao': return new YoudaoTranslatorEngine(profile);
    case 'deepl': return new DeepLTranslatorEngine(profile);
  }
};
