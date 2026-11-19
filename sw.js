// Offline support: cache the app shell; always try the network first so updates land quickly.
const CACHE = '5k-coach-v12';
const SHELL = [
  './', 'index.html', 'manifest.webmanifest', 'css/app.css',
  'js/app.js', 'js/store.js', 'js/plan.js', 'js/audio.js', 'js/ai.js', 'js/gps.js', 'js/route.js',
  'audio/warmup.wav', 'audio/run.wav', 'audio/walk.wav', 'audio/lastrun.wav',
  'audio/halfway.wav', 'audio/oneminute.wav', 'audio/cooldown.wav', 'audio/done.wav',
  'icons/apple-touch-icon.png', 'icons/icon-192.png', 'icons/icon-512.png',
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Claude API, the Leaflet CDN and OpenStreetMap tiles are never intercepted or cached here:
  // the browser fetches them itself, and the app falls back to a plain route trace offline.
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
        return res;
      })
      .catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('index.html')))
  );
});
