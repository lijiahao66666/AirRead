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

  it('prioritizes a practical topic page instead of rotating through loosely related search results', async () => {
    const practicalExtract = 'An office is a room or a building where people work. People in an office often use computers and speak to coworkers. Offices may have meeting rooms and places to take a break. Some people work from home instead of going to an office. A workplace can be busy during the day.';
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(JSON.stringify({
      query: {
        pages: {
          1: { title: 'Work of art', extract: practicalExtract, canonicalurl: 'https://simple.wikipedia.org/wiki/Work_of_art' },
          2: { title: 'Office', extract: practicalExtract, canonicalurl: 'https://simple.wikipedia.org/wiki/Office' },
        },
      },
    }), { status: 200 }));

    const material = await fetchOpenLearningMaterial('2026-08-03', { theme: 'Small talk at work', focus: '听懂寒暄并自然回应' });

    expect(fetchMock.mock.calls[0][0]).toContain('gsrsearch=Office');
    expect(material.title).toBe('Office');
    expect(material.sourceUrl).toBe('https://simple.wikipedia.org/wiki/Office');
  });
});
