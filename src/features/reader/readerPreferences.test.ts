import { beforeEach, describe, expect, it } from 'vitest';

import {
  DEFAULT_READER_PREFERENCES,
  findSpeechVoice,
  ReaderPreferencesStore,
  speechLocaleForText,
  textMatchesTargetLanguage,
  voicesForLocale,
} from './readerPreferences';

describe('ReaderPreferencesStore', () => {
  beforeEach(() => localStorage.clear());

  it('returns the local-first defaults and persists supported preferences', () => {
    const store = new ReaderPreferencesStore(localStorage);
    expect(store.get()).toEqual(DEFAULT_READER_PREFERENCES);
    store.update({ sourceLanguage: 'ja', targetLanguage: 'en', speechRate: 1.2, sourceVoiceURI: 'voice-ja', targetVoiceURI: 'voice-en' });
    expect(store.get()).toEqual({ sourceLanguage: 'ja', targetLanguage: 'en', speechRate: 1.2, sourceVoiceURI: 'voice-ja', targetVoiceURI: 'voice-en', fontFamily: 'serif', fontSize: 'medium', lineHeight: 'comfortable', readingMode: 'paged', theme: 'paper' });
  });

  it('migrates the legacy single voice into the source voice', () => {
    localStorage.setItem('airread.readerPreferences.v1', JSON.stringify({ voiceURI: 'legacy-voice' }));
    expect(new ReaderPreferencesStore(localStorage).get()).toMatchObject({ sourceVoiceURI: 'legacy-voice', targetVoiceURI: '' });
  });

  it('ignores invalid stored values instead of breaking reading', () => {
    localStorage.setItem('airread.readerPreferences.v1', JSON.stringify({ sourceLanguage: 'xx', targetLanguage: 'auto', speechRate: 3 }));
    expect(new ReaderPreferencesStore(localStorage).get()).toEqual(DEFAULT_READER_PREFERENCES);
  });
});

describe('speech preference helpers', () => {
  it('uses configured language and finds the matching system voice', () => {
    expect(speechLocaleForText('こんにちは', 'auto')).toBe('ja-JP');
    const japaneseVoice = { name: 'Japanese Enhanced', lang: 'ja-JP', voiceURI: 'ja-enhanced', default: false, localService: true } as SpeechSynthesisVoice;
    const englishVoice = { name: 'English', lang: 'en-US', voiceURI: 'en-default', default: true, localService: true } as SpeechSynthesisVoice;
    expect(findSpeechVoice([japaneseVoice], '', 'ja-JP')).toBe(japaneseVoice);
    expect(findSpeechVoice([japaneseVoice, englishVoice], 'ja-enhanced', 'en-US')).toBe(englishVoice);
    expect(textMatchesTargetLanguage('这是中文内容。', 'zh-CN')).toBe(true);
    expect(textMatchesTargetLanguage('This is English.', 'zh-CN')).toBe(false);
    expect(textMatchesTargetLanguage('これは日本語です。', 'ja')).toBe(true);
    expect(textMatchesTargetLanguage('This is an English book.', 'en')).toBe(true);
    expect(textMatchesTargetLanguage('Bonjour tout le monde.', 'fr')).toBe(true);
    expect(textMatchesTargetLanguage('Das ist ein deutsches Buch.', 'de')).toBe(true);
    expect(textMatchesTargetLanguage('Hola, este es un libro.', 'es')).toBe(true);
    expect(textMatchesTargetLanguage('Это русская книга.', 'ru')).toBe(true);
    expect(textMatchesTargetLanguage('Bonjour tout le monde.', 'en')).toBe(false);
  });

  it('prefers higher-quality voice names for automatic selection', () => {
    const standardVoice = { name: 'Microsoft Huihui', lang: 'zh-CN', voiceURI: 'standard', default: true, localService: true } as SpeechSynthesisVoice;
    const naturalVoice = { name: 'Microsoft Xiaoxiao Online (Natural)', lang: 'zh-CN', voiceURI: 'natural', default: false, localService: false } as SpeechSynthesisVoice;

    expect(voicesForLocale([standardVoice, naturalVoice], 'zh-CN')).toEqual([naturalVoice, standardVoice]);
    expect(findSpeechVoice([standardVoice, naturalVoice], '', 'zh-CN')).toBe(naturalVoice);
  });

  it('does not offer effect voices when ordinary narrator voices exist', () => {
    const effectVoice = { name: 'Albert', lang: 'en-US', voiceURI: 'effect', default: true, localService: true } as SpeechSynthesisVoice;
    const narratorVoice = { name: 'Samantha', lang: 'en-US', voiceURI: 'samantha', default: false, localService: true } as SpeechSynthesisVoice;

    expect(voicesForLocale([effectVoice, narratorVoice], 'en-US')).toEqual([narratorVoice]);
    expect(findSpeechVoice([effectVoice, narratorVoice], '', 'en-US')).toBe(narratorVoice);
  });
});
