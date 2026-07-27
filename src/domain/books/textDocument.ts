export function markdownToText(source: string): string {
  return source
    .replace(/^---\s*\n[\s\S]*?\n---\s*/u, '')
    .replace(/\r\n?/gu, '\n')
    .replace(/!\[([^\]]*)\]\([^)]*\)/gu, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/gu, '$1')
    .replace(/^>\s?/gmu, '')
    .replace(/^(\s*)[-+*]\s+/gmu, '$1')
    .replace(/^(\s*)\d+[.)]\s+/gmu, '$1')
    .replace(/[`*_~]/gu, '')
    .replace(/\n{3,}/gu, '\n\n')
    .trim();
}

export function htmlToText(source: string): string {
  if (typeof DOMParser === 'undefined') return source.replace(/<[^>]+>/gu, ' ').replace(/\s+/gu, ' ').trim();

  const document = new DOMParser().parseFromString(source, 'text/html');
  document.querySelectorAll('script,style,noscript,template').forEach((node) => node.remove());
  const blocks = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,pre')]
    .map((element) => {
      const text = element.textContent?.replace(/\s+/gu, ' ').trim() || '';
      if (!text) return '';
      return /^H[1-6]$/u.test(element.tagName) ? `# ${text}` : text;
    })
    .filter(Boolean);

  return (blocks.length > 0 ? blocks.join('\n\n') : (document.body.textContent || '').replace(/\s+/gu, ' ')).trim();
}
