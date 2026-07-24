import { strFromU8, unzipSync } from 'fflate';
import { XMLParser } from 'fast-xml-parser';

import type { Chapter } from './book';

export type EpubEntry = {
  path: string;
  bytes: Uint8Array;
};

export type EpubArchive = {
  title: string;
  author: string;
  coverDataUrl?: string;
  chapters: Chapter[];
  entries: EpubEntry[];
  packagePath: string;
};

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  removeNSPrefix: true,
  textNodeName: '#text',
  trimValues: true,
});

export function readEpubArchive(bytes: Uint8Array): EpubArchive {
  const files = unzipSync(bytes);
  const containerPath = 'META-INF/container.xml';
  const container = parseXml(requiredText(files, containerPath));
  const containerRoot = asObject(container.container);
  const rootfiles = asObject(containerRoot.rootfiles);
  const rootfile = asObject(
    Array.isArray(rootfiles.rootfile) ? rootfiles.rootfile[0] : rootfiles.rootfile,
  );
  const packagePath = stringValue(rootfile?.['@_full-path']);
  if (!packagePath) throw new Error('EPUB container has no package document');

  const packageDocument = parseXml(requiredText(files, packagePath));
  const packageRoot = asObject(packageDocument.package);
  const metadata = asObject(packageRoot.metadata);
  const manifestItems = toArray(asObject(packageRoot.manifest).item).map(asObject);
  const manifestById = new Map(
    manifestItems
      .map((item) => [stringValue(item['@_id']), item] as const)
      .filter(([id]) => id.length > 0),
  );
  const packageDirectory = directoryOf(packagePath);
  const spine = toArray(asObject(packageRoot.spine).itemref).map(asObject);
  const tocId = stringValue(asObject(packageRoot.spine)['@_toc']);
  const navigationItem = manifestItems.find((item) =>
    stringValue(item['@_properties']).split(/\s+/).includes('nav'),
  );
  const tocItem = manifestById.get(tocId) ?? manifestItems.find((item) =>
    stringValue(item['@_media-type']) === 'application/x-dtbncx+xml',
  ) ?? navigationItem;
  const tocPath = tocItem
    ? resolvePath(packageDirectory, stringValue(tocItem['@_href']))
    : undefined;
  const toc = tocItem
    ? parseToc(requiredText(files, tocPath!), directoryOf(tocPath!))
    : new Map<string, string>();

  const chapters = spine
    .map((item, index) => {
      const id = stringValue(item['@_idref']);
      const manifestItem = manifestById.get(id);
      if (!manifestItem) return undefined;
      const href = stringValue(manifestItem['@_href']).split('#', 1)[0];
      const path = resolvePath(packageDirectory, href);
      const content = requiredText(files, path);
      return {
        id,
        title: toc.get(normalizePath(path)) ?? titleFromXhtml(content) ?? `Chapter ${index + 1}`,
        href,
        content,
      } satisfies Chapter;
    })
    .filter((chapter): chapter is Chapter => Boolean(chapter));

  const coverItem = findCoverItem(metadata, manifestItems);
  const coverPath = coverItem
    ? resolvePath(packageDirectory, stringValue(coverItem['@_href']))
    : undefined;
  const coverBytes = coverPath ? files[coverPath] : undefined;

  return {
    title: textValue(metadata.title) || '未命名书籍',
    author: textValue(metadata.creator),
    coverDataUrl: coverBytes
      ? `data:${stringValue(coverItem?.['@_media-type']) || 'image/*'};base64,${bytesToBase64(coverBytes)}`
      : undefined,
    chapters,
    entries: Object.entries(files).map(([path, entryBytes]) => ({
      path,
      bytes: Uint8Array.from(entryBytes),
    })),
    packagePath,
  };
}

function parseToc(xml: string, tocDirectory: string): Map<string, string> {
  const document = asObject(parseXml(xml));
  const root = asObject(document.ncx ?? document.html);
  const labels = new Map<string, string>();
  const points = flatten(asObject(root.navMap).navPoint);
  for (const point of points) {
    const content = asObject(point.content);
    const href = stringValue(content['@_src']).split('#', 1)[0];
    const label = textValue(asObject(point.navLabel).text);
    if (href && label) labels.set(normalizePath(resolvePath(tocDirectory, href)), label);
  }

  if (labels.size === 0) {
    const nav = asObject(asObject(root.body).nav);
    const orderedList = asObject(nav.ol);
    for (const item of flatten(orderedList.li)) {
      const anchor = asObject(item.a);
      const href = stringValue(anchor['@_href']).split('#', 1)[0];
      const label = textValue(anchor['#text']);
      if (href && label) labels.set(normalizePath(resolvePath(tocDirectory, href)), label);
    }
  }
  return labels;
}

function findCoverItem(metadata: Record<string, unknown>, items: Record<string, unknown>[]) {
  const metadataCover = toArray(metadata.meta).map(asObject).find((meta) =>
    stringValue(meta['@_name']).toLowerCase() === 'cover',
  );
  const coverId = stringValue(metadataCover?.['@_content']);
  return items.find((item) =>
    stringValue(item['@_id']) === coverId ||
    stringValue(item['@_properties']).split(/\s+/).includes('cover-image') ||
    stringValue(item['@_id']).toLowerCase().includes('cover'),
  );
}

function parseXml(xml: string): Record<string, unknown> {
  return xmlParser.parse(xml) as Record<string, unknown>;
}

function requiredText(files: Record<string, Uint8Array>, path: string): string {
  const entry = files[path];
  if (!entry) throw new Error(`EPUB entry not found: ${path}`);
  return strFromU8(entry);
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' ? value as Record<string, unknown> : {};
}

function first<T>(value: T | T[]): T {
  return Array.isArray(value) ? value[0] : value;
}

function toArray(value: unknown): unknown[] {
  return value == null ? [] : Array.isArray(value) ? value : [value];
}

function flatten(value: unknown): Record<string, unknown>[] {
  return toArray(value).flatMap((item) => {
    const object = asObject(item);
    return [object, ...flatten(object.navPoint), ...flatten(object.li)];
  });
}

function stringValue(value: unknown): string {
  return typeof value === 'string' ? value : textValue(value);
}

function textValue(value: unknown): string {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  const object = asObject(value);
  return typeof object['#text'] === 'string' ? object['#text'].trim() : '';
}

function titleFromXhtml(content: string): string | undefined {
  const match = content.match(/<title[^>]*>([^<]+)<\/title>/i);
  return match?.[1]?.trim() || undefined;
}

function directoryOf(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.slice(0, slash);
}

export function resolvePath(directory: string, href: string): string {
  const parts = `${directory}/${href}`.split('/');
  const resolved: string[] = [];
  for (const part of parts) {
    if (!part || part === '.') continue;
    if (part === '..') resolved.pop();
    else resolved.push(part);
  }
  return resolved.join('/');
}

function normalizePath(path: string): string {
  return path.replace(/^\.\//, '').replace(/\\/g, '/');
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}
