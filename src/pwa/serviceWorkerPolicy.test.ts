import { describe, expect, it, vi } from 'vitest';

import serviceWorker from '../../public/sw.js?raw';

type FetchEvent = {
  request: Request;
  respondWith: (response: Promise<Response> | Response) => void;
};

type LifecycleEvent = {
  waitUntil: (operation: Promise<unknown>) => void;
};

function loadServiceWorker(overrides: {
  cacheMatch?: ReturnType<typeof vi.fn>;
  cacheKeys?: ReturnType<typeof vi.fn>;
  cacheOpen?: ReturnType<typeof vi.fn>;
  cacheDelete?: ReturnType<typeof vi.fn>;
  fetch?: ReturnType<typeof vi.fn>;
} = {}) {
  const handlers = new Map<string, (event: FetchEvent | LifecycleEvent) => void>();
  const scope = {
    addEventListener: vi.fn((type: string, handler: (event: FetchEvent | LifecycleEvent) => void) => {
      handlers.set(type, handler);
    }),
    clients: { claim: vi.fn() },
    location: { origin: 'https://airread.test' },
    skipWaiting: vi.fn(),
  };
  const caches = {
    delete: overrides.cacheDelete ?? vi.fn().mockResolvedValue(true),
    keys: overrides.cacheKeys ?? vi.fn().mockResolvedValue([]),
    match: overrides.cacheMatch ?? vi.fn().mockResolvedValue(undefined),
    open: overrides.cacheOpen ?? vi.fn(),
  };
  const fetch = overrides.fetch ?? vi.fn();
  new Function('self', 'caches', 'fetch', serviceWorker)(scope, caches, fetch);

  return { caches, fetch, handlers, scope };
}

async function dispatchFetch(
  handler: (event: FetchEvent | LifecycleEvent) => void,
  request: Request,
) {
  let response: Promise<Response> | undefined;
  handler({
    request,
    respondWith: (value) => {
      response = Promise.resolve(value);
    },
  });

  return response!;
}

async function dispatchLifecycle(handler: (event: FetchEvent | LifecycleEvent) => void) {
  let operation: Promise<unknown> | undefined;
  handler({
    waitUntil: (value) => {
      operation = Promise.resolve(value);
    },
  });

  await operation;
}

function navigationRequest(path: string) {
  return {
    method: 'GET',
    mode: 'navigate',
    url: `https://airread.test${path}`,
  } as Request;
}

describe('AirRead service-worker update policy', () => {
  it('uses the network before cache for navigation requests', async () => {
    const shellCache = { put: vi.fn().mockResolvedValue(undefined) };
    const networkResponse = new Response('<!doctype html><title>fresh</title>');
    const { caches, fetch, handlers } = loadServiceWorker({
      cacheOpen: vi.fn().mockResolvedValue(shellCache),
      fetch: vi.fn().mockResolvedValue(networkResponse),
    });
    const request = navigationRequest('/#reader');

    const response = await dispatchFetch(handlers.get('fetch')!, request);

    expect(fetch).toHaveBeenCalledWith(request);
    expect(caches.match).not.toHaveBeenCalled();
    expect(shellCache.put).toHaveBeenCalledWith('/index.html', expect.any(Response));
    expect(await response.text()).toContain('fresh');
  });

  it('falls back to the cached app shell when navigation is offline', async () => {
    const fallback = new Response('<!doctype html><title>offline</title>');
    const { caches, handlers } = loadServiceWorker({
      cacheMatch: vi.fn().mockResolvedValue(fallback),
      fetch: vi.fn().mockRejectedValue(new Error('offline')),
    });

    const response = await dispatchFetch(
      handlers.get('fetch')!,
      navigationRequest('/studio'),
    );

    expect(caches.match).toHaveBeenCalledWith('/index.html');
    expect(await response.text()).toContain('offline');
  });

  it('removes stale AirRead caches when a new worker activates', async () => {
    const cacheDelete = vi.fn().mockResolvedValue(true);
    const { caches, handlers, scope } = loadServiceWorker({
      cacheDelete,
      cacheKeys: vi.fn().mockResolvedValue([
        'airread-shell-v1',
        'airread-runtime-v1',
        'airread-shell-v2',
        'airread-runtime-v2',
        'airread-shell-v3',
        'airread-runtime-v3',
        'unrelated-cache',
      ]),
    });

    await dispatchLifecycle(handlers.get('activate')!);

    expect(cacheDelete).toHaveBeenCalledWith('airread-shell-v1');
    expect(cacheDelete).toHaveBeenCalledWith('airread-runtime-v1');
    expect(cacheDelete).toHaveBeenCalledWith('airread-shell-v2');
    expect(cacheDelete).toHaveBeenCalledWith('airread-runtime-v2');
    expect(cacheDelete).not.toHaveBeenCalledWith('airread-shell-v4');
    expect(cacheDelete).not.toHaveBeenCalledWith('airread-runtime-v4');
    expect(cacheDelete).not.toHaveBeenCalledWith('unrelated-cache');
    expect(scope.clients.claim).toHaveBeenCalledOnce();
    expect(caches.keys).toHaveBeenCalledOnce();
  });

  it('stores same-origin static resources in the runtime cache', async () => {
    const runtimeCache = {
      match: vi.fn().mockResolvedValue(undefined),
      put: vi.fn().mockResolvedValue(undefined),
    };
    const assetResponse = new Response('compiled-script');
    const { fetch, handlers } = loadServiceWorker({
      cacheOpen: vi.fn().mockResolvedValue(runtimeCache),
      fetch: vi.fn().mockResolvedValue(assetResponse),
    });
    const request = new Request('https://airread.test/assets/index-hash.js', { method: 'GET' });

    const response = await dispatchFetch(handlers.get('fetch')!, request);

    expect(fetch).toHaveBeenCalledWith(request);
    expect(runtimeCache.put).toHaveBeenCalledWith(request, expect.any(Response));
    expect(await response.text()).toBe('compiled-script');
  });
});
