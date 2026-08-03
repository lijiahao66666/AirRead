import { afterEach, describe, expect, it, vi } from 'vitest';

import { fetchOpenLearningMaterial } from './openContent';

afterEach(() => vi.restoreAllMocks());

describe('open learning content', () => {
  it('returns study text and attribution from the public source response', async () => {
    const remoteExtract = 'A city library is a public place where people can borrow books. Visitors can also use computers and ask staff for help. Many libraries offer quiet spaces for reading and studying. The service is useful for people of all ages. Community events sometimes bring local readers together to talk about new ideas.';
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify({
      query: {
        pages: {
          42: { title: 'City library', extract: remoteExtract, canonicalurl: 'https://simple.wikipedia.org/wiki/Library' },
        },
      },
    }), { status: 200 }));

    const material = await fetchOpenLearningMaterial('2026-08-03', { theme: 'Daily routines', focus: '描述习惯与生活节奏' });

    expect(material).toMatchObject({
      title: 'City library',
      text: remoteExtract,
      sourceUrl: 'https://simple.wikipedia.org/wiki/Library',
      sourceLabel: 'Simple English Wikipedia（开放资料）',
    });
    expect(material.license).toContain('CC BY-SA 4.0');
    expect(fetchMock.mock.calls[0][0]).toContain('simple.wikipedia.org/w/api.php');
  });
});
