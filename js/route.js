// Route of a finished run: an SVG trace straight away (works offline), upgraded to an
// OpenStreetMap map via Leaflet when online. Leaflet is only fetched the first time a map
// is shown, so the app itself never depends on the CDN.
import { pieces } from './gps.js';

const LEAFLET = 'https://unpkg.com/leaflet@1.9.4/dist/';
const CSS_SRI = 'sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=';
const JS_SRI = 'sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=';
let leafletP = null;

function loadLeaflet() {
  if (window.L) return Promise.resolve(window.L);
  if (leafletP) return leafletP;
  leafletP = new Promise((resolve, reject) => {
    const css = Object.assign(document.createElement('link'), { rel: 'stylesheet', href: LEAFLET + 'leaflet.css', integrity: CSS_SRI, crossOrigin: '' });
    document.head.appendChild(css);
    const js = Object.assign(document.createElement('script'), { src: LEAFLET + 'leaflet.js', integrity: JS_SRI, crossOrigin: '' });
    js.onload = () => window.L ? resolve(window.L) : reject(new Error('Leaflet missing'));
    js.onerror = () => reject(new Error('Couldn’t load the map'));
    document.head.appendChild(js);
    setTimeout(() => reject(new Error('Map timed out')), 10000);
  }).catch(e => { leafletP = null; throw e; });
  return leafletP;
}

// Simple trace: equirectangular projection, fitted into the box.
export function routeSVG(track, w = 340, h = 190) {
  const ps = pieces(track);
  if (!ps.length) return '';
  const all = ps.flatMap(p => p.line);
  const lat0 = all.reduce((a, p) => a + p[0], 0) / all.length;
  const k = Math.cos(lat0 * Math.PI / 180);
  const xs = all.map(p => p[1] * k), ys = all.map(p => -p[0]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const pad = 14, s = Math.min((w - 2 * pad) / Math.max(maxX - minX, 1e-9), (h - 2 * pad) / Math.max(maxY - minY, 1e-9));
  const ox = (w - (maxX - minX) * s) / 2, oy = (h - (maxY - minY) * s) / 2;
  const xy = p => `${((p[1] * k - minX) * s + ox).toFixed(1)},${((-p[0] - minY) * s + oy).toFixed(1)}`;
  const first = all[0], last = all[all.length - 1];
  const [fx, fy] = xy(first).split(','), [lx, ly] = xy(last).split(',');
  return `<svg class="route-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Route trace">
    ${ps.map(p => `<polyline points="${p.line.map(xy).join(' ')}" fill="none" stroke="var(--accent)" stroke-width="${p.dashed ? 2.5 : 4}" stroke-linecap="round" stroke-linejoin="round" ${p.dashed ? 'stroke-dasharray="2 7" opacity=".7"' : ''}/>`).join('')}
    <circle cx="${lx}" cy="${ly}" r="6" fill="var(--red)" stroke="var(--card)" stroke-width="2.5"/>
    <circle cx="${fx}" cy="${fy}" r="6" fill="var(--accent)" stroke="var(--card)" stroke-width="2.5"/>
  </svg>`;
}

export function routeHTML(track) {
  return `<div class="route" data-route>${routeSVG(track)}<div class="route-note">${navigator.onLine ? 'Loading map…' : 'Offline — showing the route shape.'}</div></div>`;
}

// Upgrade a .route element (from routeHTML) to a real map. Keeps the SVG if anything fails.
export async function mountMap(el, track) {
  if (!el || el.dataset.mounted || !navigator.onLine) return;
  el.dataset.mounted = '1';
  const note = el.querySelector('.route-note');
  let L;
  try { L = await loadLeaflet(); } catch (e) {
    if (note) note.textContent = 'Map unavailable — showing the route shape.';
    return;
  }
  if (!el.isConnected) return;
  const box = document.createElement('div');
  box.className = 'route-map';
  el.appendChild(box);
  const map = L.map(box, { zoomControl: true, attributionControl: true, dragging: false, touchZoom: false, scrollWheelZoom: false, doubleClickZoom: false, boxZoom: false, keyboard: false, tap: false });
  const tiles = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors',
  }).addTo(map);
  const color = getComputedStyle(el).getPropertyValue('--accent').trim() || '#34c759';
  const ps = pieces(track);
  const lines = ps.map(p => L.polyline(p.line, p.dashed ? { color, weight: 3, opacity: 0.8, dashArray: '2 8' } : { color, weight: 5, opacity: 0.95 }).addTo(map));
  const all = ps.flatMap(p => p.line);
  L.circleMarker(all[0], { radius: 6, color: '#fff', weight: 2.5, fillColor: color, fillOpacity: 1 }).addTo(map);
  L.circleMarker(all[all.length - 1], { radius: 6, color: '#fff', weight: 2.5, fillColor: '#ff3b30', fillOpacity: 1 }).addTo(map);
  map.fitBounds(L.featureGroup(lines).getBounds(), { padding: [18, 18], maxZoom: 17 });
  // Tiles can still fail (captive wifi, flaky signal): fall back to the trace.
  let loaded = false;
  tiles.on('tileload', () => {
    if (loaded) return;
    loaded = true;
    el.classList.add('has-map');
    note?.remove();
  });
  setTimeout(() => {
    if (loaded || !el.isConnected) return;
    map.remove(); box.remove();
    if (note) note.textContent = 'Map unavailable — showing the route shape.';
  }, 8000);
  el._map = map;
}
