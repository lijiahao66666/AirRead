import type { LearningPack, LearningStoryMemory } from './learningTypes';
import { createStoryEpub } from './storyEpub';

type StoryArchiveFileHandle = {
  createWritable: () => Promise<{ write: (data: Uint8Array) => Promise<void>; close: () => Promise<void> }>;
};

type StoryArchiveDirectoryHandle = {
  getFileHandle: (name: string, options?: { create?: boolean }) => Promise<StoryArchiveFileHandle>;
  queryPermission?: (descriptor?: { mode: 'read' | 'readwrite' }) => Promise<PermissionState>;
};

type ShowDirectoryPicker = (options?: { mode?: 'read' | 'readwrite' }) => Promise<StoryArchiveDirectoryHandle>;

const DATABASE_NAME = 'airread.storyArchive.v1';
const STORE_NAME = 'handles';

const archiveKey = (storyId: string): string => `directory:${storyId}`;

const safeFileName = (value: string): string => value.replace(/[\\/:*?"<>|]/gu, '-').replace(/\s+/gu, ' ').trim().slice(0, 80) || 'AirRead-Story';

export const supportsAutomaticStoryArchive = (): boolean => typeof window !== 'undefined' && typeof (window as Window & { showDirectoryPicker?: ShowDirectoryPicker }).showDirectoryPicker === 'function' && typeof indexedDB !== 'undefined';

const openDatabase = (): Promise<IDBDatabase> => new Promise((resolve, reject) => {
  const request = indexedDB.open(DATABASE_NAME, 1);
  request.onupgradeneeded = () => request.result.createObjectStore(STORE_NAME);
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

const writeFile = async (story: LearningStoryMemory, packs: Record<string, LearningPack>, handle: StoryArchiveFileHandle): Promise<void> => {
  const writable = await handle.createWritable();
  try {
    await writable.write(createStoryEpub(story, packs));
  } finally {
    await writable.close();
  }
};

const saveHandle = async (storyId: string, handle: StoryArchiveDirectoryHandle): Promise<void> => {
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

const loadHandle = async (storyId: string): Promise<StoryArchiveDirectoryHandle | undefined> => {
  const database = await openDatabase();
  const value = await new Promise<unknown>((resolve, reject) => {
    const request = database.transaction(STORE_NAME, 'readonly').objectStore(STORE_NAME).get(archiveKey(storyId));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  database.close();
  return value && typeof value === 'object' && 'getFileHandle' in value ? value as StoryArchiveDirectoryHandle : undefined;
};

export const connectAutomaticStoryArchive = async (story: LearningStoryMemory, packs: Record<string, LearningPack>): Promise<void> => {
  if (!supportsAutomaticStoryArchive()) throw new Error('当前浏览器不支持自动存档；请使用支持目录访问的 Chrome 或安卓浏览器。');
  const picker = (window as unknown as Window & { showDirectoryPicker: ShowDirectoryPicker }).showDirectoryPicker;
  const directory = await picker({ mode: 'readwrite' });
  const file = await directory.getFileHandle(`${safeFileName(story.title)}.epub`, { create: true });
  await writeFile(story, packs, file);
  await saveHandle(story.storyId, directory);
};

export const isAutomaticStoryArchiveConnected = async (storyId: string): Promise<boolean> => {
  if (!supportsAutomaticStoryArchive()) return false;
  try {
    const handle = await loadHandle(storyId);
    if (!handle) return false;
    if (handle.queryPermission && await handle.queryPermission({ mode: 'readwrite' }) !== 'granted') return false;
    return true;
  } catch {
    return false;
  }
};

export const persistAutomaticStoryArchive = async (story: LearningStoryMemory, packs: Record<string, LearningPack>): Promise<boolean> => {
  if (!supportsAutomaticStoryArchive()) return false;
  try {
    const handle = await loadHandle(story.storyId);
    if (!handle) return false;
    if (handle.queryPermission && await handle.queryPermission({ mode: 'readwrite' }) !== 'granted') return false;
    const file = await handle.getFileHandle(`${safeFileName(story.title)}.epub`, { create: true });
    await writeFile(story, packs, file);
    return true;
  } catch {
    return false;
  }
};
