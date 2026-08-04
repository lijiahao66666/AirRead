import type { LearningPack, LearningStoryMemory } from './learningTypes';
import { createStoryEpub } from './storyEpub';

type StoryArchiveFileHandle = {
  createWritable: () => Promise<{ write: (data: Uint8Array) => Promise<void>; close: () => Promise<void> }>;
  queryPermission?: (descriptor?: { mode: 'read' | 'readwrite' }) => Promise<PermissionState>;
};

type SaveFilePicker = (options: { suggestedName: string; types: Array<{ description: string; accept: Record<string, string[]> }> }) => Promise<StoryArchiveFileHandle>;

const DATABASE_NAME = 'airread.storyArchive.v1';
const STORE_NAME = 'handles';

const archiveKey = (storyId: string): string => `epub:${storyId}`;

const safeFileName = (value: string): string => value.replace(/[\\/:*?"<>|]/gu, '-').replace(/\s+/gu, ' ').trim().slice(0, 80) || 'AirRead-Story';

export const supportsAutomaticStoryArchive = (): boolean => typeof window !== 'undefined' && typeof (window as Window & { showSaveFilePicker?: SaveFilePicker }).showSaveFilePicker === 'function' && typeof indexedDB !== 'undefined';

const openDatabase = (): Promise<IDBDatabase> => new Promise((resolve, reject) => {
  const request = indexedDB.open(DATABASE_NAME, 1);
  request.onupgradeneeded = () => request.result.createObjectStore(STORE_NAME);
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

const writeHandle = async (story: LearningStoryMemory, packs: Record<string, LearningPack>, handle: StoryArchiveFileHandle): Promise<void> => {
  const writable = await handle.createWritable();
  try {
    await writable.write(createStoryEpub(story, packs));
  } finally {
    await writable.close();
  }
};

const saveHandle = async (storyId: string, handle: StoryArchiveFileHandle): Promise<void> => {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, 'readwrite');
    transaction.objectStore(STORE_NAME).put(handle, archiveKey(storyId));
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
  database.close();
};

const loadHandle = async (storyId: string): Promise<StoryArchiveFileHandle | undefined> => {
  const database = await openDatabase();
  const value = await new Promise<unknown>((resolve, reject) => {
    const request = database.transaction(STORE_NAME, 'readonly').objectStore(STORE_NAME).get(archiveKey(storyId));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  database.close();
  return value && typeof value === 'object' && 'createWritable' in value ? value as StoryArchiveFileHandle : undefined;
};

export const connectAutomaticStoryArchive = async (story: LearningStoryMemory, packs: Record<string, LearningPack>): Promise<void> => {
  if (!supportsAutomaticStoryArchive()) throw new Error('当前浏览器不支持自动保存；请使用 EPUB 导出。');
  const picker = (window as unknown as Window & { showSaveFilePicker: SaveFilePicker }).showSaveFilePicker;
  const handle = await picker({
    suggestedName: `${safeFileName(story.title)}.epub`,
    types: [{ description: 'EPUB 电子书', accept: { 'application/epub+zip': ['.epub'] } }],
  });
  await writeHandle(story, packs, handle);
  await saveHandle(story.storyId, handle);
};

export const persistAutomaticStoryArchive = async (story: LearningStoryMemory, packs: Record<string, LearningPack>): Promise<boolean> => {
  if (!supportsAutomaticStoryArchive()) return false;
  try {
    const handle = await loadHandle(story.storyId);
    if (!handle) return false;
    if (handle.queryPermission && await handle.queryPermission({ mode: 'readwrite' }) !== 'granted') return false;
    await writeHandle(story, packs, handle);
    return true;
  } catch {
    return false;
  }
};
