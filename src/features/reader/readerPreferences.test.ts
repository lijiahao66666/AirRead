import { beforeEach, describe, expect, it } from 'vitest';

import {
  DEFAULT_READER_PREFERENCES,
  findSpeechVoice,
  ReaderPreferencesStore,
  speechLocaleForText,
  textMatchesTargetLanguage,
} from './readerPreferences';

describe('ReaderPreferencesStore', () => {
  beforeEach(() => localStorage.clear());

  it('returns the local-first defaults and persists supported preferences', () => {
    const store = new ReaderPreferencesStore(localStorage);
    expect(store.get()).toEqual(DEFAULT_READER_PREFERENCES);
    store.update({ sourceLanguage: 'ja', targetLanguage: 'en', speechRate: 1.2, voiceURI: 'voice-ja' });
    expect(store.get()).toEqual({ sourceLanguage: 'ja', targetLanguage: 'en', speechRate: 1.2, voiceURI: 'voice-ja', fontFamily: 'serif', fontSize: 'medium', lineHeight: 'comfortable', readingMode: 'paged', theme: 'paper' });
  });

  it('ignores invalid stored values instead of breaking reading', () => {
    localStorage.setItem('airread.readerPreferences.v1', JSON.stringify({ sourceLanguage: 'xx', targetLanguage: 'auto', speechRate: 3 }));
    expect(new ReaderPreferencesStore(localStorage).get()).toEqual(DEFAULT_READER_PREFERENCES);
  });
});

describe('speech preference helpers', () => {
  it('uses configured language and finds the matching system voice', () => {
    expect(speechLocaleForText('こんにちは', 'auto')).toBe('ja-JP');
    const voice = { name: 'Japanese Enhanced', lang: 'ja-JP', voiceURI: 'ja-enhanced', default: false, localService: true } as SpeechSynthesisVoice;
    expect(findSpeechVoice([voice], '', 'ja-JP')).toBe(voice);
    expect(findSpeechVoice([voice], 'ja-enhanced', 'en-US')).toBe(voice);
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
});
