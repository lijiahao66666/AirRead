import { strToU8, zipSync } from 'fflate';

import type { LearningPack, LearningStoryMemory } from './learningTypes';

const escapeXml = (value: string): string => value.replace(/[&<>"']/gu, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[character] ?? character);

const paragraphs = (value: string): string => value.split(/\n{2,}/u).map((paragraph) => `<p>${escapeXml(paragraph.trim())}</p>`).join('');

const chapterFileName = (chapterNumber: number): string => `chapter-${String(chapterNumber).padStart(4, '0')}.xhtml`;

const storyPacks = (packs: Record<string, LearningPack>, storyId: string): LearningPack[] => Object.values(packs)
  .filter((pack) => pack.story?.storyId === storyId)
  .sort((left, right) => left.story.chapterNumber - right.story.chapterNumber || left.date.localeCompare(right.date));

const xhtmlDocument = (title: string, body: string): string => `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head><title>${escapeXml(title)}</title><meta charset="utf-8"/></head>
<body>${body}</body>
</html>`;

const chapterDocument = (pack: LearningPack): string => {
  const vocabulary = pack.vocabulary.length
    ? `<section><h2>Learning notes</h2><ul>${pack.vocabulary.map((item) => `<li><strong>${escapeXml(item.term)}</strong> — ${escapeXml(item.meaning)}<br/><em>${escapeXml(item.example)}</em></li>`).join('')}</ul></section>`
    : '';
  return xhtmlDocument(pack.story.chapterTitle, `<article>
<header><p>Chapter ${pack.story.chapterNumber}</p><h1>${escapeXml(pack.story.chapterTitle)}</h1></header>
<section><h2>Previous summary</h2>${paragraphs(pack.story.previousSummary)}</section>
<section><h2>English chapter</h2>${paragraphs(pack.originalText)}</section>
<section><h2>Chinese translation</h2>${paragraphs(pack.translation ?? '')}</section>
${vocabulary}
<section><h2>Next hook</h2>${paragraphs(pack.story.nextHook)}</section>
</article>`);
};

const safeFileName = (value: string): string => value.replace(/[\\/:*?"<>|]/gu, '-').replace(/\s+/gu, ' ').trim().slice(0, 80) || 'AirRead-Story';

export const createStoryEpub = (story: LearningStoryMemory, packs: Record<string, LearningPack>): Uint8Array => {
  const chapters = storyPacks(packs, story.storyId);
  if (chapters.length === 0) throw new Error('当前故事还没有可导出的章节');
  const chapterManifest = chapters.map((pack) => `<item id="chapter-${pack.story.chapterNumber}" href="text/${chapterFileName(pack.story.chapterNumber)}" media-type="application/xhtml+xml"/>`).join('');
  const chapterSpine = chapters.map((pack) => `<itemref idref="chapter-${pack.story.chapterNumber}"/>`).join('');
  const navigation = chapters.map((pack) => `<li><a href="text/${chapterFileName(pack.story.chapterNumber)}">Chapter ${pack.story.chapterNumber}: ${escapeXml(pack.story.chapterTitle)}</a></li>`).join('');
  const tocNavigation = chapters.map((pack, index) => `<navPoint id="chapter-${pack.story.chapterNumber}" playOrder="${index + 1}"><navLabel><text>Chapter ${pack.story.chapterNumber}: ${escapeXml(pack.story.chapterTitle)}</text></navLabel><content src="text/${chapterFileName(pack.story.chapterNumber)}"/></navPoint>`).join('');
  const identifier = `urn:airread:${story.storyId}`;
  const modifiedAt = new Date().toISOString().replace(/[-:]/gu, '').replace(/\.\d{3}/u, '');
  const files: Record<string, Uint8Array | [Uint8Array, { level: 0 }]> = {
    mimetype: [strToU8('application/epub+zip'), { level: 0 }],
    'META-INF/container.xml': strToU8(`<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`),
    'OEBPS/content.opf': strToU8(`<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="en">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">${escapeXml(identifier)}</dc:identifier><dc:title>${escapeXml(story.title)}</dc:title><dc:language>en</dc:language><dc:creator>AirRead AI Original Serial</dc:creator><meta property="dcterms:modified">${modifiedAt}</meta><dc:description>${escapeXml(story.premise)}</dc:description></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>${chapterManifest}</manifest>
<spine toc="toc">${chapterSpine}</spine>
</package>`),
    'OEBPS/nav.xhtml': strToU8(xhtmlDocument(story.title, `<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><h1>${escapeXml(story.title)}</h1><ol>${navigation}</ol></nav>`)),
    'OEBPS/toc.ncx': strToU8(`<?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="${escapeXml(identifier)}"/></head><docTitle><text>${escapeXml(story.title)}</text></docTitle><navMap>${tocNavigation}</navMap></ncx>`),
  };
  chapters.forEach((pack) => {
    files[`OEBPS/text/${chapterFileName(pack.story.chapterNumber)}`] = strToU8(chapterDocument(pack));
  });
  return zipSync(files, { level: 6 });
};

export const downloadStoryEpub = (story: LearningStoryMemory, packs: Record<string, LearningPack>): void => {
  const content = Uint8Array.from(createStoryEpub(story, packs));
  const blob = new Blob([content], { type: 'application/epub+zip' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = `${safeFileName(story.title)}.epub`;
  anchor.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
};
