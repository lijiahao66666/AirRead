import { AzureTranslatorEngine } from './azureTranslator';
import { FreeTranslationEngine } from './freeTranslation';
import { OpenAiCompatibleEngine } from './openAiCompatible';
import { validateProviderProfile, type ProviderProfile } from './providerProfile';
import { TencentTmtEngine } from './tencentTmt';
import type { TranslationEngine } from './translationTypes';

export const createTranslationEngine = (profile: ProviderProfile): TranslationEngine => {
  const validation = validateProviderProfile(profile);
  if (!profile.enabled || !validation.valid) throw new Error('Provider 配置无效或未启用');

  switch (profile.kind) {
    case 'free': return new FreeTranslationEngine(profile.freeRoute ?? 'auto');
    case 'openai-compatible': return new OpenAiCompatibleEngine(profile);
    case 'tencent-tmt': return new TencentTmtEngine(profile);
    case 'azure-translator': return new AzureTranslatorEngine(profile);
  }
};
