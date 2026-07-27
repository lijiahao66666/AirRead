export type ReaderLanguage = 'auto' | 'en' | 'zh-CN' | 'zh-TW' | 'ja' | 'ko' | 'fr' | 'de' | 'es' | 'ru';

export type ReaderPreferences = {
  sourceLanguage: ReaderLanguage;
  targetLanguage: Exclude<ReaderLanguage, 'auto'>;
  sourceVoiceURI: string;
  targetVoiceURI: string;
  speechRate: number;
  fontFamily: 'serif' | 'sans';
  fontSize: 'small' | 'medium' | 'large' | 'x-large';
  lineHeight: 'compact' | 'comfortable' | 'relaxed';
  readingMode: 'paged' | 'scroll';
  theme: 'paper' | 'sepia' | 'night';
};

export const READER_LANGUAGE_OPTIONS: Array<{ value: ReaderLanguage; label: string }> = [
  { value: 'auto', label: '自动识别' },
  { value: 'en', label: '英语' },
  { value: 'zh-CN', label: '简体中文' },
  { value: 'zh-TW', label: '繁体中文' },
  { value: 'ja', label: '日语' },
  { value: 'ko', label: '韩语' },
  { value: 'fr', label: '法语' },
  { value: 'de', label: '德语' },
  { value: 'es', label: '西班牙语' },
  { value: 'ru', label: '俄语' },
];

export const SPEECH_RATE_OPTIONS = [0.8, 1, 1.2, 1.5] as const;

export const DEFAULT_READER_PREFERENCES: ReaderPreferences = {
  sourceLanguage: 'auto',
  targetLanguage: 'zh-CN',
  sourceVoiceURI: '',
  targetVoiceURI: '',
  speechRate: 1,
  fontFamily: 'serif',
  fontSize: 'medium',
  lineHeight: 'comfortable',
  readingMode: 'paged',
  theme: 'paper',
};

const PREFERENCES_KEY = 'airread.readerPreferences.v1';
const languageValues = new Set<ReaderLanguage>(READER_LANGUAGE_OPTIONS.map((option) => option.value));
const targetLanguageValues = new Set<Exclude<ReaderLanguage, 'auto'>>(READER_LANGUAGE_OPTIONS.filter((option) => option.value !== 'auto').map((option) => option.value as Exclude<ReaderLanguage, 'auto'>));

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;
type StoredReaderPreferences = Partial<ReaderPreferences> & { voiceURI?: unknown };

const isReaderPreferences = (value: unknown): value is StoredReaderPreferences => Boolean(value) && typeof value === 'object';

export class ReaderPreferencesStore {
  constructor(private readonly storage: StorageLike = window.localStorage) {}

  get(): ReaderPreferences {
    const raw = this.storage.getItem(PREFERENCES_KEY);
    if (!raw) return { ...DEFAULT_READER_PREFERENCES };
    try {
      const parsed: unknown = JSON.parse(raw);
      if (!isReaderPreferences(parsed)) return { ...DEFAULT_READER_PREFERENCES };
      const sourceLanguage = typeof parsed.sourceLanguage === 'string' && languageValues.has(parsed.sourceLanguage as ReaderLanguage)
        ? parsed.sourceLanguage as ReaderLanguage
        : DEFAULT_READER_PREFERENCES.sourceLanguage;
      const targetLanguage = typeof parsed.targetLanguage === 'string' && targetLanguageValues.has(parsed.targetLanguage as Exclude<ReaderLanguage, 'auto'>)
        ? parsed.targetLanguage as Exclude<ReaderLanguage, 'auto'>
        : DEFAULT_READER_PREFERENCES.targetLanguage;
      const speechRate = typeof parsed.speechRate === 'number' && SPEECH_RATE_OPTIONS.includes(parsed.speechRate as typeof SPEECH_RATE_OPTIONS[number])
        ? parsed.speechRate
        : DEFAULT_READER_PREFERENCES.speechRate;
      const fontFamily = parsed.fontFamily === 'sans' || parsed.fontFamily === 'serif' ? parsed.fontFamily : DEFAULT_READER_PREFERENCES.fontFamily;
      const fontSize = parsed.fontSize === 'small' || parsed.fontSize === 'medium' || parsed.fontSize === 'large' || parsed.fontSize === 'x-large' ? parsed.fontSize : DEFAULT_READER_PREFERENCES.fontSize;
      const lineHeight = parsed.lineHeight === 'compact' || parsed.lineHeight === 'comfortable' || parsed.lineHeight === 'relaxed' ? parsed.lineHeight : DEFAULT_READER_PREFERENCES.lineHeight;
      const readingMode = parsed.readingMode === 'scroll' || parsed.readingMode === 'paged' ? parsed.readingMode : DEFAULT_READER_PREFERENCES.readingMode;
      const theme = parsed.theme === 'sepia' || parsed.theme === 'night' || parsed.theme === 'paper' ? parsed.theme : DEFAULT_READER_PREFERENCES.theme;
      return {
        sourceLanguage,
        targetLanguage,
        sourceVoiceURI: typeof parsed.sourceVoiceURI === 'string'
          ? parsed.sourceVoiceURI
          : typeof parsed.voiceURI === 'string'
            ? parsed.voiceURI
            : DEFAULT_READER_PREFERENCES.sourceVoiceURI,
        targetVoiceURI: typeof parsed.targetVoiceURI === 'string' ? parsed.targetVoiceURI : DEFAULT_READER_PREFERENCES.targetVoiceURI,
        speechRate,
        fontFamily,
        fontSize,
        lineHeight,
        readingMode,
        theme,
      };
    } catch {
      return { ...DEFAULT_READER_PREFERENCES };
    }
  }

  save(preferences: ReaderPreferences): void {
    this.storage.setItem(PREFERENCES_KEY, JSON.stringify(preferences));
  }

  update(patch: Partial<ReaderPreferences>): ReaderPreferences {
    const next = { ...this.get(), ...patch };
    this.save(next);
    return next;
  }
}

export const languageLabel = (language: ReaderLanguage): string => READER_LANGUAGE_OPTIONS.find((option) => option.value === language)?.label ?? language;

export const speechLocaleForLanguage = (language: ReaderLanguage): string | undefined => {
  const locales: Partial<Record<ReaderLanguage, string>> = {
    en: 'en-US',
    'zh-CN': 'zh-CN',
    'zh-TW': 'zh-TW',
    ja: 'ja-JP',
    ko: 'ko-KR',
    fr: 'fr-FR',
    de: 'de-DE',
    es: 'es-ES',
    ru: 'ru-RU',
  };
  return locales[language];
};

export const detectSpeechLocale = (text: string): string => {
  if (/[\u3040-\u30ff]/u.test(text)) return 'ja-JP';
  if (/[\uac00-\ud7af]/u.test(text)) return 'ko-KR';
  if (/[\u3400-\u9fff]/u.test(text)) return 'zh-CN';
  return 'en-US';
};

export const speechLocaleForText = (text: string, sourceLanguage: ReaderLanguage): string => speechLocaleForLanguage(sourceLanguage) ?? detectSpeechLocale(text);

const languageWordSignals: Record<Exclude<ReaderLanguage, 'auto'>, RegExp> = {
  en: /\b(?:the|and|this|that|is|are|was|were|a|an|of|to|in|on|for|with|you|we|it|hello|world|book|read|first|second)\b/iu,
  'zh-CN': /[\u3400-\u9fff]/u,
  'zh-TW': /[\u3400-\u9fff]/u,
  ja: /[\u3040-\u30ff]/u,
  ko: /[\uac00-\ud7af]/u,
  fr: /\b(?:le|la|les|des|un|une|du|de|et|est|sont|dans|pour|avec|bonjour|monde|livre|lire|ce|cette|qui|que)\b/iu,
  de: /\b(?:der|die|das|den|dem|des|ein|eine|und|ist|sind|im|in|für|mit|hallo|welt|buch|lesen|dies|diese|nicht)\b/iu,
  es: /\b(?:el|la|los|las|un|una|de|del|y|es|son|en|para|con|hola|mundo|libro|leer|este|esta|que)\b/iu,
  ru: /[\u0400-\u04ff]/u,
};

export const textMatchesTargetLanguage = (text: string, targetLanguage: Exclude<ReaderLanguage, 'auto'>): boolean => {
  const hasLetters = /[\p{L}]/u.test(text);
  if (!hasLetters) return false;
  const hasKana = /[\u3040-\u30ff]/u.test(text);
  const hasHangul = /[\uac00-\ud7af]/u.test(text);
  const hasCjk = /[\u3400-\u9fff]/u.test(text);
  if (targetLanguage === 'zh-CN' || targetLanguage === 'zh-TW') return hasCjk && !hasKana && !hasHangul;
  if (targetLanguage === 'ja') return hasKana;
  if (targetLanguage === 'ko') return hasHangul;
  if (targetLanguage === 'ru') return languageWordSignals.ru.test(text);
  if (hasKana || hasHangul || hasCjk || !/[A-Za-zÀ-ÖØ-öø-ÿ]/u.test(text)) return false;
  if (languageWordSignals[targetLanguage].test(text)) return true;
  if (targetLanguage === 'fr') return /[àâçéèêëîïôûùüÿœæ]/iu.test(text);
  if (targetLanguage === 'de') return /[äöüß]/iu.test(text);
  if (targetLanguage === 'es') return /[áéíóúñü]/iu.test(text);
  return false;
};

export const availableSpeechVoices = (): SpeechSynthesisVoice[] => {
  if (typeof window === 'undefined' || typeof window.speechSynthesis?.getVoices !== 'function') return [];
  return window.speechSynthesis.getVoices();
};

export const voicesForLocale = (voices: SpeechSynthesisVoice[], locale: string): SpeechSynthesisVoice[] => {
  const language = locale.toLowerCase().split('-')[0];
  return voices
    .filter((voice) => voice.lang.toLowerCase().split('-')[0] === language)
    .sort((left, right) => Number(right.default) - Number(left.default) || Number(right.localService) - Number(left.localService) || left.name.localeCompare(right.name));
};

export const findSpeechVoice = (voices: SpeechSynthesisVoice[], voiceURI: string, locale: string): SpeechSynthesisVoice | undefined => {
  const language = locale.toLowerCase().split('-')[0];
  if (voiceURI) {
    const preferred = voices.find((voice) => voice.voiceURI === voiceURI);
    if (preferred?.lang.toLowerCase().split('-')[0] === language) return preferred;
  }
  return voicesForLocale(voices, locale)[0];
};

export const speechPreviewText = (language: Exclude<ReaderLanguage, 'auto'>): string => ({
  en: 'This is the translation voice preview.',
  'zh-CN': '这是译文声音的试听。',
  'zh-TW': '這是譯文聲音的試聽。',
  ja: 'これは翻訳音声のプレビューです。',
  ko: '번역 음성 미리 듣기입니다.',
  fr: 'Ceci est un aperçu de la voix traduite.',
  de: 'Dies ist eine Vorschau der Übersetzungsstimme.',
  es: 'Esta es una vista previa de la voz traducida.',
  ru: 'Это пример голоса перевода.',
})[language];
