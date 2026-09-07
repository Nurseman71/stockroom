/* Stockroom service worker.
 *
 * Purpose: make the Home Screen app OPEN when the sync server is
 * unreachable. Without this, a phone with no route to the tailnet shows
 * a blank page -- which is precisely the basement/garage case the app
 * exists for.
 *
 * EVERY path here is scope-relative. The app is served from "/" by
 * storage_tracker_server.py and from "/stockroom/" by GitHub Pages, so
 * a single leading slash anywhere would silently break one of the two
 * live copies. Relative URLs in a worker resolve against the worker's
 * own location, which is what makes one file serve both.
 *
 * Caching strategy, deliberately conservative:
 *
 * - The app document is NETWORK-FIRST, cache only as an offline
 *   fallback. It must never be served stale while online: the server
 *   injects the sync token and the build stamp into it per request, and
 *   this project already has a two-live-copies drift problem. A
 *   cache-first shell would quietly become a THIRD copy, which is the
 *   opposite of what the build stamp was added to fix.
 * - /api/* is never touched. Token-authenticated and mutable.
 * - /photos/* is never touched either: those already carry
 *   `private, max-age=86400` and cache-bust on updatedAt, so the HTTP
 *   cache covers them and this worker never stores a token-bearing URL.
 * - Icons and web fonts are cache-first. Static, and they are the
 *   difference between the offline app looking like the app and looking
 *   like unstyled fallback text.
 */

const VERSION = 'stockroom-v1';
const SHELL   = VERSION + '-shell';
const RUNTIME = VERSION + '-runtime';

// Resolved against this worker's URL, so they are correct on both origins.
const SCOPE_URL   = new URL('./', self.location);
const SHELL_KEY   = SCOPE_URL.href;               // cache key for the document
const PRECACHE    = ['icons/apple-touch-icon.png', 'icons/favicon-32.png', 'manifest.webmanifest'];
const FONT_HOSTS  = ['fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL);
    // One at a time: a single 404 must not fail the whole install and
    // leave the app with no worker at all.
    await Promise.all(PRECACHE.map(u => cache.add(new URL(u, SCOPE_URL)).catch(() => {})));
    // Take over without waiting for every tab to close. A lingering old
    // worker is one more way this app grows a stale copy.
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => !k.startsWith(VERSION)).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (e) { return; }

  const sameOrigin = url.origin === SCOPE_URL.origin;
  const inScope    = sameOrigin && url.pathname.startsWith(SCOPE_URL.pathname);
  const rel        = inScope ? url.pathname.slice(SCOPE_URL.pathname.length) : null;

  // Hands off: sync API and photos. Anything cross-origin that is not a
  // font host also falls through untouched -- on the Pages copy the API
  // calls go to the tailnet server and must not be intercepted.
  if (rel !== null && (rel.startsWith('api/') || rel.startsWith('photos/'))) return;

  // The document: network first, cached copy only when the network fails.
  if (req.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        // Deliberately cached despite the server's `no-store`: that
        // header exists because the HTML carries the sync token, and the
        // Cache API is same-origin and device-local -- exactly where the
        // token already lives in localStorage. The alternative is an app
        // that will not open offline, which is the whole point of this.
        const cache = await caches.open(SHELL);
        cache.put(SHELL_KEY, fresh.clone());
        return fresh;
      } catch (e) {
        const cached = await caches.match(SHELL_KEY, { cacheName: SHELL });
        if (cached) return cached;
        return new Response(
          '<!doctype html><meta charset="utf-8"><title>Stockroom offline</title>' +
          '<body style="font-family:system-ui;background:#1C1F26;color:#EDEAE0;padding:2rem">' +
          '<h1>Stockroom is offline</h1><p>This device has not cached a copy of the app yet. ' +
          'Open it once while connected, then it will work from here.</p>',
          { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } }
        );
      }
    })());
    return;
  }

  const isIcon = rel !== null && rel.startsWith('icons/');
  const isFont = FONT_HOSTS.includes(url.hostname);
  if (!isIcon && !isFont) return;

  // Static by URL: serve from cache, fall back to network, and keep
  // whatever the network gives us for next time.
  event.respondWith((async () => {
    const cached = await caches.match(req);
    if (cached) return cached;
    try {
      const fresh = await fetch(req);
      if (fresh && (fresh.ok || fresh.type === 'opaque')) {
        const cache = await caches.open(RUNTIME);
        cache.put(req, fresh.clone());
      }
      return fresh;
    } catch (e) {
      return Response.error();
    }
  })());
});
