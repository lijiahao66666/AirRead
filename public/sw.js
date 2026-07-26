const cacheVersion = 'v3';
const shellCacheName = `airread-shell-${cacheVersion}`;
const runtimeCacheName = `airread-runtime-${cacheVersion}`;
const appShell = ['/', '/index.html', '/manifest.webmanifest'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(shellCacheName).then((cache) => cache.addAll(appShell)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(Promise.all([
    caches.keys().then((cacheNames) => Promise.all(
      cacheNames
        .filter((cacheName) => cacheName.startsWith('airread-')
          && cacheName !== shellCacheName
          && cacheName !== runtimeCacheName)
        .map((cacheName) => caches.delete(cacheName)),
    )),
    self.clients.claim(),
  ]));
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  if (event.request.mode === 'navigate') {
    event.respondWith(networkFirstNavigation(event.request));
    return;
  }

  if (isSameOriginStaticResource(event.request)) {
    event.respondWith(cacheStaticResource(event.request));
  }
});

async function networkFirstNavigation(request) {
  try {
    const response = await fetch(request);

    try {
      const cache = await caches.open(shellCacheName);
      await cache.put('/index.html', response.clone());
    } catch {}

    return response;
  } catch {
    return (await caches.match('/index.html')) ?? Response.error();
  }
}

function isSameOriginStaticResource(request) {
  const url = new URL(request.url);

  return url.origin === self.location.origin
    && (url.pathname.startsWith('/assets/')
      || url.pathname.startsWith('/icons/')
      || url.pathname === '/manifest.webmanifest'
      || url.pathname === '/favicon.png');
}

async function cacheStaticResource(request) {
  try {
    const cache = await caches.open(runtimeCacheName);
    const cached = await cache.match(request);

    if (cached) return cached;

    const response = await fetch(request);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  } catch {
    return fetch(request);
  }
}
