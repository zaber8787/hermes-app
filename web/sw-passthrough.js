'use strict';
// HERMES WEB passthrough service worker (WEBSYNC F5 — revised 2026-10-18).
//
// This worker NEVER installs a fetch handler: every request falls through to
// the network, where serve.py's no-cache + stat-ETag does the real freshness
// work. It also NEVER unregisters itself.
//
// Why "never unregister" is load-bearing: flutter_bootstrap.js runs
// navigator.serviceWorker.register(...) whenever the page already has a
// registration, then waits for the worker's "activated" statechange with a
// 4-second hard timeout. A self-unregistering worker deactivates before that
// event can reach the page, the wait times out, and the loader throws
// "prepareServiceWorker" — the whole app fails to load at that cold start.
// That race was the root cause of the intermittent "web completely fails to
// load" reports. A quiet, permanent worker resolves register() instantly and
// cannot race anything.
self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Purge Cache API storage left behind by the OLD caching worker so no
      // stale bundle can be resurrected by a returning tab.
      try {
        const keys = await caches.keys();
        await Promise.all(keys.map((k) => caches.delete(k)));
      } catch (e) {
        console.warn('hermes-sw: cache purge failed (ignored):', e);
      }
      try {
        await self.clients.claim();
      } catch (e) {
        console.warn('hermes-sw: claim failed (ignored):', e);
      }
    })()
  );
});
